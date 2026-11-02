# Release engineering review — 2026-11-02

## Status

The consistency and cleanup changes are implemented. Distribution remains gated
by three iOS 18 video-frame generation failures and physical-device validation.
The same three AVFoundation failures also reproduce at the unchanged repository
checkpoint `c26a8ebd`; their underlying cause is not resolved by this pass.

## Scope

Reviewed startup and build configuration, project storage and recovery, media
import, timeline interactions, editor state, live preview, effect rendering,
proxy/original media coordinates, encoded export, preferences and the Firebase
suggestions integration. This is a release-candidate engineering pass, not an
App Store submission or a claim of physical-device validation.

## Changes

- Scrub at playback preview resolution and vector supersampling, with no
  extra effect downscaling, text-time quantization or dropped temporal samples.
- Use project-pixel coordinates for media effects, independent of proxy or
  export size, matching generated layers and adjustment layers.
- Compare interaction and export output for every registered effect. Keep
  geometry/alpha and encoded multi-resolution export regression coverage.
  The representative image comparison permits less than 0.00001 normalized mean channel error; this is
  not bit-identical output or coverage of every parameter combination.
- Preserve authored alpha and unpremultiplied color after optical blur; maintain foreground cutouts.
- Add grain in perceptual color space and integrate scanline pixel coverage so
  pattern brightness remains stable across output resolutions.
- Snapshot scratch-pool diagnostics under its lock, avoiding a racing counter read.
- Allow a one-frame tolerance while dragging; retain exact seeking on release.
  Sub-frame presentation semantics remain shared across supported systems.
- Use a small 64px all-intra timing surface; keep cache-owned timing assets
  separate from imported-media fixtures.
- Keep cold-launch Home Screen actions queued until the root presenter is
  attached and active; log action receipt and presentation for diagnosis.
  Present each New Project request once, after its home host becomes visible.
  This fixes the missing media picker when launched through the shortcut.
- Release player layers and sample buffers when removed from the view hierarchy.
  Exercise native presentation, clearing, backpressure, detach and reattachment.
- Cache complete GPU preview frames in a memory-bounded LRU, isolated by session,
  visual revision and timeline time. Clear on memory pressure, graph rebuilds
  and player replacement. Reject stale completions after edits. Cached scrubs
  present directly without another decoder seek or effect render.
- Render generated/image-only intervals at new times directly through Metal;
  retain decoder time checks for video. Avoid constructing motion scenes when
  no adjustment layer needs Motion Blur. The final seek waits for presentation,
  without a second quality-restoration rebuild.
- Keep effect thumbnails cached and prepared before presenting the library grid.
  Retain complete Echo history and Motion Blur sample counts during interaction;
  missing local media does not start decoder work. Historical cache hits bypass
  the decoder lock.
- Motion Blur integrates the current object image over position, rotation and
  scale, individually or in combinations. Adjustment layers integrate underlying
  object placements. Source-video motion is not sampled. Remove Reverse Time
  from the catalog and ignore persisted legacy effect markers.
- Wait for actual layout-animation settling in the timeline regression test.
  Keep fixture media files independent of the private timing asset, matching
  real project imports, and exercise existing source frames on iOS 18.
- Query adaptive iPad navigation by its controls rather than assuming a bottom
  tab-bar hierarchy. Target actual timeline-item geometry in gesture tests and
  assert the same dominant-axis lock covered by the domain tests.
- Break writer-input callback ownership cycles so completed exports can release
  their reader/compositor graphs. Existing encoded-export/cancellation tests cover
  the lifetime of the suspended operation that owns the pipeline.
- Rotate project backups atomically and retain a valid backup when the current
  primary file is corrupt. Add recovery coverage for this sequence.
- Add opaque alternate-icon PNGs for all supported systems, including the
  required iPad sizes; normalize the fallback system name in the picker.
  Reconcile the operating system icon state after confirmation errors. The
  Appearance section and its controls have been removed from Settings as requested;
  icon selection remains accessible through the existing Home Screen action.
- Add the app privacy manifest for app-local preferences, local/user-selected
  file metadata, elapsed-time measurement, pseudonymous suggestions identity
  and submitted content. Firebase SDK manifests remain separate.
- Remove tracked Finder/Xcode session metadata while preserving local copies.
  Correct the README's dependency and deployment-target descriptions.

## Repeatable verification

Run `scripts/verify-release.sh 'platform=iOS Simulator,name=iPhone 17'` with an
installed simulator. The script runs the entire scheme's unit/UI tests and an
unsigned device Release build, preserving the result bundle in ignored build
storage. Test failures stop the check; there are no upload or deployment steps.

## Verification record

| Check | Result |
| --- | --- |
| iPad, iOS 26.3.1, full-quality unit action | 324 functions passed; 344 parameter-expanded runs, no skips |
| Full-quality focused regressions and UI action | 59 functions passed, including effect gestures and removed Settings controls |
| Final cache bounds and invalidation tests | Four passed, including the entry-count cap for tiny canvases |
| iPhone, iOS 18.6, full-quality effects and cache action | 12 functions passed; 14 parameter-expanded runs, no skips |
| Earlier iPad UI action excluding Home Screen shortcuts | 17 functions passed; one existing-project search test skipped because the library was empty |
| iPad project/search navigation after the home-host fix | Both tests passed, including opening an existing project |
| iPhone, iOS 18.6, Home Screen shortcuts | All four passed: cold/warm icon picker, Settings, New Project |
| Earlier iPhone, iOS 18.6, full unit action | 317 functions passed; three failed as listed below, no skips |
| Unsigned generic-device Release build | Passed |
| App and bundled privacy property-list validation | Passed |
| Whitespace/diff checks | Passed |

Results and build logs are retained locally in
`build/release-verification/2026-11-02/` (ignored by Git). Xcode emits priority
inversion diagnostics around synchronous AVFoundation work in rendering fixtures;
the successful action is not a physical-device frame-rate measurement.

The full-quality scrubbing follow-up is recorded in the `full-quality-scrubbing`
subdirectory. Its regression tests verify immediate cached presentation with no
seek, coalesced direct GPU requests, cache eviction and stale-completion rejection.
The latency fixture uses Wave Warp, Blur and Soft Glow at 960×540 and records GPU
refresh latency and cached full-quality frame lookup separately. Simulator values
do not establish zero latency or a sustained frame rate on a physical device.

The final visible-object fixture (`VisibleEffectsLatency.xcresult`) passed all
seven preview/cache test functions. Across 60 measured GPU refreshes after warm-up,
median latency was 4.70 ms, p95 7.01 ms and maximum 7.29 ms. Cache lookup averaged
0.0037 ms over 1,000 reads including assertions. The object remains on canvas
and a pixel check verifies visible content, avoiding offscreen-culling shortcuts.
Use `visible-effects-render-latency.txt` for these measurements; the earlier
latency attachment used an offscreen position sequence and is superseded.

The iOS 18 compatibility failures are:

1. `PausedLivePreviewTests.decodedSnapshotRendersLiveEditsWithoutAnotherSeek`
   with source video, while requesting a canonical composition frame.
2. `PreviewProxyTests.longGOPSourceUsesAllIntraProxiesOnlyForPreviewAndMeasuresActualFrames`
   while generating the original composition image.
3. `PreviewRebuildTests.videoClockAndDependenciesCoverLayerEndsGapsAndAudioTail`
   while generating composition frames across source boundaries.

All report AVFoundation `-11800` with underlying OSStatus `-12815`. They also
fail in a separate, unchanged checkout of `c26a8ebd`. That baseline additionally
fails its existing seek-tolerance assertion, which is corrected by this update.
Playback/export tests and generated-only frame tests do not establish that the
unresolved source-video image-generation cases are safe to ship on iOS 18.

Some Simulator runs also fail the alternate-icon confirmation service with
“couldn't load upcall bundle principal class” after applying the icon. The picker
reconciles the actual icon. The UI test skips restoration only for this specific
diagnosed runtime failure, after checking the applied selection; the recorded
iPad UI action completed the icon test without that skip.

## Required before distribution

- Resolve and rerun the three iOS 18 compatibility cases. Retain the current
  deployment target until a deliberate support decision is made.

- Validate on physical iPhone and iPad: sustained scrubbing with layered effects,
  4K/60 export, thermal/memory pressure, cancellation and interrupted saves.
- Validate the supported iOS 18 and current iOS versions on devices.
- Review visual output and alternate-icon confirmation/restoration on devices.
- Produce a signed archive and run Xcode/App Store Connect validation, including
  the aggregated SDK privacy report and production App Attest behavior.
- Confirm Firebase production rules, indexes and App Check enforcement, and
  App Store Connect privacy answers against the actual deployed service.
- Follow the existing [operational compliance checks](AppStorePrivacyAndCompliance.md).

Required-reason declarations were checked against [Apple's API categories and
approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
