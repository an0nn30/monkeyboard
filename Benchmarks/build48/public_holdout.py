"""Freeze deterministic noisy/clean pairs from previously unused UCI SMS challenge-eligible messages."""
import argparse, bz2, hashlib, json, re, sys, zipfile
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path[:0]=[str(ROOT/'keyboard-engine/training'),str(HERE.parent/'build22/blind')]
from paired_text import pairs, key
from freeze import corrupt, public_pool
from audit_sources import previous_cases

def digest(s):return hashlib.sha256(s.encode()).digest()

def prepare(paired, conversations, sms):
    blocked=previous_cases()|{key(s) for r in pairs(paired) for s in r}
    for p in [conversations, ROOT/'keyboard-engine/training/context40-practice.txt']:
        blocked.update(key(s) for s in p.read_text().splitlines())
    for p in [HERE.parent/'build22/blind/final.json', HERE.parent/'build22/blind/review.json',
              HERE.parent/'build46/public.json', *(HERE.parent/f'build{n}/fresh.json' for n in (40,41,45,47))]:
        blocked.update(key(row[k]) for row in json.loads(p.read_bytes()) for k in ('typed','expected'))
    with bz2.open(ROOT/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as stream:
        blocked.update(key(line.split('\t')[2]) for line in stream)
    pools=public_pool(sms,blocked)
    pool=[(str(i),s) for partition in pools.values() for i,s in partition.items()]
    used=set();rows=[]
    for typ in ('public-real-word','public-multi','public-word','public-join'):
        n=0
        for sid,gold in sorted(pool,key=lambda r:digest('public48/'+typ+'/'+r[0])):
            bad=corrupt(gold,typ,'public48/noise/'+typ+'/'+sid)
            if not bad or bad==gold:continue
            keys={key(gold),key(bad)}
            if keys & (used|blocked):continue
            used.update(keys)
            for noisy in (True,False):
                rows.append(dict(id='sms-'+sid+('-t' if noisy else '-c'),kind=typ if noisy else 'clean',
                                 typed=bad if noisy else gold,expected=gold,split='public',source_id=sid))
            n+=1
            if n==50:break
        assert n==50,(typ,n)
    raw=(json.dumps(rows,ensure_ascii=False,indent=2)+'\n').encode()
    (HERE/'public.json').write_bytes(raw)
    (HERE/'public-freeze.json').write_text(json.dumps(dict(rows=len(rows),unique_references=len(rows)//2,source='UCI SMS Spam Collection (ham only)',
        selection='Prior public challenge eligibility; exclude previous cases and repeated references',source_sha256=hashlib.sha256(sms.read_bytes()).hexdigest(),
        sha256=hashlib.sha256(raw).hexdigest()),indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for a in ('paired','conversations','sms'):p.add_argument(a,type=Path)
    prepare(**vars(p.parse_args()))
