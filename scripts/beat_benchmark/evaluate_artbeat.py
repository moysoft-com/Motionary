#!/usr/bin/env python3
"""Evaluate the actual Swift decoder and bundled Core ML model on ARTBeaT.

Usage: python evaluate_artbeat.py /path/to/ARTBeaT_Dataset
Requires macOS, Xcode command-line tools, numpy, soundfile, soxr, mir_eval.
The CC-BY-4.0 ARTBeaT dataset is obtained separately from AudioLabs Erlangen.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import mir_eval
import numpy as np
import soundfile as sf
import soxr

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("dataset", type=Path)
parser.add_argument("--output", type=Path, help="write per-track JSON results")
args = parser.parse_args()
audio_dir = args.dataset / "Audio"
annotations = args.dataset / "Annotations" / "gt_csv"
paths = sorted(audio_dir.glob("*.wav"))
if not paths:
    raise SystemExit(f"No WAV files found in {audio_dir}")

with tempfile.TemporaryDirectory(prefix="motionary-artbeat-") as temp:
    temp = Path(temp)
    pcm = temp / "pcm"
    pcm.mkdir()
    for path in paths:
        audio, rate = sf.read(path, dtype="float32")
        if audio.ndim == 2:
            audio = audio.mean(axis=1)
        if rate != 22_050:
            audio = soxr.resample(audio, rate, 22_050)
        audio.astype("<f4").tofile(pcm / (path.stem + ".f32"))
    executable = temp / "benchmark"
    sources = [ROOT / "Motionary/MediaPipeline" / name for name in (
        "BeatThisInference.swift", "MetricBeatDecoder.swift", "BeatTimingRefiner.swift",
        "MeterDecoder.swift", "MusicStructureAnalyzer.swift")]
    subprocess.run(["swiftc", "-O", *map(str, sources), str(ROOT / "scripts/beat_benchmark/main.swift"),
                    "-o", str(executable)], check=True)
    model = ROOT / "Motionary/Resources/BeatThis/BeatThis.mlmodelc"
    process = subprocess.run([str(executable), str(model), str(pcm)], check=True,
                             capture_output=True, text=True)
    rows = []
    for line in process.stdout.splitlines():
        row = json.loads(line)
        reference = np.atleast_1d(np.loadtxt(annotations / (row["name"] + "_gt.csv")))
        for key in ("direct", "grid", "refined"):
            estimate = np.asarray(row[key])
            row[key + "_f1_70ms"] = float(mir_eval.beat.f_measure(reference, estimate, f_measure_threshold=0.07)) if len(estimate) else 0.0
        rows.append(row)
        print(row["name"], *(f"{row[key + '_f1_70ms']:.3f}" for key in ("direct", "grid", "refined")))
    for key in ("direct", "grid", "refined"):
        print(f"mean {key}: {np.mean([row[key + '_f1_70ms'] for row in rows]):.3f}")
    if args.output:
        args.output.write_text(json.dumps(rows, indent=2) + "\n")
