"""Aggregate lexical and adjacent-word support for boundary reviews (training partition only)."""
import csv
import hashlib
import sys
from collections import Counter
from pathlib import Path
from paired_text import engine, key, pairs

def train(source):
    skip = set()
    for n in (15,16):
        with (engine.parent/f'Benchmarks/build{n}/cases.tsv').open() as f:
            skip.update(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']]))
                        for r in csv.DictReader(f,delimiter='\t'))
    seen=set()
    counts=Counter()
    for _, clean in pairs(source):
        normalized=key(clean)
        if normalized in seen or normalized in skip or hashlib.sha256(normalized.encode()).digest()[0]<38: continue
        seen.add(normalized)
        words=normalized.split()
        if not words: continue
        terms=set(words)
        terms.update(a+' '+b for a,b in zip(['^']+words,words))
        counts.update(terms)
    # Keep even one sighting of a whole token to avoid splitting deliberate spellings.
    with (engine/'model/boundary-counts.tsv').open('w') as f:
        for term,n in sorted(counts.items()):
            if ' ' not in term or n>=2: f.write(f'{term}\t{min(n,65535)}\n')
    print('Trained on',len(seen),'different normalized messages.')
if __name__=='__main__': train(Path(sys.argv[1]))
