"""Export the frozen public RoBERTa encoder for offline keyboard inference.

Run with Python 3.11, torch 2.7, transformers 4.55, coremltools 9, numpy 1.26,
and wordfreq 3.1. Pass a local Hugging Face RoBERTa masked-LM checkpoint.
"""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
)
from transformers import AutoModelForMaskedLM, RobertaTokenizerFast
from wordfreq import top_n_list, zipf_frequency

BATCH = 4
WINDOW = 32


class ClozeEncoder(torch.nn.Module):
    def __init__(self, masked_lm, anchors):
        super().__init__()
        bert = masked_lm.roberta
        self.blocks = bert.encoder.layer
        self.norm = bert.embeddings.LayerNorm
        self.register_buffer("positions", bert.embeddings.position_embeddings.weight[2:WINDOW + 2]
                             + bert.embeddings.token_type_embeddings.weight[0])
        head = masked_lm.lm_head
        self.head = head.dense
        self.head_norm = head.layer_norm
        self.anchors = torch.nn.Linear(head.dense.out_features, len(anchors))
        with torch.no_grad():
            self.anchors.weight.copy_(head.decoder.weight[anchors])
            self.anchors.bias.copy_(head.bias[anchors])

    def forward(self, vectors, tokens):
        attention = (tokens == 1).float()[:, None, None, :] * -10000.
        states = self.norm(vectors + self.positions)
        for block in self.blocks:
            states = block(states, attention_mask=attention)[0]
        state = (states * (tokens == 50264).unsqueeze(-1)).sum(dim=1)
        context = self.head_norm(torch.nn.functional.gelu(self.head(state)))
        # Normalize these on the client in float32. Some GPU backends overflow
        # the intermediate exponential when converting reduce_log_sum_exp to fp16.
        return context, self.anchors(context)


def export(checkpoint, output, bits):
    tok = RobertaTokenizerFast.from_pretrained(checkpoint)
    model = AutoModelForMaskedLM.from_pretrained(checkpoint, attn_implementation="eager")
    output.mkdir(parents=True, exist_ok=True)
    words = top_n_list("en", 65000)
    tokens = sorted(tok.get_vocab(), key=tok.get_vocab().__getitem__)
    # Serde one JSON document rather than loading Hugging Face tokenizers in iOS.
    data = json.loads(tok.backend_tokenizer.to_str())["model"]
    merges = [pair.split() if isinstance(pair, str) else pair for pair in data["merges"]]
    dictionary = {w: int(round(zipf_frequency(w, "en") * 10)) for w in words
                  if w.isascii() and w.islower() and all(c.isalpha() or c == "'" for c in w)}
    (output / "contextual55-vocab.txt").write_text(json.dumps(
        {"tokens": tokens, "merges": merges, "words": dictionary,
         "notice": (Path(__file__).parent / "NOTICE.txt").read_text()},
        ensure_ascii=False, separators=(",", ":")))
    embeddings = model.roberta.embeddings.word_embeddings.weight.detach().numpy()
    bias = model.lm_head.bias.detach().numpy()
    scales = np.maximum(np.abs(embeddings).max(axis=1) / 127, 1e-8)
    quantized = np.rint(embeddings / scales[:, None]).clip(-127, 127).astype("i1")
    with (output / "contextual55-embeddings.bin").open("wb") as file:
        file.write(b"MBCE")
        file.write(np.array(embeddings.shape, dtype="<i4").tobytes())
        file.write(scales.astype("<f4").tobytes())
        file.write(bias.astype("<f4").tobytes())
        file.write(quantized.tobytes())

    # The common-token marginal normalizes candidate scores; all candidate and
    # source logits still use the checkpoint's full original output weights.
    anchors = list(dict.fromkeys(tok.encode(" " + w, add_special_tokens=False)[0]
                                 for w in words if w))
    anchors = sorted(set(anchors[:4096]) | {tok.eos_token_id})
    encoder = ClozeEncoder(model, anchors).eval()
    width = embeddings.shape[1]
    vectors = torch.rand(BATCH, WINDOW, width)
    ids = torch.full((BATCH, WINDOW), 4, dtype=torch.int32)
    ids[:, 1] = 50264
    with torch.inference_mode():
        traced = torch.jit.trace(encoder, (vectors, ids))
    converted = ct.convert(traced,
        inputs=[ct.TensorType(name="vectors", shape=vectors.shape, dtype=np.float16),
                ct.TensorType(name="tokens", shape=ids.shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="context", dtype=np.float16),
                 ct.TensorType(name="anchors", dtype=np.float16)],
        minimum_deployment_target=ct.target.iOS18, skip_model_load=True)
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        dtype=f"int{bits}", mode="linear_symmetric", granularity="per_block", block_size=32,
        weight_threshold=10000))
    compressed = linear_quantize_weights(converted, config)
    compressed.author = "MonkeyBoard, using Facebook AI RoBERTa"
    compressed.short_description = f"Contextual masked-word scoring with block-wise {bits}-bit encoder weights."
    compressed.save(output / "MBMaskedEncoder.mlpackage")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bits", type=int, choices=[4, 8], default=8)
    args = parser.parse_args()
    export(args.checkpoint, args.output, args.bits)
