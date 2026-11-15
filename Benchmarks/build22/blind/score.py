"""Score case-sensitive simulator output, optionally comparing two builds."""
import argparse
import gzip
import json
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

WORD = re.compile(r"[^\W_]+(?:['’][^\W_]+)*")


def alignment(ref, text):
    """Map each reference token to an observed index; keep insertions in gaps."""
    n, m = len(ref), len(text)
    mapped = [None] * n
    extras = defaultdict(list)
    start = 0
    while start < min(n, m) and ref[start] == text[start]:
        mapped[start] = start
        start += 1
    while min(n, m) > start and ref[n-1] == text[m-1]:
        n -= 1
        m -= 1
        mapped[n] = m
    if m == start:
        return mapped, extras
    if n == start:
        extras[start] = list(range(start, m))
        return mapped, extras
    a, b = ref[start:n], text[start:m]
    d = [list(range(len(b) + 1))]
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1):
            row.append(min(d[-1][j-1] + (x != y), d[-1][j] + 1, row[-1] + 1))
        d.append(row)
    i, j = len(a), len(b)
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (a[i-1] != b[j-1]):
            i -= 1
            j -= 1
            mapped[start + i] = start + j
        elif i and d[i][j] == d[i-1][j] + 1:
            i -= 1
        else:
            j -= 1
            extras[start + i].append(start + j)
    return mapped, {gap: list(reversed(ids)) for gap, ids in extras.items()}


@dataclass
class Sentence:
    words: list
    external: dict
    internal: dict


def scan(text):
    words, external, internal = [], {}, {}
    end = 0
    for w in WORD.finditer(text):
        marks = punctuation(text[end:w.start()])
        if marks:
            external[len(words)] = marks
        apostrophes = tuple((i, c) for i, c in enumerate(w[0]) if c in "'’")
        if apostrophes:
            internal[len(words)] = apostrophes
        words.append(w[0])
        end = w.end()
    marks = punctuation(text[end:])
    if marks:
        external[len(words)] = marks
    return Sentence(words, external, internal)


def punctuation(s):
    return ''.join(c for c in s if unicodedata.category(c).startswith('P'))


@dataclass
class Observation:
    slots: list
    extras: dict
    punctuation: dict


def observe(ref, text):
    mapped, extra_ids = alignment(ref.words, text.words)
    slots = [None if j is None else text.words[j] for j in mapped]
    extras = {i:[text.words[j] for j in ids] for i,ids in extra_ids.items()}
    # Outside punctuation follows the next mapped reference word; terminal
    # punctuation always belongs to the end. Anchoring handles shifted indices
    # when the keyboard inserts a word earlier in the message.
    reverse = {j:i for i,j in enumerate(mapped) if j is not None}
    anchors = [len(ref.words)] * (len(text.words) + 1)
    for j in reversed(range(len(text.words))):
        anchors[j] = reverse.get(j, anchors[j+1])
    marks = {}
    for j, chars in text.external.items():
        key = ('gap', anchors[j])
        marks[key] = marks.get(key, '') + chars
    for j, marks_in_word in text.internal.items():
        if j in reverse:
            marks[('word', reverse[j])] = marks_in_word
    for gap, ids in extra_ids.items():
        for ordinal, j in enumerate(ids):
            if j in text.internal:
                marks[('insert', gap, ordinal)] = text.internal[j]
    return Observation(slots, extras, marks)


def score_sentence(row, output, ref, original, ref_punct):
    gold, typed = row['expected'], row['typed']
    if output == typed:
        final = original
    elif output == gold:
        final = Observation(ref.words, {}, ref_punct)
    else:
        final = observe(ref, scan(output))
    clean = typed == gold
    a = Counter(rows=1, exact=int(output == gold), clean_rows=int(clean),
                clean_exact=int(clean and output == gold), noisy_rows=int(not clean),
                noisy_exact=int(not clean and output == gold), changed_rows=int(typed != output),
                output_wrong_case_only_rows=int(output != gold and output.casefold() == gold.casefold()),
                ref_words=len(ref.words))
    for w, before, after in zip(ref.words, original.slots, final.slots):
        if w == before:
            a['intended_words'] += 1
            a['collateral_words'] += w != after
        else:
            a['damaged_slots'] += 1
            a['fixed_slots'] += w == after
            a['missed_unchanged_slots'] += before == after
            a['wrong_replacement_slots'] += w != after and before != after
            a['wrong_case_only_replacements'] += (w != after and before != after and
                                                  after is not None and w.casefold() == after.casefold())
        a['input_deleted_words'] += before is None
        a['output_deleted_words'] += after is None
        a['input_substituted_words'] += before is not None and before != w
        a['output_substituted_words'] += after is not None and after != w
        a['newly_deleted_intended_words'] += before == w and after is None
        a['output_case_only_substitutions'] += after is not None and after != w and after.casefold() == w.casefold()
    # Include zero counts even when an entire group contains only clean inputs.
    for field in ('intended_words', 'collateral_words', 'damaged_slots', 'fixed_slots',
                  'missed_unchanged_slots', 'wrong_replacement_slots', 'wrong_case_only_replacements'):
        a.setdefault(field, 0)
    a['collateral_rows'] = int(a['collateral_words'] > 0)
    a['wrong_replacement_rows'] = int(a['wrong_replacement_slots'] > 0)
    for field in ('input_inserted_words', 'output_inserted_words', 'new_inserted_words',
                  'removed_input_insertions', 'changed_input_insertions'):
        a[field] = 0
    for gap in original.extras.keys() | final.extras.keys():
        before, after = original.extras.get(gap, []), final.extras.get(gap, [])
        a['input_inserted_words'] += len(before)
        a['output_inserted_words'] += len(after)
        idx, extra_ids = alignment(before, after)
        a['removed_input_insertions'] += sum(j is None for j in idx)
        a['changed_input_insertions'] += sum(j is not None and before[i] != after[j] for i,j in enumerate(idx))
        a['new_inserted_words'] += sum(map(len, extra_ids.values()))
    for prefix in ('input','output'):
        a[prefix + '_word_edits'] = sum(a[prefix + '_' + s + '_words'] for s in ('inserted', 'deleted', 'substituted'))
    a['input_punctuation_exact'] = int(original.punctuation == ref_punct)
    a['output_punctuation_exact'] = int(final.punctuation == ref_punct)
    a['new_punctuation_damage_rows'] = int(original.punctuation == ref_punct != final.punctuation)
    a['punctuation_recovered_rows'] = int(original.punctuation != ref_punct == final.punctuation)
    a['input_punctuation_mismatch_sites'] = sum(original.punctuation.get(k) != ref_punct.get(k)
                                                for k in original.punctuation.keys() | ref_punct.keys())
    a['output_punctuation_mismatch_sites'] = sum(final.punctuation.get(k) != ref_punct.get(k)
                                                 for k in final.punctuation.keys() | ref_punct.keys())
    return a


def load_outputs(paths, ids):
    outputs = {}
    for path in paths:
        opener = gzip.open if path.suffix == '.gz' else open
        with opener(path, 'rt') as f:
            for line in f:
                row = json.loads(line)
                if row['id'] in outputs or not isinstance(row['final'], str):
                    raise ValueError(f'Duplicate ID or non-text result at {path}: {row["id"]}')
                outputs[row['id']] = row['final']
    missing, unexpected = ids - outputs.keys(), outputs.keys() - ids
    if missing or unexpected:
        raise ValueError(f'{len(missing)} missing and {len(unexpected)} unexpected outputs; '
                         f'first IDs {sorted(missing)[:3]}, {sorted(unexpected)[:3]}')
    return outputs


def groups(row):
    yield 'all'
    yield 'split/' + row['split']
    if 'kind' in row:
        yield 'kind/' + row['kind']
    if 'source' in row:
        yield 'source/' + row['source']


def score(cases, baseline, candidate=None, details=None):
    rows = json.loads(cases.read_bytes())
    ids = {r['id'] for r in rows}
    if len(ids) != len(rows) or not ids:
        raise ValueError('Empty input or duplicate fixture IDs')
    results = {'baseline':load_outputs(baseline, ids)}
    if candidate:
        results['candidate'] = load_outputs(candidate, ids)
    totals = {label:defaultdict(Counter) for label in results}
    paired = defaultdict(Counter)
    for row in rows:
        ref = scan(row['expected'])
        ref_punct = observe(ref, ref).punctuation
        original = observe(ref, scan(row['typed']))
        labels = list(groups(row))
        scores = {}
        for label, outputs in results.items():
            scores[label] = score_sentence(row, outputs[row['id']], ref, original, ref_punct)
            for group in labels:
                totals[label][group].update(scores[label])
        if candidate:
            a, b = scores.values()
            for g in labels:
                paired[g].update(dict(newly_exact=int(a['exact'] < b['exact']), lost_exact=int(a['exact'] > b['exact']),
                                      fewer_word_edits=int(a['output_word_edits'] > b['output_word_edits']),
                                      more_word_edits=int(a['output_word_edits'] < b['output_word_edits']),
                                      changed_output=int(results['baseline'][row['id']] != results['candidate'][row['id']])))
        if details:
            detail = dict(row, outputs={label:v[row['id']] for label,v in results.items()}, scores=scores)
            details.write(json.dumps(detail, ensure_ascii=False) + '\n')
    report = dict(fixture=cases.name, totals=totals)
    if candidate:
        report['paired'] = paired
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path)
    parser.add_argument('--baseline', type=Path, nargs='+', required=True)
    parser.add_argument('--candidate', type=Path, nargs='+')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--details', type=argparse.FileType('w'), help='Write one JSONL diagnostic record per input')
    args = parser.parse_args()
    result = json.dumps(score(args.cases, args.baseline, args.candidate, args.details), sort_keys=True, indent=2)
    if args.report:
        args.report.write_text(result + '\n')
    else:
        print(result)
