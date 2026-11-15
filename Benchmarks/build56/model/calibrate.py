"""Fit the acceptance intercept and coefficients from public development features."""
import gzip
import json
from pathlib import Path

from sklearn.linear_model import LogisticRegression


def coefficients():
    with gzip.open(Path(__file__).with_name("development-features.jsonl.gz"), "rt") as stream:
        records = [json.loads(line) for line in stream]
    model = LogisticRegression(C=0.12, max_iter=1000)
    model.fit([features for _, _, features in records], [correct for _, correct, _ in records])
    return [float(model.intercept_[0]), *model.coef_[0].tolist()]


if __name__ == "__main__":
    print(json.dumps(coefficients()))
