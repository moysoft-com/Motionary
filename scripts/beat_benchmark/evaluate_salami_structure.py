#!/usr/bin/env python3
"""Exploratory structure comparison on separately obtained SALAMI audio.

Audio files must be named <SALAMI ID>.mp3. This isolates the structural
features on a fixed 120 BPM grid; it is not an end-to-end editor benchmark.
Requires numpy, soundfile, soxr, mir_eval and the macOS Swift toolchain.
"""
import argparse
import csv
import hashlib
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
parser.add_argument('annotations', type=Path, help='salami-data-public checkout')
parser.add_argument('audio', type=Path, help='directory of ID-named MP3 files')
parser.add_argument('--source', type=Path, default=ROOT / 'Motionary/MediaPipeline/MusicStructureAnalyzer.swift')
parser.add_argument('--output', type=Path)
args = parser.parse_args()

with (args.annotations / 'metadata/id_index_internetarchive.csv').open() as stream:
    metadata = {row['SONG_ID']: float(row['SONG_DURATION']) for row in csv.DictReader(stream)
                if row['SONG_DURATION']}

def select(scores, count, duration):
    candidates = [i for i in range(1, len(scores) - 1)
                  if 5 < i * 0.5 < duration - 5 and scores[i] >= scores[i - 1] and scores[i] > scores[i + 1]]
    chosen = []
    for i in sorted(candidates, key=lambda i: scores[i], reverse=True):
        if all(abs(i - j) >= 6 for j in chosen):
            chosen.append(i)
        if len(chosen) >= count:
            break
    return np.array(sorted(i * 0.5 for i in chosen))

with tempfile.TemporaryDirectory(prefix='motionary-salami-') as directory:
    directory = Path(directory)
    hashes = {}
    for path in sorted(args.audio.glob('*.mp3')):
        try:
            audio, rate = sf.read(path, dtype='float32')
            if path.stem not in metadata or abs(len(audio) / rate - metadata[path.stem]) > 2:
                print('Excluded duration mismatch:', path.name)
                continue
            if audio.ndim == 2:
                audio = audio.mean(axis=1)
            if rate != 22050:
                audio = soxr.resample(audio, rate, 22050)
            audio.astype('<f4').tofile(directory / (path.stem + '.f32'))
            hashes[path.stem] = hashlib.sha256(path.read_bytes()).hexdigest()
        except (RuntimeError, ValueError) as error:
            print('Excluded unreadable audio:', path.name, error)
    files = sorted(directory.glob('*.f32'))
    if not files:
        raise SystemExit('No matching audio files')
    binary = directory / 'structure-benchmark'
    subprocess.run(['swiftc', '-O', str(args.source), str(ROOT / 'scripts/beat_benchmark/structure/main.swift'),
                    '-o', str(binary)], check=True)
    output = subprocess.run([str(binary), *map(str, files)], check=True, capture_output=True, text=True)
    rows = []
    for result in map(json.loads, output.stdout.splitlines()):
        annotation = args.annotations / 'annotations' / result['name'] / 'parsed/textfile1_uppercase.txt'
        if not annotation.exists():
            continue
        reference = []
        for line in annotation.read_text().splitlines():
            try:
                time = float(line.split('\t')[0])
            except (IndexError, ValueError):
                continue
            if 5 < time < result['duration'] - 5:
                reference.append(time)
        if len(reference) < 2:
            continue
        row = {'name': result['name'], 'audio_sha256': hashes[result['name']],
               'duration': result['duration'], 'references': len(reference)}
        for mode, count in [('fixed', max(1, int(result['duration'] / 8))), ('oracle', len(reference))]:
            predicted = select(result['boundaries'], count, result['duration'])
            matches = len(mir_eval.util.match_events(np.asarray(reference), predicted, window=3))
            precision = matches / max(len(predicted), 1)
            recall = matches / len(reference)
            row[mode + '_f1'] = 2 * precision * recall / max(precision + recall, 1e-12)
        rows.append(row)
    if not rows:
        raise SystemExit('No recordings with usable annotations')
    print('Tracks:', len(rows))
    for mode in ('fixed', 'oracle'):
        print(mode, 'mean F1:', float(np.mean([row[mode + '_f1'] for row in rows])))
    if args.output:
        args.output.write_text(json.dumps(rows, indent=2) + '\n')
