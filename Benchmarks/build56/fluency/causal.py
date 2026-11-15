"""Score the target spelling and observed right context under a frozen causal LM."""

import argparse
import json
import math
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


@torch.inference_mode()
def score(args):
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = (
        AutoModelForCausalLM.from_pretrained(args.model, torch_dtype=torch.float16)
        .eval()
        .to(args.device)
    )
    bos = (
        tokenizer.bos_token_id
        if tokenizer.bos_token_id is not None
        else tokenizer.eos_token_id
    )
    proposals = json.loads(args.proposals.read_bytes())
    variants = {
        line[:a] + word + line[b:]
        for line, a, b, options in proposals
        for word, _ in options
    }
    ordered = sorted(variants, key=lambda line: (len(line), line))
    scores = {}
    for start in range(0, len(ordered), args.batch):
        batch = ordered[start : start + args.batch]
        tokenized = tokenizer(
            batch, return_offsets_mapping=True, add_special_tokens=False
        )
        sequences = [[bos] + row for row in tokenized.input_ids]
        width = max(map(len, sequences))
        ids = torch.tensor(
            [s + [bos] * (width - len(s)) for s in sequences], device=args.device
        )
        logits = model(ids, use_cache=False).logits[:, :-1].float()
        observed = logits.gather(-1, ids[:, 1:].unsqueeze(-1)).squeeze(
            -1
        ) - torch.logsumexp(logits, -1)
        for line, offsets, ps in zip(
            batch, tokenized.offset_mapping, observed.cpu().tolist()
        ):
            values = ps[: len(offsets)]
            if not all(math.isfinite(v) for v in values):
                raise ValueError("Non-finite causal probability")
            scores[line] = list(zip(offsets, values))
    output = []
    for line, a, b, options in proposals:
        values = []
        for word, masked in options:
            end = a + len(word)
            logps = scores[line[:a] + word + line[b:]]
            target = [p for (l, r), p in logps if r > a and l < end]
            right = [p for (l, r), p in logps if l >= end]
            assert target
            values.append(
                [word, masked, round(sum(target), 4), [round(x, 4) for x in right]]
            )
        output.append([line, a, b, values])
    args.output.write_text(json.dumps(output))
    print(
        args.model.name,
        len(variants),
        "unique completions",
        len(output),
        "sites",
        flush=True,
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("model", type=Path)
    p.add_argument("proposals", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--batch", default=12, type=int)
    p.add_argument("--device", default="mps")
    score(p.parse_args())
