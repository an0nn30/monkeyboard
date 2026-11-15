"""Verify both Core ML heads against their training checkpoints and unchanged hidden states."""
import json,sys
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'keyboard-engine/training/neural'))
from networks import Decoder
torch.set_num_threads(2)
base=root/'keyboard-engine/research/decoder15m'
adapt=root/'keyboard-engine/research/decoder21'
a=torch.load(base/'decoder.pt',map_location='cpu',weights_only=True);b=torch.load(adapt/'decoder.pt',map_location='cpu',weights_only=True)
assert all(torch.equal(a[k],b[k]) for k in a if not k.startswith('out.'))
model=ct.models.MLModel(str(root/'keyboard-engine/model/decoder21/MonkeyDecoder.mlpackage'),compute_units=ct.ComputeUnit.CPU_ONLY)
vocab=(base/'vocab.txt').read_text().splitlines();lookup={w:i for i,w in enumerate(vocab)}
samples=['the novel goes','if it had a bar','directed by a woman','i would like to','we are going to see','my landlord is a barista','the kids in the morning','a book by the window']
res={}
for label,weights in [('legacyLogits',a),('logits',b)]:
 net=Decoder().eval();net.load_state_dict(weights);errors=[]
 for s in samples:
  ids=[1]+[lookup.get(w,0) for w in s.split()]
  x=torch.tensor([ids],dtype=torch.int32);padded=np.zeros((1,32),np.int32);padded[0,:len(ids)]=ids
  got=model.predict({'tokens':padded})[label][0,len(ids)-1].astype('float32')
  with torch.inference_mode():want=net(x)[0,-1].numpy()
  errors.append(float(np.max(np.abs(want-got))));assert np.argmax(got)==np.argmax(want)
 assert max(errors)<.15
 res[label]={'max_error':max(errors),'same_argmax':len(samples)}
print(json.dumps(res,indent=2))
