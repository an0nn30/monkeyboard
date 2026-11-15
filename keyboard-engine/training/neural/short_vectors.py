"""Export embeddings of short words to compare how similarly the decoder uses two spellings."""
from pathlib import Path
import argparse
import torch
def export(checkpoint,out):
    words=(checkpoint/'vocab.txt').read_text().splitlines()
    ids=sorted((w,i) for i,w in enumerate(words) if w.isalpha() and len(w)<=4)
    model=torch.load(checkpoint/'decoder.pt',map_location='cpu',weights_only=True)
    w=model['out.weight'][[i for _,i in ids]].float()
    # Per-row scale cancels in cosine similarity.
    quant=(w/w.abs().amax(1,keepdim=True)*127).round().to(torch.int8)
    (out/'short-vectors.bin').write_bytes(quant.numpy().tobytes())
    (out/'short-vocab.txt').write_text(''.join(w+'\n' for w,_ in ids))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('checkpoint',type=Path);p.add_argument('out',type=Path);export(**vars(p.parse_args()))
