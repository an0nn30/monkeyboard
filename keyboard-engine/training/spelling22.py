"""Fit an on-device word noisy channel and bidirectional local-context ranker.

Only the original SHA-256 training partition is eligible. Independent buckets of
clean sentences supply counts, ranking examples and an internal diagnostic. The
existing English word-frequency table supplies vocabulary outside the paired corpus.
Use the project's numpy/scipy environment. The Rust training entry point exposes
exactly the features that ship. No sentences or per-message identifiers are exported.
"""
import argparse
import ctypes
import functools
import hashlib
import math
import random
import re
import struct
import subprocess
import tempfile
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

from paired_text import engine, key, pairs, tokens

OUT = engine / 'model/spelling22'
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
START = '^'


def partition(clean):
    digest = hashlib.sha256(key(clean).encode()).digest()
    if digest[0] < 38:
        return 'reserved'
    if digest[1] < 16:
        return 'evaluate'
    return 'fit' if digest[1] < 66 else 'counts'


def word_pairs(noisy, clean):
    """Equal-width replaced spans align positionally; skip joins and splits."""
    for tag, i, j, k, l in SequenceMatcher(None, noisy, clean, autojunk=False).get_opcodes():
        if tag in ('equal', 'replace') and j - i == l - k:
            yield from zip(range(i, j), range(k, l))


@functools.lru_cache(maxsize=100000)
def alignment(clean, noisy):
    """Minimum edit path with a single operation for an adjacent transposition."""
    a, b = len(clean), len(noisy)
    dp = [[0] * (b + 1) for _ in range(a + 1)]
    for i in range(a + 1):
        dp[i][0] = i
    for j in range(b + 1):
        dp[0][j] = j
    for i in range(1, a + 1):
        for j in range(1, b + 1):
            dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1,
                           dp[i-1][j-1] + (clean[i-1] != noisy[j-1]))
            if i >= 2 and j >= 2 and clean[i-2:i] == noisy[j-2:j][::-1]:
                dp[i][j] = min(dp[i][j], dp[i-2][j-2] + 1)
    edits = []
    i, j = a, b
    while i or j:
        if i and j and clean[i-1] == noisy[j-1] and dp[i][j] == dp[i-1][j-1]:
            i, j = i-1, j-1
            continue
        if i >= 2 and j >= 2 and clean[i-2:i] == noisy[j-2:j][::-1] and dp[i][j] == 1 + dp[i-2][j-2]:
            x, y = 2, 2
        elif i and j and dp[i][j] == 1 + dp[i-1][j-1]:
            x, y = 1, 1
        elif i and dp[i][j] == 1 + dp[i-1][j]:
            x, y = 1, 0
        else:
            x, y = 0, 1
        edits.append((i-x, clean[i-x:i], noisy[j-y:j]))
        i, j = i-x, j-y
    return tuple(edits)


def counts(source):
    freq = Counter(); surface = defaultdict(Counter); seen = set(); phrases = Counter()
    channel = Counter(); denominators = Counter(); noisy_pairs = Counter(); fit = []; evaluate = []
    raw_count = Counter()
    for raw, gold in pairs(source):
        part = partition(gold)
        raw_count[part] += 1
        if part == 'reserved':
            continue
        if part != 'counts':
            (fit if part == 'fit' else evaluate).append((raw, gold))
            continue
        clean, noisy = tokens(gold), tokens(raw)
        canonical = key(gold)
        if canonical not in seen:
            seen.add(canonical)
            seq = [START] + clean
            for n in (2, 3):
                phrases.update(zip(*(seq[d:] for d in range(n))))
            freq.update(seq)
            for i, w in enumerate(WORD.findall(gold.replace('’', "'"))):
                if i or w.lower().startswith("i'") or w.lower() == 'i':
                    surface[w.lower()][w] += 1
        for i, j in word_pairs(noisy, clean):
            x, y = noisy[i], clean[j]
            if max(len(x), len(y)) > 28:
                continue
            for z in y:
                denominators[z] += 1
            denominators[''] += len(y) + 1
            denominators.update(y[p:p+2] for p in range(len(y)-1))
            if x == y:
                continue
            edits = alignment(y, x)
            if len(edits) > max(2, len(y)//2):
                continue
            noisy_pairs[x, y] += 1
            for _, a, b in edits:
                channel[a, b] += 1
    print('partition pairs', dict(raw_count), 'distinct count sentences', len(seen), flush=True)
    english = Counter({w: int(n) for w, n in (s.split('\t') for s in (engine/'model/words.tsv').read_text().splitlines())})
    everyday = set((engine/'training/everyday-words.txt').read_text().split())
    # Words used intentionally in disjoint fitting messages can safely act as
    # literals. They contribute no counts, casing priors or context features.
    fit_words = {w for _, clean in fit for w in tokens(clean)}
    vocab = sorted(set(freq) | set(english) | everyday | fit_words)
    ids = {w: i for i, w in enumerate(vocab)}
    assert len(vocab) < 65535
    with (OUT/'vocab.tsv').open('w') as f:
        for w in vocab:
            s = surface[w]; case, n = s.most_common(1)[0] if s else (w, 0)
            display = case if n >= 2 and n >= .88 * s.total() else w
            # Generic frequency outside this collection balances its narrower topic mix.
            f.write(f'{w}\t{display}\t{freq[w]}\t{english[w]}\n')
    with (OUT/'contexts.bin').open('wb') as f:
        for term, count in sorted(((tuple(ids[w]+1 for w in t),v) for t,v in phrases.items() if v >= 2), key=lambda row: (len(row[0]), row[0])):
            code = 0
            for i in term:
                code = code * 65536 + i
            f.write(struct.pack('<QH', code, min(65535, count)))
    with (OUT/'edits.tsv').open('w') as f:
        for (a, b), n in sorted(channel.items()):
            if n < 2:
                continue
            p = (n + .25) / (denominators[a] + 40)
            f.write(f'{a}\t{b}\t{-math.log(p):.5f}\n')
    with (OUT/'observed.tsv').open('w') as f:
        for (x, y), n in sorted(noisy_pairs.items()):
            if n >= 2:
                f.write(f'{x}\t{ids[y]}\t{n}\n')
    print('vocabulary',len(vocab),'error observations',sum(noisy_pairs.values()),flush=True)
    return fit, evaluate


FEATURES = 24


def compile_library(tmp, training):
    path = tmp / ('features.dylib' if training else 'inference.dylib')
    args = ['rustc','--edition=2021','--crate-type=cdylib','-C','opt-level=3']
    if training:
        args.extend(['--cfg','spelling22_training'])
    subprocess.run([*args,str(engine/'src/spelling22.rs'),'-o',str(path)], check=True)
    return ctypes.CDLL(str(path))


def fit_model(lib, rows):
    import numpy as np
    from scipy.optimize import minimize
    rng = random.Random(220722)
    words = {s.split('\t')[0]:i for i,s in enumerate((OUT/'vocab.tsv').read_text().splitlines())}
    # Reusable memory for a query. Select all aligned typo examples, a broad
    # sample of clean words, and clean words masked from the lexicon to teach
    # the decoder how to abstain on an unfamiliar literal.
    cap = 2048
    ids = np.empty(cap,np.int32); matrix = np.empty((cap,FEATURES),np.float32)
    feature = lib.mb22_features
    feature.argtypes = [ctypes.c_char_p]*3+[ctypes.c_bool,ctypes.c_bool,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t]
    feature.restype = ctypes.c_size_t
    chunks = []; sizes = []; labels = []; used = Counter()
    for raw,gold in rows:
        x = WORD.findall(raw.replace('’',"'")); y = tokens(gold)
        for i,j in word_pairs([w.lower() for w in x],y):
            correct = x[i].lower()==y[j]
            if correct and rng.random()>.25:
                continue
            hide = correct and rng.random()<.2
            # Drop topic-specific frequencies, observed word pairs and n-grams
            # together. These examples fit the broad dictionary fallback.
            generic = rng.random()<.32
            # Train both immediate and later review, using noisy neighboring text.
            left = ' '.join(x[max(0,i-2):i]); right = ' '.join(x[i+1:i+3]) if rng.random()<.53 else ''
            n = feature(left.encode(),x[i].encode(),right.encode(),hide,generic,ids.ctypes.data,matrix.ctypes.data,cap)
            if n<2:
                continue
            target = 0 if correct else next((k for k in range(1,n) if ids[k]==words.get(y[j],-2)),0)
            used['literal' if correct else 'gold in pool' if target else 'outside pool']+=1
            labels.append(target); sizes.append(n); chunks.append(matrix[:n].copy())
    print('ranking examples',dict(used),'total alternatives',sum(sizes),flush=True)
    x = np.concatenate(chunks).astype(np.float64);del chunks
    sizes = np.asarray(sizes); starts=np.cumsum(np.r_[0,sizes[:-1]])
    gold = x[starts+labels].sum(axis=0)
    def objective(w):
        score = x@w
        peak = np.maximum.reduceat(score,starts)
        exp = np.exp(score-np.repeat(peak,sizes))
        total = np.add.reduceat(exp,starts)
        prob = exp/np.repeat(total,sizes)
        reg = .0008
        return ((np.log(total)+peak).sum()-gold@w)/len(starts)+reg*(w@w)/2, (x.T@prob-gold)/len(starts)+reg*w
    result=minimize(objective,np.zeros(FEATURES),jac=True,method='L-BFGS-B',options={'maxiter':300,'ftol':1e-11,'gtol':.000025})
    assert result.success, result.message
    (OUT/'ranker.txt').write_text(' '.join(f'{v:.8f}' for v in result.x)+'\n')
    print('ranker loss',round(result.fun,6),'iterations',result.nit,flush=True)


def evaluate(lib,rows):
    fn = lib.mb_spelling22_v1
    fn.argtypes = [ctypes.c_char_p]*3+[ctypes.c_void_p,ctypes.c_size_t];fn.restype=ctypes.c_int32
    output=ctypes.create_string_buffer(256); totals=Counter()
    def check(left,raw,right):
        status=fn(left.encode(),raw.encode(),right.encode(),output,len(output))
        assert status>=0
        return output.value.decode().lower() if status else None
    for raw,gold in rows:
        x=WORD.findall(raw.replace('’',"'"));y=WORD.findall(gold.replace('’',"'"))
        for i,j in word_pairs([w.lower() for w in x],[w.lower() for w in y]):
            correct=x[i].lower()==y[j].lower();left=' '.join(x[max(0,i-2):i]);right=' '.join(x[i+1:i+3]);
            for mode,following in (('immediate',''),('context',right)):
                chosen=check(left,x[i],following)
                tag='clean' if correct else 'short' if len(x[i])<=3 else 'long'
                outcome='kept' if chosen is None else 'fixed' if chosen==y[j].lower() else 'incorrect'
                totals[mode,tag,outcome]+=1
    for mode in ('immediate','context'):
        for tag in ('clean','short','long'):
            print(mode,tag,{k:totals[mode,tag,k] for k in ('fixed','kept','incorrect')},flush=True)


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('source',type=Path);args=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    fit,evaluation=counts(args.source)
    # A valid coefficient vector is needed to compile the feature extractor
    # before fitting. Replace it with the optimized vector before the audit.
    (OUT/'ranker.txt').write_text(' '.join(['0']*FEATURES)+'\n')
    with tempfile.TemporaryDirectory() as path:
        tmp=Path(path)
        fit_model(compile_library(tmp,True),fit)
        evaluate(compile_library(tmp,False),evaluation)

if __name__=='__main__':
    main()
