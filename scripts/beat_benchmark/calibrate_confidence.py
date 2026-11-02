#!/usr/bin/env python3
"""Fit/evaluate candidate beat confidence with disjoint GTZAN tracks.

Usage: python calibrate_confidence.py results.json /path/to/gtzan [--output candidate.json]
Requires numpy, scikit-learn, and mir_eval. Even-numbered tracks are used to
fit; odd-numbered tracks are held out. This does not establish out-of-domain
calibration, nor calibrate cut suitability or timing.
"""
import argparse
import json
from pathlib import Path
import numpy as np
from sklearn.isotonic import IsotonicRegression
import mir_eval

parser = argparse.ArgumentParser()
parser.add_argument("results", type=Path)
parser.add_argument("annotations", type=Path)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
rows = json.loads(args.results.read_text())["rows"]
label_dir = args.annotations / "annotations" / "beats"
data = {"train": [], "test": []}
for row in rows:
    name = row["name"]
    annotated = np.atleast_2d(np.loadtxt(label_dir / (name + ".beats")))[:, 0]
    annotated = annotated[annotated >= 5]
    times = np.asarray(row["grid"], dtype=float)
    probability = np.asarray(row["probabilities"], dtype=float)
    if len(times) != len(probability):
        raise ValueError(f"Mismatched beats and probabilities for {name}")
    keep = times >= 5
    times, probability = times[keep], probability[keep]
    labels = np.zeros(len(times))
    for _, estimate_index in mir_eval.util.match_events(annotated, times, 0.07):
        labels[estimate_index] = 1
    group = "train" if int(name.rsplit("_", 1)[1]) % 2 == 0 else "test"
    data[group].append((name, probability, labels))

train_p = np.concatenate([x[1] for x in data["train"]])
train_y = np.concatenate([x[2] for x in data["train"]])
test_p = np.concatenate([x[1] for x in data["test"]])
test_y = np.concatenate([x[2] for x in data["test"]])
calibrator = IsotonicRegression(out_of_bounds="clip").fit(train_p, train_y)
cal_p = calibrator.predict(test_p)

def metrics(p, y):
    brier = np.mean((p-y)**2)
    ece = 0.0
    for index in range(10):
        mask = (p >= index / 10) & (p < (index + 1) / 10 if index < 9 else p <= 1)
        if np.any(mask):
            ece += np.mean(mask) * abs(np.mean(p[mask]) - np.mean(y[mask]))
    return {"n": len(p), "brier": float(brier), "ece_10_bins": float(ece)}

report = {"train_tracks": len(data["train"]), "test_tracks": len(data["test"]),
          "raw": metrics(test_p, test_y), "calibrated": metrics(cal_p, test_y), "genres": {}}
for genre in sorted({x[0].split("_")[1] for x in data["test"]}):
    subset = [x for x in data["test"] if x[0].split("_")[1] == genre]
    p = np.concatenate([x[1] for x in subset])
    y = np.concatenate([x[2] for x in subset])
    report["genres"][genre] = metrics(calibrator.predict(p), y)
report["thresholds"] = {"x": calibrator.X_thresholds_.tolist(), "y": calibrator.y_thresholds_.tolist()}
print(json.dumps(report, indent=2))
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
