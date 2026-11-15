"""Produce corpus evidence for all cloze candidates without consulting edit labels."""
from functools import lru_cache
import argparse, json, gzip, re, math
from pathlib import Path
import numpy as np
START=14695981039346656037; P=1099511628211; MAX=(1<<64)-1
def mix(h,x):return ((h^x)*P)&MAX
@lru_cache(100000)
def word(s):
 h=START
 for c in s.lower().replace('’',"'").encode():h=mix(h,c)
 return h
class Counts:
 def __init__(self,p):
  self.arr=np.memmap(p,dtype=[('k','<u8'),('v','<u4')],mode='r');self.keys=np.ascontiguousarray(self.arr['k'])
 @lru_cache(100000)
 def lookup(self,ws):
  h=mix(START,len(ws))
  for w in ws:h=mix(h,word(w))
  i=int(np.searchsorted(self.keys,np.uint64(h)))
  return int(self.arr['v'][i]) if i<len(self.keys) and self.keys[i]==h else 0
 def evidence(self,words,i,w):
  src=words[:];src[i]=w
  uni=self.lookup((w,)); fs=[math.log1p(uni)]
  for n in (2,3):
   for pos in range(i-n+1,i+1):
    gram=src[pos:pos+n]
    count=self.lookup(tuple(gram)) if pos>=0 and len(gram)==n and all(re.fullmatch("[A-Za-z']+",v) for v in gram) else 0
    fs.append(math.log1p(count))
  return fs
def probe(counts,logits,docs):
 out={x['id']:x['final'] for x in map(json.loads,gzip.open(docs,'rt'))};result=[]
 for id,i,src,score,n,opts in json.loads(logits.read_bytes()):
  if not opts or opts[0][1]-score < -2:continue
  words=re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)*|[0-9]+|[^\s]",out[id].lower())
  if i>=len(words) or words[i]!=src.lower():continue
  result.append([id,i,src,n,[[w,sc,counts.evidence(words,i,w)] for w,sc in [(src,score)]+opts[:4]]])
 return result
if __name__=='__main__':
 a=argparse.ArgumentParser()
 for k in ['counts','logits','docs','out']:a.add_argument(k,type=Path)
 p=a.parse_args();p.out.write_text(json.dumps(probe(Counts(p.counts),p.logits,p.docs)))
