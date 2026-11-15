"""Generate a masked-model shortlist without reading benchmark labels."""

import argparse
import gzip
import json
import re
import subprocess
from pathlib import Path

import torch
from rapidfuzz.distance import DamerauLevenshtein
from transformers import RobertaForMaskedLM, RobertaTokenizerFast

WORDS = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")
ROOT = Path(__file__).resolve().parents[3]


def form(typed, lower):
    if lower == "i" or lower.startswith("i'"):
        return "I" + lower[1:]
    return lower.capitalize() if typed.istitle() else lower


@torch.inference_mode()
def proposals(lines, args):
    tokenizer = RobertaTokenizerFast.from_pretrained(args.masked)
    model = (
        RobertaForMaskedLM.from_pretrained(args.masked).eval().half().to(args.device)
    )
    sites = []
    queries = []
    for line in lines:
        for match in WORDS.finditer(line):
            word = match.group()
            left, right = line[: match.start()], line[match.end() :]
            if len(word) < 2 or (
                word != word.lower() and (left.strip() or not word.istitle())
            ):
                continue
            sites.append((line, match.start(), match.end(), word))
            queries.append(f"{left.strip()}\t{word}\t{right.strip()}")
    answers = subprocess.run(
        [args.probe, args.resources],
        input="\n".join(queries) + "\n",
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    assert len(answers) == len(sites)
    vocab = json.loads(
        (ROOT / "Keyboard/Resources/contextual55-vocab.txt").read_text()
    )["words"]
    pending = []
    for (line, a, b, source), answer in zip(sites, answers):
        _repair, _known, protected, *words = answer.split("\t")
        if protected == "protected" or not words:
            continue
        lower = source.lower()
        choices = {
            w
            for w in words
            if w in vocab and (DamerauLevenshtein.distance(w, lower) <= 2 or "'" in w)
        }
        choices.update(
            lower + x
            for x in ("'re", "'ve", "'d", "'ll", "'s", "n't", "'m")
            if lower + x in vocab
        )
        if len(choices - {lower}) == 0:
            continue
        left = tokenizer.encode(line[:a].rstrip(), add_special_tokens=False)
        right = tokenizer.encode(line[b:], add_special_tokens=False)
        before = left[-18:]
        masked = [0] + before + [50264] + right[: 29 - len(before)] + [2]
        prefix = " " if a and line[a - 1].isspace() else ""
        options = [source] + sorted(form(source, w) for w in choices if w != lower)
        ids = [
            tokenizer.encode(prefix + w.replace("’", "'"), add_special_tokens=False)
            for w in options
        ]
        pending.append((line, a, b, masked, len(before) + 1, options, ids))
    rows = []
    for k in range(0, len(pending), 48):
        batch = pending[k : k + 48]
        width = max(len(r[3]) for r in batch)
        x = torch.tensor(
            [r[3] + [1] * (width - len(r[3])) for r in batch], device=args.device
        )
        states = model.roberta(x, attention_mask=x.ne(1)).last_hidden_state
        logits = (
            model.lm_head(states[torch.arange(len(batch)), [r[4] for r in batch]])
            .float()
            .log_softmax(-1)
            .cpu()
            .numpy()
        )
        for (line, a, b, _, _, options, ids), probs in zip(batch, logits):
            source = options[0].lower()

            scores = []
            for word, pieces in zip(options, ids):
                dist = DamerauLevenshtein.distance(word.lower(), source)
                prior = max(0, dist - 1) * (0.65 if "'" in word + source else 2.0)
                scores.append(float(probs[pieces[0]]) - prior - 1.5 * (len(pieces) - 1))
            ranked = sorted(
                range(1, len(options)), key=scores.__getitem__, reverse=True
            )[:6]
            if not ranked or scores[ranked[0]] < scores[0] - 3 or scores[0] > -3:
                continue
            rows.append(
                (line, a, b, [(options[j], round(scores[j], 3)) for j in [0] + ranked])
            )
    return rows


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("masked", type=Path)
    p.add_argument("probe", type=Path)
    p.add_argument("resources", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("rendered", nargs="+", type=Path)
    p.add_argument("--device", default="mps")
    args = p.parse_args()
    lines = set()
    for path in args.rendered:
        with gzip.open(path, "rt") as rendered:
            lines.update(r["final"] for r in map(json.loads, rendered))
    scores = proposals(sorted(lines), args)
    args.output.write_text(json.dumps(scores))
    print(
        len(lines),
        "sentences",
        len(scores),
        "sites",
        sum(len(r[3]) for r in scores),
        "candidate sentences",
    )
