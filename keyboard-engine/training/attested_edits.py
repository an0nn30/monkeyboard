"""Fit spelling repairs from the build 16 training partition (no benchmark text ships)."""
import argparse
import csv
import hashlib
import re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path
from paired_text import engine, key, pairs, tokens

def train(source):
    bench = engine.parent / 'Benchmarks'
    protected = set()
    for n in [15, 16]:
        with (bench / f'build{n}/cases.tsv').open() as f:
            protected.update(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']]))
                             for r in csv.DictReader(f,delimiter='\t'))
    english = {l.split('\t')[0] for l in (engine/'model/words.tsv').read_text().splitlines()}
    votes = defaultdict(lambda: defaultdict(set))
    clean_tokens, ordinary, seen = set(), set(), set()
    kept = Counter()
    for raw, gold in pairs(source):
        words = tokens(gold)
        canonical = ' '.join(words)
        if canonical in protected or hashlib.sha256(canonical.encode()).digest()[0] < 38:
            continue
        if canonical not in seen:
            # Learn intentional phrases from distinct clean messages, not from
            # the typo side or repeated variants of the same sentence.
            kept.update(set(zip(['^'] + words, words)))
            seen.add(canonical)
        clean_tokens.update(words)
        surface = re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)*",gold.replace('’',"'"))
        ordinary.update(w for w in surface[1:] if w.islower())
        noisy = tokens(raw)
        for tag,i,j,k,l in SequenceMatcher(None,noisy,words,autojunk=False).get_opcodes():
            if tag!='replace' or j-i!=1 or not 1<=l-k<=2: continue
            src = noisy[i]
            if not src.isalpha() or not 2<=len(src)<=30 or src in english: continue
            dst = ' '.join(words[k:l])
            if abs(len(src)-len(dst))>4: continue
            previous = words[k-1] if k else '^'
            for prefix in ('*',previous):
                votes[prefix+':'+src][dst].add(canonical)
    out = {}
    for code,options in votes.items():
        prefix,src = code.split(':')
        if src in clean_tokens: continue
        best, *rest = sorted(((len(s),w) for w,s in options.items()),reverse=True)
        n,dst = best
        # Short inputs need evidence from the preceding word. Never reinterpret
        # a spelling the corpus uses deliberately or a proper-name-only target.
        contextual = prefix != '*'
        if not contextual and len(src)<4: continue
        if not all(w in ordinary for w in dst.split()): continue
        if n < (2 if contextual else 3) or n < 8 * sum(c for c,_ in rest): continue
        out[code] = dst
    filtered = {k:v for k,v in out.items() if k.startswith('*:') or v != out.get('*:'+k.split(':')[1])}
    # An unambiguous global error/repair pair can still be wrong in a
    # particular sentence. Require its first target word to have followed this
    # predecessor in more than one distinct clean training message at runtime.
    repairs = len(filtered)
    for (prev,word),n in kept.items():
        if n>=3 and word in ordinary and word.isalpha() and len(word)>=2:
            filtered[f'!{prev}:{word}'] = word
    print('attested intentional phrases:', len(filtered)-repairs)
    with (engine/'model/attested-edits.tsv').open('w') as f:
        for k,v in sorted(filtered.items()): f.write(f'{k}\t{v}\n')
    print('context-specific / unrestricted entries:',sum(not k.startswith(('*:', '!')) for k in filtered),
          sum(k.startswith('*:') for k in filtered))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path)
    train(p.parse_args().source)
