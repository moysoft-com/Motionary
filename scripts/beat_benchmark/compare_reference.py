#!/usr/bin/env python3
"""Compare original PyTorch and Core ML logits and direct beat decisions."""
import argparse
import json
from pathlib import Path
import numpy as np
import mir_eval

p = argparse.ArgumentParser()
p.add_argument("results", type=Path)
p.add_argument("reference", type=Path)
p.add_argument("--output", type=Path)
a = p.parse_args()
rows = {r["name"]: r for r in json.loads(a.results.read_text())["rows"]}
reference = np.load(a.reference)
keys = sorted(k[:-5] for k in reference.files if k.endswith("_beat"))
report = []
for key in keys:
    if key not in rows:
        continue
    row = rows[key]
    entry = {"name": key}
    for feature, col in (("beat", "beatLogits"), ("downbeat", "downbeatLogits")):
        x = np.asarray(reference[key + "_" + feature], dtype=float)
        y = np.asarray(row[col], dtype=float)
        n = min(len(x), len(y))
        if n < 15:
            continue
        difference = np.abs(x[6:n-6] - y[6:n-6])
        entry[feature + "_mae"] = float(np.mean(difference))
        entry[feature + "_max"] = float(np.max(difference))
        def peaks(z):
            # Beat This uses a 7-frame maximum filter, positive logits and
            # averages adjacent equal maxima.
            from scipy.ndimage import maximum_filter1d
            candidates = np.flatnonzero((z > 0) & (z == maximum_filter1d(z, 7, mode="constant", cval=-np.inf)))
            groups = np.split(candidates, np.where(np.diff(candidates) > 1)[0] + 1)
            return np.asarray([float(np.mean(g)) for g in groups if len(g)])
        xp, yp = peaks(x[:n]), peaks(y[:n])
        entry[feature + "_exact_peaks"] = bool(np.array_equal(xp, yp))
        entry[feature + "_peak_f1_20ms"] = float(mir_eval.beat.f_measure(xp / 50, yp / 50, f_measure_threshold=0.021)) if len(xp) and len(yp) else 0.0
    report.append(entry)
summary = {"tracks": len(report)}
for feature in ("beat", "downbeat"):
    selected = [r for r in report if feature + "_mae" in r]
    if selected:
        summary[feature] = {
            "mean_logit_mae": float(np.mean([r[feature + "_mae"] for r in selected])),
            "worst_logit_difference": float(max(r[feature + "_max"] for r in selected)),
            "exact_peak_tracks": int(sum(r[feature + "_exact_peaks"] for r in selected)),
            "mean_peak_f1_20ms": float(np.mean([r[feature + "_peak_f1_20ms"] for r in selected]))
        }
print(json.dumps(summary, indent=2))
if a.output:
    a.output.write_text(json.dumps({"summary": summary, "tracks": report}, indent=2) + "\n")
