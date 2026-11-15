"""Freeze matched typo/keep samples from conversations reserved before training."""
import bz2, csv, hashlib, json, re, sys
from pathlib import Path
from collections import Counter
here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parents[1]/'keyboard-engine/training'))
from paired_text import key, pairs
def sha(s): return hashlib.sha256(s.encode()).digest()
def cases(dialogs, paired, extra=None, audit=None, general=False):
    final = str(general)=='final'
    confirmation = str(general)=='confirmation' or final
    assert hashlib.sha256(dialogs.read_bytes()).hexdigest()=='1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d'
    used={key(x) for pair in pairs(paired) for x in pair}
    for f in here.parent.rglob('*.tsv'):
        if here in f.parents: continue
        with f.open() as fp:
            for r in csv.DictReader(fp, delimiter='\t'):
                for col in ('typed','expected','sentence','text','context','prompt'):
                    if r.get(col): used.add(key(r[col]))
                if all(c in r for c in ('left','gold','right')):
                    used.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    pool={}
    if extra:
        assert hashlib.sha256(extra.read_bytes()).hexdigest()=='cd3bc4e968487315d412c044d30af2bf0a4b33c3ef8b74c589f1e1fa832bf72f'
        with (here/'fresh.tsv').open() as fp:
            for r in csv.DictReader(fp,delimiter='\t'):used.update([key(r['typed']),key(r['expected'])])
        for d in json.loads(dialogs.read_text()):
            for u in d['utterances']:
                used.update(key(s) for s in re.split(r'[.!?;:]',u['text']))
        with bz2.open(here.parents[1]/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as inp:
            for line in inp:used.add(key(line.split('\t')[2]))
    if audit:
        domains = {'flights':'86b37b5ae25f530fd18ced78800d30c3b54f7b34bb208ecb51842718f04e760b',
                   'hotels':'975b0242f1e37ea1ab94ccedd7e0d6ee5831599d5df1f16143e71110d6c6006a',
                   'music':'e5db60d6576fa010bef87a70a8b371d293d48cde8524c1d3ed7c3022f079d95d',
                   'sports':'8191531bfa5a8426b1508c396ab9886a19c7c620b443c436ec10d8d4708d0eac'}
        if general:
            domains={'movies':'6f67c9a1f04abc111186e5bcfbe3050be01d0737fd6422901402715bc1f3dd0d','restaurant-search':'fb9735f89e7ebc7c877f976da4c30391af6a6277991b597c0755564657ff8f47','food-ordering':'0a042e566a816a5d0abebe6f7e8cfd6abaa89729ffc42f433d327df7342b12f8'}
            with (here/'audit.tsv').open() as fp:
                for r in csv.DictReader(fp,delimiter='\t'):used.update([key(r['typed']),key(r['expected'])])
        if final:
            with (here/'confirmation.tsv').open() as fp:
                for r in csv.DictReader(fp,delimiter='\t'):used.update([key(r['typed']),key(r['expected'])])
        if confirmation:
            with (here/'general.tsv').open() as fp:
                for r in csv.DictReader(fp,delimiter='\t'):used.update([key(r['typed']),key(r['expected'])])
        with (here/'spoken.tsv').open() as fp:
            for r in csv.DictReader(fp,delimiter='\t'):used.update([key(r['typed']),key(r['expected'])])
        used.update(key(x) for l in (here/'examples.txt').read_text().splitlines() for x in l.split('|'))
        all_dialogs=[]
        for name,checksum in domains.items():
            data=(audit/(name+'.json')).read_bytes();assert hashlib.sha256(data).hexdigest()==checksum
            all_dialogs.extend(json.loads(data))
    else:all_dialogs=json.loads((extra or dialogs).read_text())
    for d in all_dialogs:
        if not extra and sha(d['conversation_id'])[0]>=26: continue
        for u in d['utterances']:
            if u['speaker']!='USER':continue
            for m in re.finditer(r'[^.!?;:]+[.!?]?(?=\s|$)',u['text']):
                s=m[0].strip(); k=key(s)
                if (5<=len(k.split())<=28 and len(s)<=180 and re.fullmatch(r"[A-Za-z][a-zA-Z ,'.?!-]*[.?!]",s)
                    and '  ' not in s and k not in used): pool.setdefault(k,s)
    groups=[('be-by',110),('od-of',150),('ti-to',130),('keep-be',140),('keep-by',75),('join',360),('clean',130)]
    if general:groups=[('be-by',110),('if-of',160),('id-is',160),('od-of',160),('ti-to',120),('keep-if',180),('keep-be',180),('join',400),('clean',300)]
    for kind,quota in groups:
        if audit and not general:quota={'be-by':190,'od-of':220,'ti-to':180,'keep-be':300,'keep-by':80,'join':700,'clean':260}[kind]
        n=0
        for k in sorted(pool,key=lambda k:sha(kind+('/final/' if final else '/confirm/' if confirmation else '/20/')+k)):
            if k in used: continue
            if kind=='be-by' and sha('reserve by/'+k)[0]<(50 if extra else 100):continue
            s=pool[k]; gap=''; slot=''; typed=s
            if kind=='join':
                matches=[i for i,c in enumerate(s) if c==' ' and s[i-1].isalpha() and s[i+1].isalpha()]
                if not matches:continue
                gap=matches[int.from_bytes(sha('gap/'+k)[:2],'big')%len(matches)]
                typed=s[:gap]+s[gap+1:]
            elif kind!='clean':
                gold=kind.split('-')[1]
                m=re.search(r'(?<= )'+gold+r'(?= )',s)
                if not m:continue
                if not kind.startswith('keep'):
                    slot=len(re.findall(r"[^\W_]+(?:['’][^\W_]+)*",s[:m.start()]))
                    typed=s[:m.start()]+kind.split('-')[0]+s[m.end():]
            if typed!=s and key(typed) in used:continue
            yield (('general-' if general else 'audit-' if audit else 'spoken-' if extra else '')+kind+str(n),'external' if extra else 'heldout',kind,typed,s,gap,slot)
            used.update([key(typed),k]); n+=1
            if n>=quota:break
        assert n>=8,(kind,n)
if __name__=='__main__':
    rows=list(cases(*map(Path,sys.argv[1:])))
    with (here/('final.tsv' if sys.argv[-1]=='final' else 'confirmation.tsv' if sys.argv[-1]=='confirmation' else 'general.tsv' if len(sys.argv)>5 else 'audit.tsv' if len(sys.argv)>4 else 'spoken.tsv' if len(sys.argv)>3 else 'fresh.tsv')).open('w') as out:
        w=csv.writer(out,delimiter='\t',lineterminator='\n');w.writerow(('id','split','kind','typed','expected','gap','slot'));w.writerows(rows)
    print(Counter(r[2] for r in rows))
