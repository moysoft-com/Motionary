#!/usr/bin/env python3
"""Research-only comparison against externally installed CASM.

The CASM repository did not advertise a license at the time this was written;
its source and parameter file are not bundled here. Install or supply it
separately if permitted. This script evaluates its public API only.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import mir_eval
from casm_beat_tracking import CASMDecoder

p = argparse.ArgumentParser()
p.add_argument("results", type=Path)
p.add_argument("annotations", type=Path)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
rows = json.loads(a.results.read_text())["rows"]
label_dir = a.annotations / "annotations" / "beats"
model = CASMDecoder()
result = []
for row in rows:
    try:
        beat, downbeat = model.decode(np.asarray(row["beatLogits"]),
                                      np.asarray(row["downbeatLogits"]), input_type="logits")
        beat, downbeat = np.asarray(beat), np.asarray(downbeat)
        ann = np.atleast_2d(np.loadtxt(label_dir / (row["name"] + ".beats")))
        ref = ann[ann[:, 0] >= 5, 0]
        downref = ann[(ann[:, 0] >= 5) & (ann[:, 1] == 1), 0]
        beat = beat[beat >= 5]
        downbeat = downbeat[downbeat >= 5]
        f1 = float(mir_eval.beat.f_measure(ref, beat)) if len(ref) and len(beat) else 0
        downf1 = float(mir_eval.beat.f_measure(downref, downbeat)) if len(downref) and len(downbeat) else 0
        continuity = list(map(float, mir_eval.beat.continuity(ref, beat))) if len(ref) > 2 and len(beat) > 2 else [0.0] * 4
        result.append({"name": row["name"], "f1": f1, "downbeatF1": downf1, "continuity": continuity})
    except (ValueError, RuntimeError) as exc:
        print(f"{row['name']}: {exc}", flush=True)
    if len(result) % 100 == 0:
        print(f"processed {len(result)}", flush=True)
a.output.write_text(json.dumps(result) + "\n")
print("tracks", len(result), "beat F1", float(np.mean([x["f1"] for x in result])),
      "downbeat F1", float(np.mean([x["downbeatF1"] for x in result])),
      "CMLt", float(np.mean([x["continuity"][1] for x in result])))
