"""Build the portable lexical search resources from pinned vocabularies and existing training counts."""
import argparse
import gzip
import hashlib
import re
import rdata
import struct
from collections import defaultdict
from importlib.metadata import distribution, version
from pathlib import Path

from wordfreq import iter_wordlist, zipf_frequency

ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / "keyboard-engine/model"
OUT = ROOT / "Keyboard/Resources"
WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")
CMU_SHA = '81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22'


def english_forms(path):
    words = set()
    for part in ('noun', 'verb', 'adj', 'adv'):
        for line in (path / f'data.{part}').read_text().splitlines():
            if not line or not line[0].isdigit():
                continue
            fields = line.split()
            for lemma in fields[4:4 + 2 * int(fields[3], 16):2]:
                if not WORD.fullmatch(lemma):
                    continue
                words.add(lemma)
                if part not in ('verb', 'noun'):
                    continue
                base = lemma[:-1] if lemma.endswith('e') else lemma
                plural = (lemma[:-1] + 'ies' if lemma.endswith('y') and len(lemma) >= 2 and lemma[-2] not in 'aeiou'
                          else lemma + 'es' if lemma.endswith(('s', 'x', 'z', 'ch', 'sh')) else lemma + 's')
                words.add(plural)
                if part == 'verb':
                    words.update((base + 'ing', base + 'ed', lemma[:-1] + 'ied' if lemma.endswith('y') else lemma + 'ed'))
                    if len(lemma) >= 3 and lemma[-1] not in 'aeiouwxy' and lemma[-2] in 'aeiou':
                        words.update((lemma + lemma[-1] + 'ing', lemma + lemma[-1] + 'ed'))
        words.update(row.split()[0] for row in (path / f'{part}.exc').read_text().splitlines() if row.strip())
    return words


def hash_word(word):
    h = 14695981039346656037
    for c in word.encode():
        h = ((h ^ c) * 1099511628211) & 0xffffffffffffffff
    return h


def build(args):
    assert version('wordfreq') == '3.1.1'
    assert hashlib.sha256(args.cmu.read_bytes()).hexdigest() == CMU_SHA
    assert hashlib.sha256(args.cmu_license.read_bytes()).hexdigest() == 'bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a'
    existing = (MODEL / 'textspell30/vocab.tsv').read_text().splitlines()
    rows = {xs[0]: (i + 1, int(xs[1]), int(xs[2]), int(xs[3]))
            for i, row in enumerate(existing) if len(xs := row.split('\t')) == 5}
    words = set()
    for word in iter_wordlist('en'):
        if not WORD.fullmatch(word) or len(word) > 24:
            continue
        if zipf_frequency(word, 'en') < 2.3:
            break
        words.add(word)
    words.update(w for w, (_, f, general, sms) in rows.items()
                 if (f >= 2 or general >= 2 or sms) and WORD.fullmatch(w) and len(w) <= 24)
    forms = english_forms(args.wordnet / 'dict')
    assert hashlib.sha256(args.names.read_bytes()).hexdigest() == '1d5c601fa3c5177f4d9edb4c8c2f08fddc8d9bf04372b8a40dc6aecf92bfa324'
    data = rdata.read_rda(args.names)['babynames']
    counts = data.groupby('name').n.sum()
    names = {name.lower() for name, n in counts.items() if (n >= 25 or len(name) >= 5) and name.isascii() and name.isalpha()}
    here = Path(__file__).parent
    with gzip.open(here / 'given-names.txt.gz', 'rt') as f:
        names.update(w for row in f if (w := row.strip()).isalpha())
    texting = {w for row in (here / 'texting-words.txt').read_text().splitlines() if WORD.fullmatch(w := row.strip())}
    words.update(w for w in names if len(w) >= 3)
    words.update(texting)
    words.update(w for w in forms if WORD.fullmatch(w) and zipf_frequency(w, 'en') >= 1.0)
    preferred = {xs[0] for row in (MODEL / 'surface31/vocab.tsv').read_text().splitlines()
                 if len(xs := row.split('\t')) == 5 and xs[3].istitle()}
    contractions = {w.replace("'", "") for w in words if "'" in w and zipf_frequency(w, 'en') >= 3.9}
    corpus = {w for w in words if w not in forms and len(w) > 1 and w in contractions}

    phones = defaultdict(set)
    for line in args.cmu.read_text().splitlines():
        spell, phone = line.split(maxsplit=1)
        spell = spell.split('(')[0]
        if spell in words:
            phones[re.sub(r'[012]', '', phone.split('#')[0]).strip()].add(spell)
    homophones = defaultdict(set)
    for group in phones.values():
        if len(group) > 1:
            for w in group:
                homophones[w].update(group - {w})

    # Attribution travels with the derived word list in the app bundle.
    metadata = distribution('wordfreq').read_text('METADATA')
    credits = ("Lexical55. The following English frequency and vocabulary data are adapted from "
               "Robyn Speer's wordfreq 3.1.1 (https://github.com/rspeer/wordfreq), with frequency "
               "quantization, lexical flags, and filtered grouping by pronunciation. The derived table "
               "is licensed under CC BY-SA 4.0 https://creativecommons.org/licenses/by-sa/4.0/ .\n"
               + metadata[metadata.index('## License\n'):metadata.index('## Citing wordfreq\n')]
               + '\nUS given-name aggregate spellings: Social Security Administration via Hadley Wickham babynames 1.0.1 (CC0), https://github.com/hadley/babynames\n'
               + '\nWikidata English-language labels for given names, lowercased and accent-folded (CC0), https://www.wikidata.org/\n'
               + '\nEnglish Wiktionary contributors, derived headwords from the English text messaging slang and English internet slang categories (CC BY-SA 4.0), https://en.wiktionary.org/wiki/Category:English_text_messaging_slang and https://en.wiktionary.org/wiki/Category:English_internet_slang\n'
               + '\nCMUdict 74790861f652b15e4ac49015a90074ad62a27690, https://github.com/cmusphinx/cmudict\n'
               + args.cmu_license.read_text() + '\n' + (args.wordnet / 'LICENSE').read_text())
    OUT.mkdir(parents=True, exist_ok=True)
    (here / 'NOTICE.txt').write_text(credits + '\n')
    packed = []
    with (OUT / 'lexical55.tsv').open('w') as stream:
        for line in credits.splitlines():
            stream.write('# ' + line + '\n')
        stream.write('LEX55\n')
        for word in sorted(words):
            idx, freq, general, sms = rows.get(word, (0, 0, 0, 0))
            z = round(zipf_frequency(word, 'en') * 100)
            is_target = word in forms or general >= 2 or freq >= 3 or (z >= 330 and "'" in word)
            # Recognized as a possible repair target, or protected evidence of casual usage.
            name = word in names and (word in preferred or (word not in forms and general <= 2 and (len(word) >= 5 or z >= 155)))
            informal = (word in corpus or (word not in forms and sms >= 2 and general <= 2) or
                        (word in texting and (word not in forms and general <= 3 or z <= 350)))
            name |= word not in forms and general == 0 and sms > 0 and freq == sms and len(word) >= 5 and z < 265
            uncommon = not is_target and z >= 265
            protected = name or informal or uncommon
            flags = int(is_target) + (2 if sms >= 2 else 0) + (4 if protected else 0) + (8 if word in forms else 0) + (16 if freq >= 10 else 0)
            packed.append((hash_word(word), z, idx, flags))
            group = ','.join(sorted(homophones.get(word, ())))
            affix = is_target and z >= 320 and len(word) >= 4
            if affix or group:
                stream.write(f'{word}\t{int(affix)}\t{group}\n')

    # Retain trained bigrams only. IDs are the original vocabulary indices plus one.
    pairs = bytearray()
    for key, n in struct.iter_unpack('<QH', (MODEL / 'textspell30/contexts.bin').read_bytes()):
        if key >> 32:
            break
        pairs.extend(struct.pack('<IH', key, n))
    assert len({h for h, *_ in packed}) == len(packed)
    with (OUT / 'lexical55-context.bin').open('wb') as stream:
        stream.write(struct.pack('<4sIII', b'MBL2', len(packed), len(pairs) // 6, 0))
        for row in sorted(packed):
            stream.write(struct.pack('<QHHB3x', *row))
        stream.write(pairs)
    print('words', len(words), 'homophone members', len(homophones), 'context bytes', (OUT / 'lexical55-context.bin').stat().st_size)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wordnet', type=Path, required=True)
    parser.add_argument('--cmu', type=Path, required=True)
    parser.add_argument('--names', type=Path, required=True)
    parser.add_argument('--cmu-license', type=Path, required=True)
    build(parser.parse_args())
