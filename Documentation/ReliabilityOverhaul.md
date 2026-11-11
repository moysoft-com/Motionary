# Motionary reliability overhaul — 9 November 2026

The reliability changes are on `codex/reliability-overhaul`, based on HEAD `14b82e35` and the incoming working tree. Benchmark comparisons use that incoming state, which already included performance improvements.

**Confirmed causes and corrections**

- Preview graph construction awaited a complete proxy transcode, even when only one frame was needed. It now uses an available proxy or the original asset immediately, while a deduplicated utility-priority task prepares the proxy. Completion does not mutate an installed composition. Proxy resolution now matches the existing 960-pixel preview ceiling, avoiding the previous 720-to-960 enlargement.
- Starting a scrub cancelled an edit's pending composition rebuild and deferred it until release. That allowed the old source mapping to serve the entire gesture. Structural edits now invalidate cached frames and decoder snapshots immediately, rebuild during scrubbing, and resume at the latest gesture position. Release before the rebuild completes is also handled. Replacing a player invalidates outstanding scrub seeks.
- Nearby-frame lookup admitted older edit revisions. It now requires the current revision, and equal-distance matches favor the earlier frame while the exact seek runs. The compositor's last-good-frame fallback also labelled old pixels with a new request time. Fallback reuse now requires matching time, session, revision, and dimensions. If any differ, the compositor cancels the request and AVPlayer retains its current presentation.
- Repeated trim calls with a gesture baseline applied each absolute delta to the already-trimmed item. Both edges now derive their result from the baseline. Animation trims discarded boundary samples, causing values to jump to the next or previous keyframe. They now retain the sampled boundary and the appropriate portion of the interpolation curve, including effect parameters and Bézier easing.
- The preview deliberately advanced a zero playhead by one project frame. That workaround was removed. The last playable position also subtracted a whole frame from arbitrary durations, omitting a partial final frame. It now uses the last valid project frame boundary. Pausing captures the actual player clock before the timeline returns to the model. It does not overwrite the target of a pending seek.
- The timeline had a separate display link publishing playback time into its SwiftUI root, alongside the scroll coordinator's playback clock. The ruler now follows the actual scroll presentation state. The duplicate display link and root scroll-offset binding were removed. Scroll samples update the ruler and overlays directly, and an already-resolved offset no longer republishes its unchanged flag.
- Manual source conversion dropped color information, including SMPTE-C/ICC and transfer characteristics. Native Core Image pixel-buffer ingestion now preserves that information on the GPU. The output also encoded using a named Core Graphics Rec.709 profile while attaching Core Video tags that imply a different transfer curve. Rendering and proxy encoding now share a color space derived from the actual output tags, and output buffers carry that exact color space.
- Native decoder images and time-addressed effect samples used different vertical coordinate conventions. Both now pass through the same conversion into the existing Metal compositor coordinates. This addresses a shared cause of temporal-effect/depth orientation disagreement without branching on input type.
- Depth map loading applied an additional horizontal mirror. Comparing to the model buffer measured 48.28 grayscale levels of mean absolute error. The mirrored reference matched exactly. Loading now preserves the model coordinates. Video and still consistency, deterministic reverse access, and style-only analysis reuse are tested. Every enabled Depth Map instance is prepared, including distinct stabilization settings. New cache versions force existing depth maps and proxies to be regenerated.
- On iOS 18.6, Core Image rejected the depth model's 518-byte grayscale row stride and left the buffer blank. Depth analysis now renders to a four-byte-aligned stride and packs the actual pixels for stabilization and storage.
- Preview preparation now rechecks cancellation and generation after asynchronous depth preparation, before publishing its graph.

The split/ripple model itself preserved source ranges in the investigated workflow. It was retained. Regressions exercise a long source range starting at 900 seconds, a timeline starting at 120 seconds, speeds of 0.5×/1×/2×, ripple deletion, and undo/redo. Encoded-media checks independently compare retained source content through preview and export composition paths.

**Architecture and scope**

The fixes build on the typed timeline model, command history, AVPlayer transport, interval indexing, composition service, Metal effect graph, and shared preview and export path. At the source-ingestion boundary, Core Image performs color conversion and `VideoColorSpace` defines the common output color space for rendering and proxy encoding. The obsolete manual YUV shader and its allocation path were removed.

Two baseline assertions now reflect existing behavior. The registry includes 46 effects, and the track-background radius ceiling is 12 points in the tested configuration. Production fixes address the baseline animation-continuity failures. Trim tests now check retained keyframe IDs and sampled boundary values.

**Verification**

The iPhone 17 simulator passed all 423 unit test cases in Release before the final timeline subscription and iOS 18 depth-stride changes. A full Debug unit rerun passed all 423 after those changes. On the final build, all 13 focused cache and reliability tests and all four performance tests passed. The Debug UI run passed all 25 tests. After the timeline subscription change, 57 preview rebuild tests and eight timeline gesture cases passed. The long-press case failed once during the focused run and passed twice in isolation. All nine gesture cases also passed on the iPhone 16 Pro simulator with iOS 18.6.

The iOS 18.6 rerun passed 74 focused tests across preview rebuilds, proxy generation, source timing and color, and Depth Map. Four rendered-frame checks now compare AVPlayer output because `AVAssetImageGenerator` returned `-12815` for these custom compositions on the older simulator. The iOS 18.6 playback and decoded-scrub fixtures delivered 90 of 90 frames and 28 of 28 targets. The decoded-scrub median and p95 were 51.08 and 56.14 ms.

The baseline Debug run on an Apple M4 with Xcode 27.2 (27B52) and an iPhone 17 Simulator with iOS 26.3.1 completed with 401 passes and four failures. New regressions reproduced cross-revision cache reuse, cumulative trimming, missing animation boundaries, and the frame-zero shift before their corrections. Mismatched encoding and tags changed `[51, 204, 25]` to `[71, 213, 42]` on a color round trip. Matching the color contract preserved the input values. A native decoder comparison changed from `[37, 255, 24]` to `[77, 255, 0]`, matching the native YUV reference for the tested SMPTE-C sample.

| Simulator benchmark, Debug | Incoming baseline | After changes |
| --- | ---: | ---: |
| Dense-project exact seek, median / p95 (30 samples) | 58.76 / 76.41 ms | 49.04 / 57.47 ms |
| Live edit to rendered buffer, median / p95 (30 samples) | 41.04 / 51.59 ms | 37.86 / 45.21 ms |
| 2,400-cut descriptor refresh, median / p95 | 42.62 / 46.00 ms | 33.25 / 34.20 ms |
| Decoded scrub to rendered buffer, median / p95 (24 timed targets) | 46.81 / 69.85 ms | 54.37 / 60.82 ms |
| Scrub targets delivered | 28 / 28 | 28 / 28 |
| Playback frames delivered (three-second fixture) | 90 / 90 | 90 / 90 |
| Playback frame delivery interval, median / p95 | 34.33 / 35.64 ms | 34.57 / 35.75 ms |
| Dense-project H.264 export | 4.51 s | 4.13 s |

The decoded scrub median was slower, while the tail improved. Post-change Debug runs measured 52.49–55.17 ms at the median and 59.51–62.81 ms at p95 for decoded scrub. Dense-project exact seeks varied across runs. Three measured 47.73–49.04 ms at the median and 53.05–57.47 ms at p95. The final isolated run measured 66.99 and 89.41 ms, both slower than the incoming baseline. All observed post-change runs delivered 90 of 90 playback frames and 28 of 28 scrub targets. These simulator measurements cover the time to a rendered buffer. Main actor slider processing at 2,400 cuts stayed near 0.17 ms. Shared and separate decoder tracks produced identical sampled pixels within the updated renderer.

The cold 1080p60 fixture prepared the original-media preview graph in 187 ms, with another 774 ms of proxy work still outstanding. A completed proxy was used on the next topology build. In the same 1080p60 checkerboard fixture at the production bitrate policy, mean absolute channel error in the sampled downscaled proxy frames fell from 2.50 to 0.71 on an 8-bit scale. The disposable proxy grew from 9.23 MB to 14.13 MB. Corrected color encoding intentionally changes old pixel hashes. Direct native color comparisons and an encoded export check verify the new output.

Run `PerformanceBenchmarkTests` and `PreviewProxyTests` serially in the Motionary test scheme to repeat the simulator measurements. `SourceTimingRenderTests` covers source timestamps and color through the player, proxy, and export paths.

Core Video derives image color spaces from buffer attachments. Core Image supports native YUV ingestion and color conversion. [Core Video documentation](https://developer.apple.com/documentation/corevideo/cvimagebuffercreatecolorspacefromattachments(_:)) and [Core Image performance guidance](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html).

**Remaining verification**

The simulator measurements track graph construction and rendered-buffer delivery. Physical-device display latency, peak memory and thermal behavior in long editing sessions, and ruler frame pacing with iOS screen recording active remain unmeasured. The removed duplicate timeline clock and root subscription were observable sources of redundant updates. Their impact under screen recording remains open.

Color checks cover SDR H.264 input, tagged SMPTE-C and Rec.709 conversion, generated video and still depth, and an encoded SDR export. HDR tone mapping, 10-bit footage, and a broader codec and camera matrix remain unverified. The decoded-scrub median regression warrants a device trace with representative long-GOP sources. Xcode also flagged the existing synchronous wait for an asynchronous frame decoder in temporal effects. The cost on long clips with these effects remains unmeasured.
