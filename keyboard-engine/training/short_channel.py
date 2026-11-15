"""Learn character confusions, empirical word-error priors and contextual n-grams."""
import bz2,csv,hashlib,json,re,sys
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path
from paired_text import pairs,tokens,key,engine

def operation(noisy,clean):
    if noisy==clean:return None
    if len(noisy)==len(clean):
        dif=[i for i,(a,b) in enumerate(zip(noisy,clean)) if a!=b]
        if len(dif)==1:return clean[dif[0]]+noisy[dif[0]]
        if len(dif)==2 and dif[1]==dif[0]+1 and noisy[dif[0]:dif[1]+1]==clean[dif[0]:dif[1]+1][::-1]:return '~'+clean[dif[0]]
    if len(clean)==len(noisy)+1:
        for i,c in enumerate(clean):
            if clean[:i]+clean[i+1:]==noisy:return c+'-'
    if len(noisy)==len(clean)+1:
        for i,c in enumerate(noisy):
            if noisy[:i]+noisy[i+1:]==clean:return '+'+c

def train(source,dialogs):
    block=set()
    for v in [15,16]:
        for r in csv.DictReader((engine.parent/f'Benchmarks/build{v}/cases.tsv').open(),delimiter='\t'):
            block.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    corpus=set();errors=Counter();pairs_used=0; short=Counter();false_tokens=Counter();err_pairs=Counter()
    for x,y in pairs(source):
        k=key(y)
        if k in block or hashlib.sha256(k.encode()).digest()[0]<38:continue
        corpus.add(k);a,b=tokens(x),tokens(y);pairs_used+=1
        for tag,i,j,m,n in SequenceMatcher(None,a,b,autojunk=False).get_opcodes():
            if tag=='equal':
                short.update(w for w in b[m:n] if w.isalpha() and len(w)<=4)
            if tag!='replace' or j-i!=1 or n-m!=1 or not a[i].isalpha() or not b[m].isalpha():continue
            op=operation(a[i],b[m])
            if op:
                errors[op]+=1
                if 2<=len(a[i])<=3 and 1<=len(b[m])<=4:
                    false_tokens[a[i]]+=1;err_pairs[a[i],b[m]]+=1
    with (engine/'model/short-channel.tsv').open('w') as fp:
        for op,n in sorted(errors.items()):fp.write(f'{op}\t{n}\n')
    with (engine/'model/short-literals.tsv').open('w') as fp:
        for w in sorted(set(short)|set(false_tokens)):
            if len(w)<=4:fp.write(f'{w}\t{short[w]}\t{false_tokens[w]}\n')
    with (engine/'model/short-observations.tsv').open('w') as f:
        for (a,b),n in sorted(err_pairs.items()):
            if n>=2:f.write(f'{a}:{b}\t{n}\n')
    assert hashlib.sha256(dialogs.read_bytes()).hexdigest()=='1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d'
    held=set()
    def public(s,bucket):
        t=key(s)
        if 3<=len(t.split())<=32 and len(s)<=200:
            (held if bucket<26 else corpus).add(t)
    with bz2.open(engine/'training/eng_sentences_CC0.tsv.bz2','rt') as f:
        for line in f:
            _,lang,s,_=line.rstrip('\n').split('\t',3)
            if lang=='eng':public(s,hashlib.sha256(key(s).encode()).digest()[0])
    for d in json.loads(dialogs.read_bytes()):
        bucket=hashlib.sha256(d['conversation_id'].encode()).digest()[0]
        for u in d['utterances']:
            if u['speaker']=='USER':
                for s in re.split(r'[.!?;:]',u['text']):public(s,bucket)
    counts=Counter()
    for sentence in corpus-held-block:
        line=['^']+sentence.split()+['$']
        for n in (1,2,3):
            counts.update(' '.join(line[i:i+n]) for i in range(len(line)-n+1) if n==1 or any(len(w)<=4 for w in line[i:i+n]))
    with (engine/'model/short-phrases.tsv').open('w') as f:
        for k,n in sorted(counts.items()):
            if n>=2:f.write(f'{k}\t{n}\n')
    print('training pairs',pairs_used,'one-edit observations',sum(errors.values()),'edit classes',len(errors),'short source spellings',len(false_tokens))
if __name__=='__main__':train(*map(Path,sys.argv[1:]))
