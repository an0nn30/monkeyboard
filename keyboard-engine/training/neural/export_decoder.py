"""Export the trained decoder for the iOS extension. Uses coremltools 9 and torch 2.8."""
import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from networks import Decoder, T

engine = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--checkpoint", type=Path, default=engine / "research/decoder15m")
parser.add_argument("--out", type=Path, default=engine / "model/decoder15m")
parser.add_argument("--legacy-checkpoint", type=Path)
args = parser.parse_args()
checkpoint, out = args.checkpoint, args.out
out.mkdir(exist_ok=True)
vocab = (checkpoint / "vocab.txt").read_text().splitlines()
reviewed = set()
for file in ("display-words.txt", "texting-display-words.txt", "everyday-words.txt"):
    reviewed.update((engine / "training" / file).read_text().split())
# Preserve the training IDs and mark words approved for the next-word strip.
(out / "decoder-vocab.tsv").write_text("".join(f"{word}\t{int(word in reviewed)}\n" for word in vocab))

torch.set_num_threads(2)
model = Decoder().eval()
model.load_state_dict(torch.load(checkpoint / "decoder.pt", map_location="cpu", weights_only=True))
# Fixed shape, right padding. Causal attention guarantees pad tokens cannot
# influence any preceding logit. Retain logits at every position for lookback.
class KeyboardDecoder(torch.nn.Module):
    def __init__(self, decoder):
        super().__init__()
        self.decoder = decoder
        self.legacy = torch.nn.Linear(384,8192) if args.legacy_checkpoint else None
        if self.legacy is not None:
            old = torch.load(args.legacy_checkpoint / "decoder.pt", map_location="cpu",weights_only=True)
            self.legacy.load_state_dict({k.removeprefix("out."):v for k,v in old.items() if k.startswith("out.")})

    def forward(self, tokens):
        m = self.decoder
        h = m.emb(tokens) + m.pos(torch.arange(tokens.shape[1]))[None]
        states = m.norm(m.layers(h))
        outputs = (m.out(states), states)
        return outputs + (self.legacy(states),) if self.legacy is not None else outputs


example = torch.arange(T, dtype=torch.int32)[None]
with torch.inference_mode():
    traced = torch.jit.trace(KeyboardDecoder(model).eval(), example)
    core = ct.convert(traced, inputs=[ct.TensorType(name="tokens", shape=(1, T), dtype=np.int32)],
                      outputs=[ct.TensorType(name="logits", dtype=np.float16),
                               ct.TensorType(name="states", dtype=np.float16)] + ([ct.TensorType(name="legacyLogits",dtype=np.float16)] if args.legacy_checkpoint else []),
                      minimum_deployment_target=ct.target.iOS18, convert_to="mlprogram",
                      compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_ONLY)
    core.save(str(out / "MonkeyDecoder.mlpackage"))
    for prefix in ("the novel", "beside my", "the shoe goes", "he goes home"):
        ids = [1] + [vocab.index(w) for w in prefix.split()]
        ix = torch.tensor([ids], dtype=torch.int32)
        padded = torch.nn.functional.pad(ix, (0,T-len(ids)))
        got = core.predict({"tokens": padded.numpy()})["logits"][0, len(ids)-1].astype("float32")
        want = model(ix)[0,-1].numpy()
        error = float(np.max(np.abs(want-got)))
        assert error < 0.12 and np.argmax(got) == np.argmax(want), (prefix, error)
        print(f"{prefix!r}: max logit error {error:.4f}, same top prediction {vocab[np.argmax(got)]}")
