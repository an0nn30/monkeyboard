"""Score the final text; require exactly one result per frozen input from both builds."""
import argparse
import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

root = Path(__file__).resolve().parent
def align(gold, text):
    # Align case-sensitive words, keeping apostrophes and numbers. Costs are
    # unit insert/delete/substitute; prefer a diagonal when paths tie.
    a = re.findall(r"[^\W_]+(?:['’][^\W_]+)*", gold)
    b = re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text)
    d = [list(range(len(b)+1))]
    for i,x in enumerate(a,1):
        row = [i]
        for j,y in enumerate(b,1):
            row.append(min(d[i-1][j-1] + (x!=y), d[i-1][j]+1, row[j-1]+1))
        d.append(row)
    i,j = len(a),len(b)
    mapped = [None]*len(a)
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1]+(a[i-1]!=b[j-1]):
            mapped[i-1] = b[j-1]
            i-=1; j-=1
        elif i and d[i][j] == d[i-1][j]+1: i-=1
        else: j-=1
    return a,mapped,d[-1][-1]

def load(path):
    outputs = {}
    for line in path.read_text().splitlines():
        row = json.loads(line)
        assert row['id'] not in outputs
        outputs[row['id']] = row['final']
    return outputs

def score(fixtures, files):
    with fixtures.open() as f:
        rows = list(csv.DictReader(f,delimiter='\t'))
    keys = {r['id'] for r in rows}
    assert len(keys) == len(rows)
    results = [load(path) for path in files]
    assert all(set(res)==keys for res in results), 'Missing or extra output IDs'
    totals = defaultdict(Counter)
    for row in rows:
        k, gold, typed = row['id'],row['expected'],row['typed']
        ref, orig, initial = align(gold,typed)
        for path,res in zip(files,results):
            out = res[k]
            _,final,remaining = align(gold,out)
            a = totals[(row['split'],row['kind'],path.stem)]
            a.update({'sentences':1,'exact':int(out==gold),'input_edits':initial,'remaining_edits':remaining})
            for w,before,after in zip(ref,orig,final):
                if w==before:
                    a['intended']+=1
                    a['changed_intended']+=int(w!=after)
                else:
                    a['typo_slots']+=1
                    a['fixed']+=int(w==after)
                    wrong = w!=after and before!=after
                    a['wrong_replacement']+=int(wrong)
                    a['wrong_case_only']+=int(wrong and after is not None and w.casefold()==after.casefold())
    for k,counts in totals.items():print(*k,json.dumps(dict(counts),sort_keys=True),sep='\t')
    for group in [('holdout','noisy'),('holdout','clean'),('authored','noisy'),('authored','clean')]:
        units = [r for r in rows if (r['split'],r['kind'])==group]
        old,new = results
        win = sum(old[r['id']]!=r['expected']==new[r['id']] for r in units)
        loss = sum(old[r['id']]==r['expected']!=new[r['id']] for r in units)
        print(*group,'newly exact',win,'lost exact',loss)
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--cases',type=Path,default=root/'sentences.tsv')
    ap.add_argument('files',type=Path,nargs=2,default=None)
    args=ap.parse_args()
    score(args.cases,args.files)
