"""Targeted challenge outside the headline benchmark, with synthetic errors and clean controls."""
import bz2
import csv
import re
import sys
from collections import Counter
from make_sentences import here, hashed, key, pairs, rows

def collect(source):
    # Exclude all user pairs (including near-identical noisy variants by case/spacing)
    # and prior benchmark targets. Public-source bucket matches decoder training.
    skip = {key(text) for pair in pairs(source) for text in pair}
    for version in (15,16):
        for r in rows(here.parent/f'build{version}/cases.tsv'):
            skip.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    for r in rows(here/'sentences.tsv'):
        skip.update([key(r['typed']),key(r['expected'])])
    public = here.parents[1]/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2'
    assert hashed_bytes(public) == 'c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca'
    pool={}
    with bz2.open(public,'rt') as f:
        for line in f:
            _,lang,text,_=line.rstrip('\n').split('\t',3)
            target=key(text)
            if lang!='eng' or target in skip or hashed(target)[0]>=26 or not 5<=len(target.split())<=18:continue
            if not re.fullmatch(r"[A-Za-z ,'’]+[.?!]",text): continue
            pool[target]=text
    counts=Counter()
    # The small bundled English source has few unused pronoun examples.
    # Use separate bins for joins and their unmodified public controls.
    for target in sorted(pool,key=lambda t:hashed('mb18/ambiguity/'+t)):
        text=pool[target]
        spans=[m.span(1) for m in re.finditer(r"\b[a-z]{2,}( )(?=[a-z]{2,}\b)",text)]
        if not spans: continue
        group='join' if hashed('challenge-kind/'+target)[0]%2==0 else 'clean'
        if counts[group]>=120: continue
        a,b=spans[int.from_bytes(hashed('challenge-cut/'+target)[:2],'big')%len(spans)]
        typed=text[:a]+text[b:] if group=='join' else text
        if group=='join' and key(typed) in skip: continue
        counts[group]+=1
        yield (group+str(counts[group]),group,'noisy' if group=='join' else 'clean',typed,text)
    assert counts=={'join':120,'clean':120},counts

    # Sample previously unused corrected messages from the paired corpus. Both
    # their clean and corrupted forms use a target excluded from training.
    prior=set(pool)
    for version in (15,16):
        prior.update(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']]))
                     for r in rows(here.parent/f'build{version}/cases.tsv'))
    for path in (here.parent/'build17/sentences.tsv',here.parent/'build17/confirmation.tsv',here/'sentences.tsv'):
        for r in rows(path): prior.update([key(r['typed']),key(r['expected'])])
    targets={}
    for _,ref in pairs(source):
        target=key(ref)
        if target in prior or hashed(target)[0]>=38 or not re.search(r'\bis (?:a|an) \w+',ref):continue
        targets.setdefault(target,ref)
    for i,target in enumerate(sorted(targets,key=lambda t:hashed('mb18/copula/'+t))[:100]):
        ref=targets[target]
        yield (f'copula{i}', 'copula','noisy',re.sub(r'\bis (?=(?:a|an) \w+)','us ',ref,count=1),ref)
    assert len(targets)>=20,len(targets)

def hashed_bytes(path):
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()
if __name__=='__main__':
    from pathlib import Path
    with (here/'challenge.tsv').open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n')
        w.writerow(['id','split','kind','typed','expected'])
        w.writerows(collect(Path(sys.argv[1])))
