from pathlib import Path
import json,gzip,re,sys
p=Path(sys.argv[1]);docs={r['id']:r['final'] for r in map(json.loads,gzip.open(sys.argv[2]))};out=[]
for id,i,w,source,n,opts in json.load(open(p)):
 if not opts or opts[0][1]-source < -1.:continue
 text=docs[id]; m=list(re.finditer(r"[A-Za-z]+(?:['’][A-Za-z]+)*|[0-9]+|[^\s]",text))[i]
 if m[0].lower()!=w.lower():continue
 choices=sorted({w.lower(),*(s.lower() for s,v in opts if v>opts[0][1]-4)})
 prompt='Message with one missing word: '+text[:m.start()]+'[BLANK]'+text[m.end():]+'\nOptions: '+' / '.join(choices)+'\nIntended word:'
 out.append(dict(id=id+'|'+str(i),prompt=prompt))
json.dump(out,open(sys.argv[3],'w'))
