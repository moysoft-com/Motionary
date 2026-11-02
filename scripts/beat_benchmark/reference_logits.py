#!/usr/bin/env python3
"""Compute original PyTorch small0 logits for GTZAN audio, for parity checking.

Usage: python reference_logits.py GTZAN.zip output.npz --count 500
Requires beat_this, numpy, soundfile, soxr and torch. GTZAN audio is read from
zip and not copied into this repository. This command can take many minutes.
"""
import argparse
import io
from pathlib import Path
import zipfile

import numpy as np
import soundfile as sf
import torch
from beat_this.inference import Audio2Frames

parser = argparse.ArgumentParser()
parser.add_argument("audio_zip", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--count", type=int, default=500)
parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
args = parser.parse_args()
torch.set_num_threads(2)
model = Audio2Frames(checkpoint_path="small0", device=args.device)
outputs = {}
with zipfile.ZipFile(args.audio_zip) as archive:
    files = sorted(x for x in archive.namelist() if x.endswith(".wav") and Path(x).name.count(".") == 2)
    # Interleave genres so partial results do not consist of one genre only.
    by_genre = {}
    for name in files:
        genre = Path(name).name.split(".")[0]
        by_genre.setdefault(genre, []).append(name)
    interleaved = [by_genre[g][i] for i in range(max(map(len, by_genre.values())))
                   for g in sorted(by_genre) if i < len(by_genre[g])]
    for path in interleaved:
        if len(outputs) // 2 >= args.count:
            break
        try:
            samples, rate = sf.read(io.BytesIO(archive.read(path)), dtype="float32")
            beat, downbeat = model(samples, rate)
        except (ValueError, RuntimeError, OSError) as exc:
            print(f"skipping {path}: {exc}", flush=True)
            continue
        genre, number, _ = Path(path).name.split(".")
        key = f"gtzan_{genre}_{number}"
        outputs[key + "_beat"] = beat.cpu().numpy()
        outputs[key + "_downbeat"] = downbeat.cpu().numpy()
        if len(outputs) % 50 == 0:
            print(f"processed {len(outputs) // 2}", flush=True)
np.savez_compressed(args.output, **outputs)
print(f"saved {len(outputs) // 2} tracks to {args.output}")
