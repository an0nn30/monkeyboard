"""Learn literal-use evidence from separate UCI non-spam texts; never use challenge answers."""
import argparse,csv,hashlib,json,re,zipfile
from collections import Counter
from pathlib import Path
from paired_text import key,pairs,engine
def train(archive,pairs_file,bench):
    assert hashlib.sha256(archive.read_bytes()).hexdigest()=='1587ea43e58e82b14ff1f5425c88e17f8496bfcdb67a583dbff9eefaf9963ce3'
    block={key(v) for xy in pairs(pairs_file) for v in xy}
    for split in ['review','final']:
        block.update(key(r[c]) for r in json.loads((bench/f'{split}.json').read_text()) for c in ('expected','typed'))
    with zipfile.ZipFile(archive) as z:lines=z.read('SMSSpamCollection').decode().splitlines()
    kept=set();counts=Counter()
    for line in lines:
        if not line.startswith('ham\t'):continue
        s=line[4:];k=key(s)
        if k in block or k in kept:continue
        kept.add(k);terms=re.findall(r"[a-z]+(?:'[a-z]+)*",s.lower());terms=['^']+terms
        counts.update(set(terms[1:])|{' '.join(terms[i:i+2]) for i in range(len(terms)-1)})
    out=engine/'model/wordnet22/casual.tsv';out.write_text(''.join(f'{s}\t{n}\n' for s,n in sorted(counts.items()) if n>=2))
    print('independent non-spam SMS training messages',len(kept),'aggregate rows',sum(n>=2 for n in counts.values()))
if __name__=='__main__':
    p=argparse.ArgumentParser();[p.add_argument(x,type=Path) for x in ('archive','pairs_file','bench')];train(**vars(p.parse_args()))
