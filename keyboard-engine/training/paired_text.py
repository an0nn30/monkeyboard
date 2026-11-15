"""Fit aggregate typo counts and phrase counts from S:/C: pairs. No raw sentences ship."""
import argparse
import csv
import hashlib
import random
import re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

engine = Path(__file__).resolve().parents[1]
bench = engine.parent / "Benchmarks/build16"
def tokens(s):
    return re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower().replace("’", "'"))
def key(s):
    return " ".join(tokens(s))
def pairs(file):
    pending = None
    for n, line in enumerate(file.read_text().splitlines(), 1):
        if line.startswith("S: "):
            if pending is not None: raise ValueError(f"Missing C: before line {n}")
            pending = line[3:]
        elif line.startswith("C: "):
            if pending is None: raise ValueError(f"Missing S: before line {n}")
            yield pending, line[3:]
            pending = None
    if pending is not None: raise ValueError("Unpaired last sentence")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source",type=Path)
    args = ap.parse_args()
    vocab = set((engine/"research/decoder15m/vocab.txt").read_text().splitlines())
    safe = {l.split("\t")[0] for l in (engine/"model/decoder15m/decoder-vocab.tsv").read_text().splitlines()
            if l.endswith("\t1")}
    english = {line.split("\t")[0] for line in (engine/"model/words.tsv").read_text().splitlines()}
    noise = defaultdict(lambda: defaultdict(set))
    phrase = defaultdict(Counter)
    reserved = defaultdict(list)
    seen = set()
    lowercase_targets = set()
    counts = Counter()
    # Exclude exact benchmark messages in all splits, including development.
    protected = {key(" ".join((r["left"], r["gold"].split("|")[0], r["right"]))) for r in
                 csv.DictReader((engine.parent/"Benchmarks/build15/cases.tsv").open(), delimiter="\t")}
    for source, clean in pairs(args.source):
        counts["pairs"] += 1
        words = tokens(clean)
        canonical = " ".join(words)
        if not words or canonical in protected:
            counts["excluded"] += 1
            continue
        digest = hashlib.sha256(canonical.encode()).digest()
        if digest[0] < 38:
            reserved[canonical].append((source,clean))
            continue
        counts["training pairs"] += 1
        clean_words = re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)*", clean.replace("’", "'"))
        lowercase_targets.update(w for w in clean_words[1:] if w.islower())
        if canonical not in seen:
            for i,w in enumerate(words):
                if w not in safe: continue
                for n in range(1, min(4,i)+1):
                    phrase[" ".join(words[i-n:i])][w]+=1
            seen.add(canonical)
        noisy = tokens(source)
        for tag,i,j,k,l in SequenceMatcher(None,noisy,words,autojunk=False).get_opcodes():
            if tag != "replace" or j-i!=1 or l-k not in (1,2): continue
            typed, gold = noisy[i], " ".join(words[k:l])
            if all(w in vocab for w in words[k:l]):noise[typed][gold].add(canonical)
    dest = engine/"model/paired-edits.tsv"
    with dest.open("w") as f:
        for w, alternatives in sorted(noise.items()):
            # Statistical support in at least three different clean messages.
            # Accepted words and short acronyms stay protected in the keyboard.
            if w in english or not w.isalpha() or not 4<=len(w)<=24:continue
            votes=sorted(((len(frames),gold) for gold,frames in alternatives.items()),reverse=True)
            n,gold=votes[0]
            if (n>=3 and n>=5*sum(c for c,_ in votes[1:]) and abs(len(w)-len(gold))<=3
                    and all(t in lowercase_targets for t in gold.split())):
                f.write(f"{w}\t{gold}\n")
    with (engine/"model/paired-next.tsv").open("w") as f:
        for ctx, cs in sorted(phrase.items()):
            ranked=sorted(cs.items(),key=lambda t:(-t[1],t[0]))
            if ranked[0][1]>=3:
                values=" ".join(f"{w}:{min(n,50)}" for w,n in ranked[:6] if n>=2)
                f.write(f"{ctx}\t{values}\n")
    # One marked decision per reserved clean sentence. Unlike the training table,
    # evaluation admits words outside the vocabulary and intentional real words.
    out=[]; quotas=Counter()
    for clean in sorted(reserved,key=lambda s:hashlib.sha256(("mb16check/"+s).encode()).digest()):
        source, target = sorted(reserved[clean])[0]
        word_pattern = r"[A-Za-z]+(?:'[A-Za-z]+)*"
        noisy = re.findall(word_pattern, source.replace("’", "'"))
        words = re.findall(word_pattern, target.replace("’", "'"))
        rng=random.Random(clean); tag=['fix','keep','next'][rng.randrange(3)]
        if quotas[tag]>={'fix':420,'keep':180,'next':240}[tag]:continue
        if tag=='fix':
            valid=[(i,j,k,l) for t,i,j,k,l in SequenceMatcher(None,noisy,words,autojunk=False).get_opcodes()
                   if t=='replace' and j-i==1 and 1<=l-k<=2]
            if not valid:continue
            i,j,k,l=rng.choice(valid);typed=noisy[i];gold=" ".join(words[k:l])
        else:
            if len(words)<4:continue
            k=rng.randrange(2,len(words));l=k+1;gold=words[k];typed=gold if tag=='keep' else ''
        quotas[tag]+=1
        out.append(['holdout','user_pairs',tag,'mixed','paired_'+tag,' '.join(words[:k]),typed,gold,' '.join(words[l:])])
    assert quotas=={'fix':420,'keep':180,'next':240},quotas
    with (bench/'cases.tsv').open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n')
        w.writerow('split origin task difficulty kind left typed gold right'.split());w.writerows(out)
    print(dict(counts),'training clean',len(seen),'reserved clean',len(reserved),'reserved pairs',sum(map(len,reserved.values())))
    print('retained spelling entries',sum(1 for _ in dest.open()),'phrase contexts',sum(1 for _ in (engine/'model/paired-next.tsv').open()))
if __name__=='__main__':main()
