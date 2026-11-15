"""Prepare corpus partitions and frozen full-sentence typing challenges; no phone data."""
import argparse, bz2, csv, hashlib, json, random, re, sys
from pathlib import Path
from collections import Counter, defaultdict
here = Path(__file__).resolve().parent
root = here.parents[1]
sys.path.insert(0,str(root/'keyboard-engine/training'))
from paired_text import key, pairs
FILES = {'flights':'86b37b5ae25f530fd18ced78800d30c3b54f7b34bb208ecb51842718f04e760b','hotels':'975b0242f1e37ea1ab94ccedd7e0d6ee5831599d5df1f16143e71110d6c6006a','music':'e5db60d6576fa010bef87a70a8b371d293d48cde8524c1d3ed7c3022f079d95d','sports':'8191531bfa5a8426b1508c396ab9886a19c7c620b443c436ec10d8d4708d0eac','movies':'6f67c9a1f04abc111186e5bcfbe3050be01d0737fd6422901402715bc1f3dd0d','restaurant-search':'fb9735f89e7ebc7c877f976da4c30391af6a6277991b597c0755564657ff8f47','food-ordering':'0a042e566a816a5d0abebe6f7e8cfd6abaa89729ffc42f433d327df7342b12f8','woz-dialogs':'cd3bc4e968487315d412c044d30af2bf0a4b33c3ef8b74c589f1e1fa832bf72f'}
def digest(x): return hashlib.sha256(x.encode()).digest()
def prepare(data, source, self_dialogs, work, prefix="", include_replies_excluding=None):
    frozen_train=set(include_replies_excluding.read_text().splitlines()) if include_replies_excluding else set()
    if include_replies_excluding: assert prefix, "Supplemental testing only"
    blocked = {key(s) for pair in pairs(source) for s in pair}
    for f in (root/'Benchmarks').rglob('*.tsv'):
        if here in f.parents:
            earlier={'dev.tsv','blind.tsv','paired.tsv'} if prefix else set()
            if prefix=='audit-': earlier.update({'confirmation-dev.tsv','confirmation-blind.tsv'})
            if f.name not in earlier:continue
        for r in csv.DictReader(f.open(),delimiter='\t'):
            blocked.update(key(r[c]) for c in ('typed','expected','sentence','text','prompt','context') if r.get(c))
            if all(r.get(c) for c in ('left','gold','right')):
                blocked.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    with bz2.open(root/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as fp:
        blocked.update(key(l.split('\t')[2]) for l in fp)
    assert hashlib.sha256(self_dialogs.read_bytes()).hexdigest()=='1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d'
    for d in json.loads(self_dialogs.read_bytes()):
        for u in d['utterances']: blocked.update(map(key,re.split(r'[.!?;:]',u['text'])))
    buckets=[{}, {}, {}]
    for name,sha in sorted(FILES.items()):
        raw=(data/(name+'.json')).read_bytes(); assert hashlib.sha256(raw).hexdigest()==sha,name
        for d in json.loads(raw):
            ident=d['conversation_id']; b=digest(ident)[0]; group=0 if b>=64 else 1 if b>=32 else 2
            for u in d['utterances']:
                for s in re.findall(r'[^.!?;:]+[.!?]?',u['text']):
                    s=s.strip().replace('’',"'"); k=key(s)
                    if k in blocked or not 4<=len(k.split())<=30 or not re.fullmatch(r"[A-Za-z][a-zA-Z ,'.?!-]{5,185}",s):continue
                    if group and ((u['speaker']!='USER' and not (include_replies_excluding and group==2)) or k in frozen_train or s[-1] not in '.?!' or '  ' in s):continue
                    buckets[group].setdefault(k,(s,name,ident))
    train,dev,test=buckets
    for k in test: train.pop(k,None);dev.pop(k,None)
    for k in dev:train.pop(k,None)
    work.mkdir(exist_ok=True,parents=True)
    def dump(name,rows): (work/name).write_text(''.join(x+'\n' for x in sorted(rows)))
    dump('train.txt',train);dump('validation.txt',dev)
    print('Distinct sentences by partition:',*[len(b) for b in buckets],flush=True)
    used=set()
    for name,pool,scale in [('dev',dev,1),('blind',test,3)]:
        out=[]
        groups=[('be-by',22),('if-of',42),('id-is',42),('od-of',42),('ti-to',32),('other-short',55),('long-typo',68),('join',160),('keep-be',55),('keep-if',35),('clean',280)]
        for group,quota in groups:
            count=0
            for k in sorted(pool,key=lambda s:digest(prefix+name+'/'+group+'/'+s)):
                if k in used:continue
                s,domain,ident=pool[k]; typed=s; gap=slot=''
                ws=list(re.finditer(r"[A-Za-z]+(?:'[A-Za-z]+)*",s)); rnd=random.Random(digest(name+'/'+s))
                if group=='join':
                    gaps=[i for i,ch in enumerate(s) if ch==' ' and s[i-1].isalpha() and s[i+1].isalpha()]
                    if not gaps:continue
                    gap=rnd.choice(gaps);typed=s[:gap]+s[gap+1:]
                elif group in ('other-short','long-typo'):
                    opts=[(i,m) for i,m in enumerate(ws) if m[0].islower() and m[0].isalpha() and (len(m[0]) in (2,3) if group=='other-short' else 5<=len(m[0])<=12)]
                    if not opts:continue
                    slot,m=rnd.choice(opts);w=m[0];j=rnd.randrange(len(w));op=rnd.randrange(4)
                    if op==0:err=w[:j]+w[j+1:]
                    elif op==1 and j:err=w[:j-1]+w[j]+w[j-1]+w[j+1:]
                    elif op==2:err=w[:j]+w[j]+w[j:]
                    else:
                        layout=['qwertyuiop','asdfghjkl','zxcvbnm'];row=next(t for t in layout if w[j] in t);q=row.index(w[j]);err=w[:j]+rnd.choice([row[z] for z in (q-1,q+1) if 0<=z<len(row)])+w[j+1:]
                    if err==w:continue
                    typed=s[:m.start()]+err+s[m.end():]
                elif group!='clean':
                    noisy,gold=group.split('-');opts=[(i,m) for i,m in enumerate(ws) if m[0]==gold and i>0 and i+1<len(ws)]
                    if not opts:continue
                    i,m=rnd.choice(opts)
                    if noisy!='keep':slot=i;typed=s[:m.start()]+noisy+s[m.end():]
                if typed!=s and (key(typed) in used or key(typed) in train or key(typed) in blocked):continue
                used.update([key(typed),k]);out.append(dict(id=f'{name}-{group}-{count}',split=name,kind=group,typed=typed,expected=s,gap=gap,slot=slot,domain=domain,dialogue=ident));count+=1
                if count==quota*scale:break
        with (here/(prefix+name+'.tsv')).open('w') as fp:
            writer=csv.DictWriter(fp,fieldnames=out[0],delimiter='\t',lineterminator='\n');writer.writeheader();writer.writerows(out)
        (work/(name+'.json')).write_text(json.dumps(out));print(name,Counter(r['kind'] for r in out))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--prefix',default='');p.add_argument('--include-replies-excluding',type=Path);[p.add_argument(a,type=Path) for a in ('data','source','self_dialogs','work')];prepare(**vars(p.parse_args()))
