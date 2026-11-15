"""Export the existing masked encoder plus a fitted sentence-corruption head."""
import argparse
import json
import importlib.util
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from transformers import RobertaForMaskedLM, RobertaTokenizerFast
from wordfreq import top_n_list
from calibrate import coefficients

BASE = Path(__file__).resolve().parents[2] / "build55/model/export.py"
spec = importlib.util.spec_from_file_location("export55", BASE)
export55 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export55)


class Scorer(export55.ClozeEncoder):
    def __init__(self, model, anchors, artifact):
        super().__init__(model, anchors)
        self.layers = set(artifact["layers"])
        first = artifact["weights"]["0.weight"]
        self.hidden = torch.nn.Linear(first.shape[1], first.shape[0])
        self.verdict = torch.nn.Linear(first.shape[0], 1)
        with torch.no_grad():
            self.hidden.weight.copy_(first / artifact["std"])
            self.hidden.bias.copy_(artifact["weights"]["0.bias"] - self.hidden.weight @ artifact["mean"])
            self.verdict.weight.copy_(artifact["weights"]["3.weight"])
            self.verdict.bias.copy_(artifact["weights"]["3.bias"])

    def forward(self, vectors, tokens):
        attention = (tokens == 1).float()[:, None, None, :] * -10000.
        active = (tokens == 50264).float().unsqueeze(-1)
        active = active / active.sum(dim=1,keepdim=True).clamp(min=1)
        states = self.norm(vectors + self.positions)
        selected = []
        for n,block in enumerate(self.blocks,1):
            states = block(states,attention_mask=attention)[0]
            if n in self.layers:
                selected.append((states * active).sum(dim=1))
        state = (states * active).sum(dim=1)
        context = self.head_norm(torch.nn.functional.gelu(self.head(state)))
        failure = self.verdict(torch.nn.functional.gelu(self.hidden(torch.cat(selected,dim=1))))
        return context,self.anchors(context),failure


def convert(checkpoint, detector, destination):
    tok = RobertaTokenizerFast.from_pretrained(checkpoint)
    model = RobertaForMaskedLM.from_pretrained(checkpoint,attn_implementation="eager")
    anchors=list(dict.fromkeys(tok.encode(" "+w,add_special_tokens=False)[0] for w in top_n_list("en",65000) if w))
    anchors=sorted(set(anchors[:8192])|{tok.eos_token_id})
    scorer=Scorer(model,anchors,torch.load(detector,weights_only=True)).eval()
    source=Path(__file__).resolve().parents[3]/"Keyboard/Resources/contextual55-vocab.txt"
    vocabulary=json.loads(source.read_text())
    vocabulary["acceptance"] = coefficients()
    vocabulary["anchorWords"]=[tok.convert_ids_to_tokens(i) for i in anchors]
    notice = (Path(__file__).parent / "NOTICE.txt").read_text()
    if notice not in vocabulary["notice"]:
        vocabulary["notice"] += "\n" + notice
    tmp=destination.parent/"contextual55-vocab.tmp"
    tmp.write_text(json.dumps(vocabulary,ensure_ascii=False,separators=(",",":")))
    tmp.replace(destination.parent/"contextual55-vocab.txt")
    x=torch.zeros(4,32,768);ids=torch.full((4,32),4,dtype=torch.int32);ids[:,1]=50264
    with torch.inference_mode():
        traced=torch.jit.trace(scorer,(x,ids))
    prog=ct.convert(traced,inputs=[
        ct.TensorType(name="vectors",shape=x.shape,dtype=np.float16),
        ct.TensorType(name="tokens",shape=ids.shape,dtype=np.int32)],
        outputs=[ct.TensorType(name=name,dtype=np.float16) for name in ("context","anchors","corruption")],
        minimum_deployment_target=ct.target.iOS18,skip_model_load=True)
    cfg=OptimizationConfig(global_config=OpLinearQuantizerConfig(dtype="int8",mode="linear_symmetric",
        granularity="per_block",block_size=32,weight_threshold=10000))
    result=linear_quantize_weights(prog,cfg)
    result.author="MonkeyBoard, using Facebook AI RoBERTa"
    result.short_description="Offline masked-word scores and a contextual real-word corruption detector."
    result.save(destination)


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("checkpoint",type=Path);p.add_argument("detector",type=Path);p.add_argument("output",type=Path)
    a=p.parse_args();convert(a.checkpoint,a.detector,a.output)
