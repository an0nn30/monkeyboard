"""Fit the long-word choice model on recorded disagreements, with regression constraints."""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.optimize import LinearConstraint, minimize
from scipy.special import expit

def load(paths):
    observations = [json.loads(line) for path in paths for line in path.read_text().splitlines()]
    decisive = [row for row in observations if row["word"] in row["pair"]]
    return (np.asarray([row["features"] for row in decisive]),
            np.asarray([row["word"] == row["pair"][1] for row in decisive]))

def fit(training, regression):
    x, target = training
    center, scale = x.mean(axis=0), x.std(axis=0)
    scale[scale == 0] = 1
    def design(rows):
        return np.column_stack((np.ones(len(rows)), (rows - center) / scale))
    x = design(x)
    rx, ry = regression
    # Maintain a small margin for known losses *and* known gains. These cases
    # belong to development; only the separately reserved swipes measure accuracy.
    constraints = LinearConstraint(design(rx) * np.where(ry, 1, -1)[:, None], 0.1, np.inf)
    strength = 0.01
    def objective(w):
        z = x @ w
        loss = np.mean(np.logaddexp(0, z) - target * z)
        penalty = strength * np.dot(w[1:], w[1:]) / 2
        gradient = x.T @ (expit(z) - target) / len(target) + strength * np.r_[0, w[1:]]
        return loss + penalty, gradient
    result = minimize(objective, np.zeros(x.shape[1]), jac=True, method="SLSQP",
                      constraints=[constraints], options={"maxiter": 300, "ftol": 1e-9})
    if not result.success:
        raise RuntimeError(result.message)
    weights = result.x[1:] / scale
    return np.r_[result.x[0] - center @ weights, weights]

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("regression", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("training", type=Path, nargs="+")
    args = parser.parse_args()
    weights = fit(load(args.training), load([args.regression]))
    if len(weights) != 10:
        raise ValueError("The shipping ranker uses nine generic features and an intercept")
    args.output.write_text("[" + ", ".join(f"{w:.9f}" for w in weights) + "]\n")
