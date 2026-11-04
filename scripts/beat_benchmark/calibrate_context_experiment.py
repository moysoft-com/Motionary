#!/usr/bin/env python3
"""Compare experimental beat-confidence models on GTZAN and ARTBeaT.

This is an evaluation script, not an exported production calibrator. The
mixed-data runs use even ARTBeaT track IDs for training and odd IDs for
testing. Requires numpy, mir_eval and scikit-learn.
"""

import argparse
import json
from pathlib import Path
import numpy as np
import mir_eval
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.isotonic import IsotonicRegression


def features(times, prob):
    intervals = np.diff(times)
    output = []
    for i, p in enumerate(prob):
        near = intervals[max(i - 4, 0) : min(i + 4, len(intervals))]
        median = np.median(near) if len(near) else 0.5
        left = intervals[i - 1] if i else median
        right = intervals[i] if i < len(intervals) else median
        localp = prob[max(0, i - 3) : min(len(prob), i + 4)]
        logit = np.log(np.clip(p, 0.0001, 0.9999) / (1 - np.clip(p, 0.0001, 0.9999)))
        output.append(
            [
                logit,
                np.mean(localp),
                np.min(localp),
                abs(np.log(max(left, 1e-5) / median)),
                abs(np.log(max(right, 1e-5) / median)),
                abs(np.log(max(left, 1e-5) / max(right, 1e-5))),
                np.std(near) / max(median, 1e-5),
            ]
        )
    return np.asarray(output).reshape(-1, 7)


def data(path, loader):
    rows = json.load(open(path))
    rows = rows["rows"] if isinstance(rows, dict) else rows
    groups = []
    for row in rows:
        times = np.array(row["grid"])
        p = np.array(row["probabilities"])
        ref = loader(row["name"])
        ref = ref[ref >= 5]
        x = features(times, p)
        keep = times >= 5
        times = times[keep]
        p = p[keep]
        x = x[keep]
        y = np.zeros(len(times))
        for _, i in mir_eval.util.match_events(ref, times, 0.07):
            y[i] = 1
        groups.append((row["name"], x, y, p))
    return groups


def metric(p, y):
    ece = 0
    for i in range(10):
        m = (p >= i / 10) & (p < ((i + 1) / 10) if i < 9 else p <= 1)
        if m.any():
            ece += m.mean() * abs(p[m].mean() - y[m].mean())
    high = p >= 0.95
    return {
        "ece": round(float(ece), 4),
        "brier": round(float(np.mean((p - y) ** 2)), 4),
        "high_count": int(high.sum()),
        "high_precision": round(float(y[high].mean()), 4) if high.any() else None,
    }


parser = argparse.ArgumentParser()
parser.add_argument("gtzan_results", type=Path)
parser.add_argument(
    "gtzan_annotations", type=Path, help="directory containing .beats files"
)
parser.add_argument("artbeat_results", type=Path)
parser.add_argument(
    "artbeat_annotations", type=Path, help="directory containing _gt.csv files"
)
args = parser.parse_args()
gt = data(
    args.gtzan_results,
    lambda n: np.atleast_2d(np.loadtxt(args.gtzan_annotations / (n + ".beats")))[:, 0],
)
art = data(
    args.artbeat_results,
    lambda n: np.atleast_1d(np.loadtxt(args.artbeat_annotations / (n + "_gt.csv"))),
)
train = [r for r in gt if int(r[0].rsplit("_", 1)[1]) % 2 == 0]
test = [r for r in gt if int(r[0].rsplit("_", 1)[1]) % 2]
X = np.concatenate([r[1] for r in train])
Y = np.concatenate([r[2] for r in train])
P = np.concatenate([r[3] for r in train])
models = {
    "raw": None,
    "isotonic": IsotonicRegression(out_of_bounds="clip").fit(P, Y),
    "logistic": LogisticRegression(max_iter=1000).fit(X, Y),
    "hist": HistGradientBoostingClassifier(
        max_iter=100, max_leaf_nodes=10, l2_regularization=3, random_state=0
    ).fit(X, Y),
}
for name, model in models.items():
    print("\n", name)
    for label, group in [
        ("gtzan", test),
        ("blues", [r for r in test if "_blues_" in r[0]]),
        ("classical", [r for r in test if "_classical_" in r[0]]),
        ("artbeat", art),
    ]:
        x = np.concatenate([r[1] for r in group])
        y = np.concatenate([r[2] for r in group])
        p = np.concatenate([r[3] for r in group])
        pred = (
            p
            if model is None
            else (
                model.predict(p) if name == "isotonic" else model.predict_proba(x)[:, 1]
            )
        )
        print(label, metric(pred, y))

art_train = [r for r in art if int(r[0][:2]) % 2 == 0]
art_test = [r for r in art if int(r[0][:2]) % 2]
AX = np.concatenate([r[1] for r in art_train])
AY = np.concatenate([r[2] for r in art_train])
X2 = np.concatenate([X, AX])
Y2 = np.concatenate([Y, AY])
for share in [0.1, 0.3, 0.5]:
    weights = np.concatenate(
        [np.full(len(X), (1 - share) / len(X)), np.full(len(AX), share / len(AX))]
    ) * len(X2)
    for name, model in [
        ("logistic", LogisticRegression(max_iter=1000)),
        (
            "hist",
            HistGradientBoostingClassifier(
                max_iter=100, max_leaf_nodes=10, l2_regularization=3, random_state=0
            ),
        ),
    ]:
        model.fit(X2, Y2, sample_weight=weights)
        print("\nmixed", share, name)
        for label, group in [
            ("gtzan", test),
            ("classical", [r for r in test if "_classical_" in r[0]]),
            ("artbeat-heldout", art_test),
        ]:
            x = np.concatenate([r[1] for r in group])
            y = np.concatenate([r[2] for r in group])
            pred = model.predict_proba(x)[:, 1]
            print(label, metric(pred, y))
