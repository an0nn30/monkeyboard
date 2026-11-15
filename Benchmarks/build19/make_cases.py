"""Freeze a fresh missing-space benchmark. Every noisy case has one labelled removed space."""
import bz2, csv, hashlib, re, sys
from pathlib import Path
here=Path(__file__).resolve().parent
root=here.parents[1]
sys.path.insert(0,str(root/'keyboard-engine/training'))
from paired_text import key,pairs

def sha(s): return hashlib.sha256(s.encode()).digest()
def read(p):
    with p.open() as f: yield from csv.DictReader(f,delimiter='\t')
def collect(path, confirmation=False):
    blocked=set()
    for n in (15,16):
        for r in read(here.parent/f'build{n}/cases.tsv'):
            blocked.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    for fname in ('build17/sentences.tsv','build17/confirmation.tsv','build18/sentences.tsv','build18/challenge.tsv'):
        for r in read(here.parent/fname): blocked.update(map(key,[r['typed'],r['expected']]))
    if confirmation:
        for r in read(here/'sentences.tsv'):blocked.update(map(key,[r['typed'],r['expected']]))
    controls=(here/'controls.txt').read_text().splitlines()
    blocked.update(map(key,controls))
    corpora={'paired':{},'public':{}}
    pairkeys=set()
    for src,ref in pairs(path):
        k=key(ref);pairkeys.update([k,key(src)])
        if sha(k)[0]<38 and k not in blocked:corpora['paired'].setdefault(k,ref)
    public=root/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2'
    assert hashlib.sha256(public.read_bytes()).hexdigest()=='c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca'
    with bz2.open(public,'rt') as f:
        for line in f:
            _,lang,ref,_=line.rstrip('\n').split('\t',3); k=key(ref)
            if lang=='eng' and k not in blocked and k not in pairkeys and sha(k)[0]<26:
                corpora['public'].setdefault(k,ref)
    for group,pool in corpora.items():
        take=0
        for k in sorted(pool,key=lambda x:sha('mb19/rows/'+x)):
            ref=pool[k]; words=list(re.finditer(r"[A-Za-z]+(?:['’][A-Za-z]+)*",ref))
            if not 4<=len(words)<=22 or len(ref)>150 or not ref.isprintable():continue
            # Word-initial capitals and one-letter words are allowed. Preserve punctuation literally.
            options=[b.start()-1 for a,b in zip(words,words[1:]) if ref[a.end():b.start()]==' '
                     and a.group().isalpha() and b.group().isalpha()
                     and len(a.group())+len(b.group())>=4]
            if not options:continue
            gap=options[int.from_bytes(sha('mb19/cut/'+k)[:4],'big')%len(options)]
            noisy=take%3!=2
            typed=ref[:gap]+ref[gap+1:] if noisy else ref
            if key(typed) in blocked:continue
            blocked.update([k,key(typed)])
            yield [group+str(take),group,'noisy' if noisy else 'clean',typed,ref,gap if noisy else '']
            take+=1
            if take==({'paired':900,'public':210}[group] if confirmation else {'paired':1500,'public':450}[group]):break
        assert take>=({'paired':600,'public':100}[group] if confirmation else {'paired':1500,'public':150}[group]), (group,take)
    if confirmation: return
    for i,ref in enumerate(controls):yield [f'control{i}','authored','clean',ref,ref,'']
if __name__=='__main__':
    confirmation='--confirmation' in sys.argv[2:]
    with (here/('confirmation.tsv' if confirmation else 'sentences.tsv')).open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n');w.writerow(['id','split','kind','typed','expected','gap']);w.writerows(collect(Path(sys.argv[1]),confirmation))
