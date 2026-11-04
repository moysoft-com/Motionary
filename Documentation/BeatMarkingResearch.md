# Beat marking: implementation and validation status

The audio analysis service uses Beat This `small0`, a local-periodicity beat
path, beat-synchronous meter selection, and local onset refinement. If the
structured decoder fails, upstream-style direct peak picking is tried; if the
neural path fails, the earlier signal-based tracker is tried. The selected
method is persisted and the UI identifies the signal fallback. Failure of every
level retains the existing analysis. Structured results are checked after
excluding beats outside the audible boundaries; if fewer than three survive,
direct peak picking is attempted before falling back to the signal tracker.
Meter decoding operates on the retained beats. Cancellation is propagated.

The timeline beat remains on the metric grid. Suggested cuts seek to that same
visible beat position; the separately detected audible onset remains stored as
analysis evidence. Binary, ternary and quaternary subbeat *hypotheses*
are selectable in the editor; selecting them adds mapped timeline and snapping
points. A beat-synchronous spectral and RMS/bass contrast analysis samples up
to eight windows across each beat and produces
accent, boundary, drop, break and edit-ranking metadata. These are heuristics,
not verified section labels or calibrated cut probabilities. Nearby drop/break
candidates are deduplicated. Ranked suggestions are exposed in the editor.

This remains a development implementation, not a production-ready release:
confidence calibration does not generalize adequately, the requested dataset
and editorial-judgment targets have not been met, and several processing
components described by the research report are still missing or unvalidated.

## Model provenance

`BeatThis.mlmodelc` is the FP16 `small0` conversion from
[palmier-pro](https://github.com/palmier-io/palmier-pro/tree/5b806b35165da70d2834b53dfc022abc8e00a12e/models/beat_this).
Its model README says the model and upstream weights are MIT licensed; the
upstream license is included alongside it. The surrounding repository is
GPL-3.0 and the converted artifact's distribution provenance should be
independently reviewed. No palmier-pro application source was copied.
SHA-256 of `weights/weight.bin`:
`e4f80e477a99bfc8e838c90d625e8be5a8d2f63e711865c3445d778fb527be37`.
The FP16 artifact remains in the repository for historical benchmarking, but
is excluded from the app target; new analyses use the FP32 model exclusively.
The FP32 conversion used for new analyses was generated from the same small0 checkpoint using
the same external conversion workflow and passed its synthetic click gate.
Its `weights/weight.bin` SHA-256 is
`fffd124276272c39342f08bb83c05a647f99f58777406bb27d7ba6776db01b9f`.
The graph consumes 661,059 mono samples at 22,050 Hz and returns 1,500
beat/downbeat frames. Current chunking retains the upstream six-frame context
and the first valid prediction. Short clips still use a padded fixed-size graph
rather than upstream's variable-length graph.

## Reproducible evaluation

The programs in `scripts/beat_benchmark/` accept independently obtained data;
the music is not bundled. Beat This's `small0` checkpoint excludes GTZAN from
training. The GTZAN audio mirror used here has not been independently verified
byte-for-byte against the original release. We used upstream Beat This GTZAN
annotations, 998 readable tracks out of 999 (`jazz.00054` was corrupt),
`mir_eval`, a ±70 ms window and the upstream exclusion of the first five
seconds. Audio was decoded with soundfile and resampled using soxr, so this is
not an end-to-end measurement of AVFoundation decoding.

| GTZAN measure | Direct 7-frame peaks | Structured grid | Onset-refined |
| --- | ---: | ---: | ---: |
| Beat F1 | 0.8810 | 0.8776 | 0.8734 |
| Beat CMLt | 0.7896 | 0.7975 | 0.7921 |

Structured downbeat F1 was 0.7593. The report's targets of 0.89 Beat F1,
0.81 Beat CMLt and 0.79 Downbeat F1 were not met. Refinement improved F1 on
62 tracks and worsened it on 189; mean change was -0.00418, paired Wilcoxon
p=3.79e-12. Consequently the timeline retains grid time; this decision was
made on GTZAN, so an independent acceptance set is still needed.

ARTBeaT by Rico Rosenbusch, [CC BY 4.0](https://audiolabs-erlangen.de/resources/MIR/2024-ARTBeaT),
contains 25 created music and deliberately difficult rhythm examples. On these
25 tracks without the five-second exclusion, mean Beat F1 was 0.7499 for the
correct seven-frame direct rule, 0.7428 for the structured grid and 0.7436
for onset-refined markers. Track 23 received F1 0 from both methods because
its model pulse and annotations differ in phase. These scores are not a
representative genre benchmark. The structure analyzer ran on all 25 tracks,
but this dataset does not label professional cuts, accents or drops and cannot
validate their precision.

An exploratory structure-only comparison used 27 short Live Music Archive
recordings with [SALAMI](https://github.com/DDMAL/salami-data-public)
upper-level human annotations (commit `8e4f95d18a3ab628c53011fa5a43e9d3be27965d`).
Each method used the same artificial 120 BPM grid, local maxima at least three
seconds apart, a fixed budget of one candidate per eight seconds, and a
three-second matching window. Mean boundary F1 changed from 0.4052 for the
previous midpoint-only features to 0.4196 for multiple windows; paired Wilcoxon
p=0.53. A second, oracle-count comparison uses the known number of reference
boundaries and is not an operational score. Two mismatched audio durations were
excluded; the remaining audio was not independently aligned to the annotations.
The sample is short, nonrandom, live-music-only, and does not validate drops,
accents, cuts or end-to-end inference. Individual results and audio hashes are
in `BeatStructureEvaluation.json`; `evaluate_salami_structure.py` reproduces
the measurement with separately obtained audio and annotations. The broader
window sampling changes ranking and increases computation; its performance on
physical iPhones and iPads has not been measured.

A research-only comparison against the public CASM API on the same GTZAN
activations gave Beat F1 0.8818, Downbeat F1 0.7700 and Beat CMLt 0.7898. The
[CASM repository](https://github.com/zhanh-he/casm-beat-tracking) did not
contain an identifiable license when inspected; neither its code nor its
configuration was copied into Motionary. This is not the authors' full published
protocol. It improves F1 relative to this decoder while reducing beat CMLt.

An independently implemented experimental adaptive decoder was also evaluated
on the same stored activations. Its transition penalty depends on the margin
between local autocorrelation tempo hypotheses; four penalty weights were
explored on even-numbered tracks and checked on odd-numbered tracks. At weight
1, held-out Beat F1 increased from 0.8761 to 0.8814, while Beat CMLt decreased
from 0.7918 to 0.7888 (tracks without sufficient beats count as zero in this
comparison). The paired F1 change was not statistically significant
(Wilcoxon p=0.065). This is an exploratory split of one dataset, not an
independent validation, and no downbeat results were established. The
experimental decoder is not included in the application.

## PyTorch/Core ML parity

On 500 GTZAN clips, original PyTorch `small0` and Core ML were compared using
the upstream seven-frame maximum rule. The PyTorch reference ran on MPS; one
CPU/MPS spot check differed by at most 0.00024 in logits. Mean beat-logit MAE
was 0.1155; beat peaks were exactly identical on 142/500 tracks and mean peak
F1 at 20 ms was 0.9918. Downbeat-logit MAE was 0.1026, exact downbeat peaks
occurred on 242/500 tracks, and downbeat peak F1 was 0.9855. The direct Beat
F1 against GTZAN on these same 500 clips was 0.83769 for PyTorch and 0.83701
for Core ML; paired mean change -0.00069, Wilcoxon p=0.20. This does not show
a statistically significant F1 difference on this set, but marker decisions
are not identical and the report's strict marker-parity target is not met.

For comparison, on the same 100-clip exploratory subset the earlier chunking
had beat-logit MAE 0.5294 and peak F1 at 20 ms 0.9800; reference-style
chunking achieved 0.1172 and 0.9940. This is a development-set comparison;
model behavior on shorter clips and other genres needs independent evaluation.

The single 120 BPM click fixture puts both PyTorch and Core ML peaks around
20 ms after the clicks. A nearby transient is therefore retained as separate
onset evidence, not subtracted by a fixed offset. Sample zero remains
ambiguous when a recording begins already sounding.

## Confidence and edit quality

An isotonic candidate trained on 498 even-numbered GTZAN tracks and evaluated
on 500 odd-numbered tracks used one-to-one beat matches at 70 ms. Held-out
Brier score improved from 0.1033 to 0.0908 and ten-bin ECE from 0.0954 to
0.0170 overall. Classical ECE remained 0.1086 and blues ECE 0.0904. The
candidate is not shipped: group and out-of-domain reliability are inadequate.
The procedure is `calibrate_confidence.py`. Raw beat probability, periodicity,
and edit score must not be interpreted as calibrated correctness probabilities;
the workspace labels the latter periodicity-derived value “Rhythm strength”.

Further experiments added local activation and inter-beat-interval features
to logistic and histogram-boosted models. The latter improved held-out GTZAN
Brier score to 0.0828 and overall ECE to 0.0114, but on the 25 independent
ARTBeaT recordings its 152 predictions at or above 0.95 had only 86.8% beat
precision. Mixing even-numbered ARTBeaT tracks into training did not achieve
95% precision on the odd-numbered ARTBeaT tracks for any evaluated weighting.
These small exploratory splits do not prove a general impossibility; they do
show that these candidates do not satisfy the requested cross-domain reliability.
The reproducible experiment is `calibrate_context_experiment.py`; no
experimental calibrator is shipped.

There is no annotated professional edit-point set, multiple-rater evaluation,
phrase-level ground truth, or validated 95% high-confidence edit precision.
The present ranking must not be presented as meeting those targets. Complete
multi-resolution DSP, harmonic/self-similarity structure analysis, multiple
metrical hypotheses, maximum-quality mode and confidence calibration remain
open. The DSP fallback still contains its legacy fixed onset offset.

## Device and timing

A separate temporary benchmark app on a connected iPhone 15 loaded the FP16
model and ran a fixed-size prediction on ten seconds of zero-padded input; it
was removed afterwards and did not overwrite the existing Motionary app.
CPU-only load/inference were 0.232/0.145 seconds first run and 0.013/0.143
seconds second run. `.all` was 5.474/0.661 and 0.059/0.295 seconds. These are
single measurements, not latency distributions or thermal/energy tests. The
model remains CPU-only pending a broader device matrix. The iPad was offline.

A separately converted FP32 graph occupies 13 MB instead of 6.6 MB and is
used for new analyses. On the same phone its
initial CPU-only load/inference were 0.265/0.553 seconds, and `.all`
0.519/4.951 seconds. On 500 tracks its beat-logit MAE was 0.0652, exact beat
peaks occurred on 219 tracks, and peak F1 at 20 ms was 0.9965. For the same
tracks, PyTorch/FP16/FP32 direct Beat F1 was 0.83769/0.83701/0.83777. The
FP32–FP16 difference was not significant in a paired Wilcoxon test (p=0.33).
This supports closer reference parity but not a demonstrated F1 gain. Longer
recordings, older iPhones, iPads and thermal behavior remain unprofiled.

Decoded PCM is spooled to a temporary mapped file. The sample-time mapper
inserts timestamp gaps and removes negative preroll and overlapping frames,
allowing one sample of timestamp rounding tolerance. Synthetic tests, an
ordinary WAV and a compressed fixture with a nonzero first presentation time
pass on iOS 18.6 simulator. Other containers, edit lists and physical-device
resampling still require verification.

## Simulator verification

The updated build and 36 selected beat, timing, model, timeline and decoder
tests passed on an iPad Pro simulator running iOS 18.6. A full iPhone 16
simulator run on the preceding build reported 367 passing and four failing
test cases. On rerunning the affected suites with the updated build, one
previously failing paused-preview test passed; two video-preview tests still
failed with AVFoundation error -11800 (underlying OSStatus -12815), and the
project-search UI test failed while waiting for the settings screen on
iOS 18.6. These failures are outside the beat tests, but their cause has not
been established and a completely passing editor suite cannot be claimed.
The same 36 targeted tests passed on an iPhone 17 simulator running iOS 26.3.1.
A full iOS 26.3.1 run was interrupted after ten minutes in the UI tests; its
partial result is not a completed suite and cannot establish editor coverage.
The complete `MotionaryTests` unit target was then run separately on iOS 26.3.1:
352 test cases passed, with no failures. Xcode reported priority-inversion
warnings from `CanvasAndRenderingTests`.
