#!/usr/bin/env python3
"""Evaluate the bundled Core ML pipeline against upstream Beat This GTZAN labels.

Usage: python evaluate_gtzan.py GTZAN.zip beat_this_annotations/gtzan --output results.json
Requires macOS, swiftc, numpy, soxr, soundfile and mir_eval. Audio is temporary
and is not redistributed. The first five seconds are trimmed as in Beat This.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

import mir_eval
import numpy as np
import soundfile as sf
import soxr

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("audio_zip", type=Path)
parser.add_argument("annotations", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
label_dir = args.annotations / "annotations" / "beats"
if not label_dir.is_dir():
    raise SystemExit(f"Missing annotation directory: {label_dir}")

with tempfile.TemporaryDirectory(prefix="motionary-gtzan-") as scratch:
    scratch = Path(scratch)
    pcm = scratch / "pcm"
    pcm.mkdir()
    skipped = []
    with zipfile.ZipFile(args.audio_zip) as archive:
        for item in archive.infolist():
            filename = Path(item.filename).name
            if not filename.endswith(".wav") or filename.count(".") != 2:
                continue
            genre, number, _ = filename.split(".")
            name = f"gtzan_{genre}_{number}"
            if not (label_dir / (name + ".beats")).exists():
                continue
            try:
                samples, rate = sf.read(io.BytesIO(archive.read(item)), dtype="float32")
                if samples.ndim == 2:
                    samples = samples.mean(axis=1)
                if rate != 22_050:
                    samples = soxr.resample(samples, rate, 22_050)
                if not np.isfinite(samples).all():
                    raise ValueError("non-finite audio")
                samples.astype("<f4").tofile(pcm / (name + ".f32"))
            except (ValueError, RuntimeError, OSError) as exc:
                skipped.append({"file": filename, "error": str(exc)})
    executable = scratch / "benchmark"
    source_dir = root / "Motionary" / "MediaPipeline"
    sources = [source_dir / name for name in ("BeatThisInference.swift", "MetricBeatDecoder.swift",
               "BeatTimingRefiner.swift", "MeterDecoder.swift", "MusicStructureAnalyzer.swift")]
    subprocess.run(["swiftc", "-O", *map(str, sources), str(root / "scripts/beat_benchmark/main.swift"),
                    "-o", str(executable)], check=True)
    model = root / "Motionary/Resources/BeatThis/BeatThis.mlmodelc"
    rows = []
    proc = subprocess.Popen([str(executable), str(model), str(pcm)], stdout=subprocess.PIPE, text=True)
    assert proc.stdout is not None
    for line in proc.stdout:
        row = json.loads(line)
        annotation = np.atleast_2d(np.loadtxt(label_dir / (row["name"] + ".beats")))
        reference = annotation[annotation[:, 0] >= 5, 0]
        downbeats = annotation[(annotation[:, 0] >= 5) & (annotation[:, 1] == 1), 0]
        for key in ("direct", "grid", "refined", "downbeats"):
            estimate = np.asarray(row[key], dtype=float)
            estimate = estimate[estimate >= 5]
            target = downbeats if key == "downbeats" else reference
            row[key + "_f1"] = float(mir_eval.beat.f_measure(target, estimate)) if len(target) and len(estimate) else 0.0
            if key != "downbeats" and len(target) > 2 and len(estimate) > 2:
                row[key + "_continuity"] = list(map(float, mir_eval.beat.continuity(target, estimate)))
        rows.append(row)
        if len(rows) % 50 == 0:
            print(f"processed {len(rows)}", flush=True)
    if proc.wait() != 0:
        raise SystemExit("Swift benchmark failed")
    result = {"rows": rows, "skipped": skipped}
    args.output.write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print("tracks", len(rows), "skipped", len(skipped))
    for key in ("direct", "grid", "refined", "downbeats"):
        print(key, "mean F1", round(float(np.mean([r[key + "_f1"] for r in rows])), 4))
