"""Compare the upstream small0 reference timing on a reproducible click track.

Requires the `beat_this` Python package, numpy, torch, and the upstream weights
(downloaded by beat_this). This is a diagnostic fixture, not a quality benchmark.
"""
import numpy as np
from beat_this.inference import Audio2Frames

sample_rate = 22_050
samples = np.zeros(31 * sample_rate, dtype=np.float32)
offsets = np.arange(1_102)
pulse = np.exp(-offsets / 220.5) * np.sin(2 * np.pi * 1_000 * offsets / sample_rate)
for beat in range(62):
    start = beat * sample_rate // 2
    samples[start:start + len(pulse)] = pulse

beat_logits, _ = Audio2Frames(checkpoint_path="small0", device="cpu")(samples, sample_rate)
logits = beat_logits.numpy()
peaks = np.flatnonzero((logits[1:-1] > 0) & (logits[1:-1] >= logits[:-2]) & (logits[1:-1] > logits[2:])) + 1
print(f"count={len(peaks)} first_seconds={peaks[:12] / 50}")
