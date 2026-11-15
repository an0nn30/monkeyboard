"""Fit a small fluency head against a frozen causal teacher using public text only."""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    RobertaModel,
    RobertaTokenizerFast,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from train_detector import make_pairs

LAYERS = (4, 8, 12)


def variants(pairs):
    for line, a, b, alternative in pairs:
        yield line, a, b
        yield line[:a] + alternative + line[b:], a, a + len(alternative)


@torch.inference_mode()
def teacher_scores(teacher, variants, device):
    tok = AutoTokenizer.from_pretrained(teacher)
    model = (
        AutoModelForCausalLM.from_pretrained(
            teacher, torch_dtype=torch.bfloat16, attn_implementation="eager"
        )
        .eval()
        .to(device)
    )
    bos = tok.bos_token_id if tok.bos_token_id is not None else tok.eos_token_id
    targets = []
    for i in range(0, len(variants), 24):
        group = variants[i : i + 24]
        enc = tok(
            [s for s, _, _ in group],
            return_offsets_mapping=True,
            add_special_tokens=False,
        )
        seqs = [[bos] + s for s in enc.input_ids]
        width = max(map(len, seqs))
        ids = torch.tensor([s + [bos] * (width - len(s)) for s in seqs], device=device)
        logits = model(ids, use_cache=False).logits[:, :-1].float()
        ps = (
            (
                logits.gather(-1, ids[:, 1:, None]).squeeze(-1)
                - torch.logsumexp(logits, -1)
            )
            .cpu()
            .tolist()
        )
        for (line, a, b), offsets, probs in zip(group, enc.offset_mapping, ps):
            word = sum(p for (l, r), p in zip(offsets, probs) if r > a and l < b)
            right = [p for (l, r), p in zip(offsets, probs) if l >= b][:6]
            targets.append([word, sum(right)])
    values = np.array(targets).reshape(-1, 2, 2)
    if not np.isfinite(values).all():
        raise ValueError("Non-finite causal teacher targets")
    return values


@torch.inference_mode()
def features(masked, variants, device):
    tok = RobertaTokenizerFast.from_pretrained(masked)
    model = (
        RobertaModel.from_pretrained(masked, add_pooling_layer=False)
        .eval()
        .half()
        .to(device)
    )
    out = []
    for k in range(0, len(variants), 64):
        batch = variants[k : k + 64]
        enc = tok(
            [text for text, _, _ in batch],
            return_offsets_mapping=True,
            return_tensors="pt",
            padding=True,
        )
        ids = enc.input_ids.to(device)
        weights = []
        for offsets, (_, a, b) in zip(enc.offset_mapping.tolist(), batch):
            span = [i for i, (l, r) in enumerate(offsets) if r > a and l < b and r > l]
            assert span
            weights.append([float(i in span) / len(span) for i in range(len(offsets))])
        att = torch.tensor(weights, device=device, dtype=torch.float16).unsqueeze(-1)
        hidden = model(
            ids, attention_mask=ids.ne(1), output_hidden_states=True
        ).hidden_states
        out.append(
            torch.cat([(hidden[j] * att).sum(1) for j in LAYERS], 1).cpu().numpy()
        )
    return np.concatenate(out)


def fit(x, y, path, device):
    torch.manual_seed(5821)
    n = len(y)
    cut = int(n * 0.9)
    x = torch.tensor(x.reshape(n, 2, -1), device=device).float()
    mean = x[:cut].mean((0, 1))
    std = x[:cut].std((0, 1)).clamp(min=0.03)
    x = (x - mean) / std
    # Centering each pair cancels constant context difficulty and document length.
    gains = y[:, 1] - y[:, 0]
    y = torch.tensor(gains, dtype=torch.float32, device=device).clamp(-20, 20) / 4
    model = torch.nn.Sequential(
        torch.nn.Linear(x.shape[-1], 96),
        torch.nn.GELU(),
        torch.nn.Dropout(0.12),
        torch.nn.Linear(96, 2),
    ).to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=0.0006, weight_decay=0.03)
    best = float("inf")
    for epoch in range(15):
        model.train()
        for ix in torch.randperm(cut, device=device).split(196):
            preds = model(x[ix])
            diff = preds[:, 1] - preds[:, 0]
            loss = torch.nn.functional.smooth_l1_loss(diff, y[ix])
            opt.zero_grad()
            loss.backward()
            opt.step()
        model.eval()
        with torch.no_grad():
            v = model(x[cut:])
            d = v[:, 1] - v[:, 0]
            loss = torch.nn.functional.smooth_l1_loss(d, y[cut:]).item()
            if loss < best:
                best = loss
                torch.save(
                    {
                        "mean": mean.cpu(),
                        "std": std.cpu(),
                        "weights": {k: v.cpu() for k, v in model.state_dict().items()},
                        "layers": LAYERS,
                    },
                    path,
                )
            print(epoch, round(loss, 3), flush=True)


def predict(checkpoint, proposals, masked, output, device):
    rows = json.loads(proposals.read_bytes())
    variants = [
        (line[:a] + w + line[b:], a, a + len(w))
        for line, a, b, opts in rows
        for w, _ in opts
    ]
    unique = list(dict.fromkeys(variants))
    X = torch.from_numpy(features(masked, unique, device)).float()
    state = torch.load(checkpoint, weights_only=True)
    model = torch.nn.Sequential(
        torch.nn.Linear(X.shape[-1], 96),
        torch.nn.GELU(),
        torch.nn.Dropout(0.12),
        torch.nn.Linear(96, 2),
    )
    model.load_state_dict(state["weights"])
    model.eval()
    with torch.inference_mode():
        ps = (4 * model((X - state["mean"]) / state["std"])).tolist()
    result = dict(zip(unique, ps))
    out = []
    for line, a, b, opts in rows:
        vals = []
        for w, cloze in opts:
            first, right = result[line[:a] + w + line[b:], a, a + len(w)]
            vals.append([w, cloze, round(first, 4), [round(right, 4)]])
        out.append([line, a, b, vals])
    output.write_text(json.dumps(out))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["train", "predict"])
    p.add_argument("masked", type=Path)
    p.add_argument("work", type=Path)
    p.add_argument("--teacher", type=Path)
    p.add_argument("--corpus", type=Path)
    p.add_argument("--dialogue", type=Path)
    p.add_argument("--count", type=int, default=18000)
    p.add_argument("--proposals", type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--device", default="mps")
    a = p.parse_args()
    a.work.mkdir(parents=True, exist_ok=True)
    ck = a.work / "head.pt"
    if a.mode == "train":
        pairs = make_pairs(a.corpus, a.dialogue, a.count, 564219)
        seq = list(variants(pairs))
        print("training on", len(seq), "filled sentences", flush=True)
        y = teacher_scores(a.teacher, seq, a.device)
        print("teacher computed", flush=True)
        x = features(a.masked, seq, a.device)
        print("encoder computed", flush=True)
        fit(x, y, ck, a.device)
    else:
        predict(ck, a.proposals, a.masked, a.output, a.device)
