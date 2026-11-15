"""Learn a small distributional word space from public noun definitions; no evaluation inputs."""
import argparse, collections, hashlib, io, math, re, struct, tarfile
from pathlib import Path
import numpy as np
import scipy.sparse as sp
from scipy.sparse.linalg import svds
root=Path(__file__).resolve().parents[2]
ap=argparse.ArgumentParser()
ap.add_argument("archive",type=Path)
ap.add_argument("--out",type=Path,default=root/"model/semantics")
a=ap.parse_args()
assert hashlib.sha256(a.archive.read_bytes()).hexdigest()=="640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52"
D=80
stop=set("""a an the of his her it this that these those who whom whose have has had having i your yours their themselves my our its from used use using usually especially consisting which one made make such over under with into when where than after before between and or not some other most as is are be been being on by to in for at out any only often something someone person thing type kind part each first last along etc genus family name either small large about more form like may called also very little many would can generally common another two three long formerly people them him they she we he without both together do very own much whole certain particular all sometimes""".split())
archive=tarfile.open(a.archive,"r:gz")
def lines(name):return io.TextIOWrapper(archive.extractfile("WordNet-3.0/dict/"+name),encoding="ascii")
terms={}; defs={}; edges={}
for line in lines("data.noun"):
    if not line[0].isdigit():continue
    body,gloss=line.split("|",1);f=body.split();slot=int(f[3],16);sid=f[0]
    terms[sid]=[w.lower() for w in f[4:4+slot*2:2]]
    defs[sid]=re.findall("[a-z]+",gloss.split('; "')[0].lower())
    rest=f[4+slot*2:];edges[sid]=[(rest[i],rest[i+1]) for i in range(1,1+int(rest[0])*4,4) if rest[i+2]=="n"]
senses={}
for line in lines("index.noun"):
    if line.startswith(" "):continue
    f=line.split(); n=int(f[3]); senses[f[0]]=f[6+n:]
exceptions={f[0]:f[1] for l in lines("noun.exc") if len(f:=l.split())>=2}
def lemma(w):
    for t in [w,exceptions.get(w,w),w[:-3]+"y" if w.endswith("ies") else w,w[:-1] if w.endswith("s") else w]:
        if t in senses:return t
    return w
# Vocabulary comes solely from the dictionary and the existing build-10 training lexicon.
general={l.split()[0] for l in (root/"model/words.tsv").read_text().splitlines()}
general.update((root/"model/neural/vocab.txt").read_text().split())
tagged=set()
for l in lines("index.sense"):
    _,_,_,n=l.split()
    if int(n)>0 and "%1:" in l:tagged.add(l.split("%")[0])
allowed={lemma(w) for w in general|tagged if w.isascii() and w.isalpha() and len(w)>2} - stop
vocab=sorted(allowed); ids={w:i for i,w in enumerate(vocab)}
rows=[];cols=[];vals=[]
for j,sid in enumerate(terms):
    doc=collections.Counter()
    def add(w,weight):
        w=lemma(w)
        if w in ids:doc[w]=max(doc[w],weight)
    for term in terms[sid]:
        for w in term.split("_"):
            senses_for=senses.get(w,[])
            first=senses_for.index(sid) if sid in senses_for else 3
            add(w,4/math.sqrt(1+first))
    for w in defs[sid]:add(w,1)
    for rel,target in edges[sid]:
        if rel not in {"@","%p","#p","~"}:continue
        for t in terms[target][:2]:
            for w in t.split("_"):add(w,1.2 if rel!="~" else .45)
    for word,n in doc.items():rows.append(ids[word]);cols.append(j);vals.append(n)
M=sp.csr_matrix((np.array(vals,dtype=np.float32),(rows,cols)),shape=(len(vocab),len(terms)))
# Normalize word frequency and definition length before the truncated SVD.
from scipy.sparse import diags
df=np.asarray(M.getnnz(axis=1)); idf=np.log((1+M.shape[1])/(1+df))
M=diags(idf.astype(np.float32))@M
M=M@diags((1/np.maximum(.01,np.sqrt(np.asarray(M.power(2).sum(0)).ravel()))).astype(np.float32))
M=diags((1/np.maximum(.01,np.sqrt(np.asarray(M.power(2).sum(1)).ravel()))).astype(np.float32))@M
u,s,_=svds(M,k=D,which="LM",random_state=4132)
u=u*np.sqrt(s)
# Make SVD signs deterministic before int8 export.
u*=np.sign(u[np.abs(u).argmax(axis=0),np.arange(D)])
u/=np.maximum(1e-8,np.linalg.norm(u,axis=1,keepdims=True))
a.out.mkdir(exist_ok=True,parents=True)
(a.out/"vocab.txt").write_text("\n".join(vocab)+"\n")
(a.out/"vectors.i8").write_bytes(struct.pack("<4sII",b"MBS2",len(vocab),D)+np.rint(u*127).clip(-127,127).astype("i1").tobytes())
print(f"{len(vocab)} words, {len(terms)} noun senses, {D} dimensions")
