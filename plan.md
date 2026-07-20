# Motionary production-readiness plan

> Audit baseline: current working tree on 2026-07-20. The repository contains extensive uncommitted editor and rendering work, so this plan treats the working tree, not `main`, as the product baseline.

## Goal

Ship Motionary as a stable, visually sharp, trustworthy iPhone and iPad video editor. Preview, interaction, persistence, and final export must behave consistently across supported devices and media types.

## Release gates

Motionary is not ready for customer release until all of these are true:

- [ ] A clean checkout builds and tests in CI with the documented Xcode and iOS SDK.
- [ ] App icon, privacy manifest, signing, entitlements, versioning, and App Store metadata are complete.
- [ ] Preview and export match for text, transforms, masks, effects, timing, color, and crop within defined tolerances.
- [ ] Text and source media remain sharp at normal zoom and after transforms.
- [ ] Project creation, editing, autosave, recovery, export, cancellation, backgrounding, and relaunch pass end-to-end tests.
- [ ] No known P0 or P1 defects remain. P2 defects have an explicit ship/defer decision.
- [ ] Accessibility, localization readiness, privacy declarations, moderation operations, and support links are verified.
- [ ] Performance budgets pass on the oldest supported device and with representative stress projects.

## Priority and effort

| Priority | Meaning |
|---|---|
| P0 | Blocks builds, data integrity, export correctness, privacy, or App Store submission |
| P1 | Major customer-visible correctness, rendering, reliability, or accessibility issue |
| P2 | Important polish, maintainability, observability, and workflow improvement |
| P3 | Post-launch enhancement |

Effort: **S** under one day, **M** 1–3 days, **L** 3–7 days, **XL** more than one week. Estimates are directional and should be revised after reproductions and profiling.

---

# Phase 0: Stabilize the baseline

## P0.1 Make the project buildable on development machines and CI

**Evidence**

- `Motionary.xcodeproj/project.pbxproj:360,418,507,526` sets `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
- The local test attempt failed because the required iOS 26.2 platform was not installed and Xcode reported no supported simulator destinations.
- `.github/workflows/swift.yml:19-22` runs `swift build` and `swift test`, but this repository is an Xcode app and has no `Package.swift`.
- `README.md:7-9` requires Xcode 17 and iOS 26, while CI uses unpinned `macos-latest`.

**Work**

- [ ] Decide the real minimum supported iOS version based on product needs and API usage.
- [ ] Pin a known Xcode version in CI and select an installed simulator runtime.
- [ ] Replace `swift build/test` with `xcodebuild build` and `xcodebuild test` for the `Motionary` scheme.
- [ ] Add dependency caching and upload `.xcresult` on failure.
- [ ] Add a Release configuration build and an archive-without-signing validation.
- [ ] Make README requirements and commands exactly match CI.

**Acceptance criteria**

- A clean clone passes Debug build, unit tests, UI smoke tests, and Release build without manual setup beyond documented Firebase configuration.
- CI fails on compiler warnings introduced by app code after an initial warning cleanup.
- Test results and failure attachments are downloadable from CI.

**Effort:** M

## P0.2 Freeze, checkpoint, and reduce working-tree risk

**Evidence**

- The audit found dozens of modified files plus untracked media-analysis, background-removal, effect-rendering, tests, and design-system files.
- User-specific files and build noise are tracked, including `xcuserdata`, `.xcuserstate`, `.DS_Store`, and `firebase-debug.log`.

**Work**

- [ ] Create a checkpoint branch and commit the current feature baseline in coherent changes.
- [ ] Remove user-specific Xcode state, `.DS_Store`, and debug logs from version control.
- [ ] Strengthen `.gitignore` for Xcode user data, DerivedData, result bundles, logs, generated exports, and temporary analysis artifacts.
- [ ] Review whether `GoogleService-Info.plist` should remain tracked. If tracked, ensure it is the intended public client configuration and restrict Firebase resources with App Check and security rules.
- [ ] Tag the first reproducible stabilization baseline.

**Acceptance criteria**

- `git status` is clean after build and test.
- A second developer can clone and reproduce the same test result.
- No personal workspace state or runtime logs are tracked.

**Effort:** S

## P0.3 Add the missing application icon and submission assets

**Evidence**

- Build settings reference `ASSETCATALOG_COMPILER_APPICON_NAME = Motionary` at `project.pbxproj:432,467`.
- `Motionary/Assets.xcassets` contains no `Motionary.appiconset` in the audited tree.

**Work**

- [ ] Add a complete AppIcon set, including current iOS alternate appearances if desired.
- [ ] Validate icon safe areas, transparency rules, small-size legibility, and asset compiler warnings.
- [ ] Create App Store screenshots for required iPhone and iPad sizes, app preview decisions, subtitle, keywords, description, support URL, marketing URL, and review notes.

**Acceptance criteria**

- Asset catalog compilation has no missing app-icon warning.
- Archive validation and App Store Connect upload validation pass.

**Effort:** M

---

# Phase 1: Rendering correctness and sharpness

This phase is the highest product priority. Do not tune random SwiftUI modifiers until a reproducible render-quality harness exists.

## P0.4 Build a deterministic preview/export parity harness

**Evidence**

- Rendering spans `CompositionRenderService`, `MotionaryVideoCompositor`, `TextLayerRenderer`, SwiftUI preview overlays, thumbnail loaders, and `VideoExportService`.
- Existing `CanvasAndRenderingTests.swift` covers geometry and selected composition behavior, but there are no broad pixel, snapshot, color-space, or preview-versus-export comparisons.
- UI tests only verify launch and launch performance.

**Work**

- [ ] Add checked-in synthetic fixtures: 1 px grids, checkerboards, diagonal lines, small text, transparent PNG, Display-P3 image, portrait/landscape/rotated video, variable-frame-rate video, HEVC, HDR input, and audio/video with known timing.
- [ ] Add reference projects covering every transform, blend mode, effect, mask, text style, text animation, speed map, and background-removal state.
- [ ] Render selected timestamps through preview-quality and export-quality paths.
- [ ] Compare dimensions, alpha, crop, average/maximum pixel error, edge sharpness, and frame timing.
- [ ] Store human-review contact sheets as CI artifacts rather than relying only on numeric tolerances.
- [ ] Add regression fixtures for every rendering bug found during stabilization.

**Acceptance criteria**

- Preview and export geometry match within 0.5 output pixel for position and bounds.
- Rotation differs by less than 0.1 degree and opacity/effect values by less than 1%.
- Static reference frames stay under an agreed perceptual difference threshold.
- Text line breaks and glyph reveal boundaries are identical between preview and export.

**Effort:** L

## P0.5 Fix stale previews when blend intensity changes

**Evidence**

- `CompositionRenderService.RenderClipDescriptor` and `MotionaryVideoCompositor.applyBlendMode` consume `blendIntensity`.
- `EditorProject.renderVisualSignature` / `RenderItemVisual` in `EditorCommand.swift` do not include blend intensity.
- `EditorViewModel+MediaAnalysis.setSelectedBlendIntensity` can therefore change a rendered value without producing `.previewFrame` invalidation.

**Work**

- [ ] Add blend intensity to the visual render signature for media, shape, and text items.
- [ ] Audit every compositor-consumed property against render invalidation signatures.
- [ ] Add a table-driven test proving each rendered property invalidates the minimum correct render layer.

**Acceptance criteria**

- Changing blend intensity updates preview without requiring a second unrelated edit.
- Preview and export pixels match after the change within the standard parity tolerance.
- A test fails whenever a newly added compositor property is omitted from invalidation signatures.

**Effort:** S

## P1.1 Define one coordinate, scale, and pixel-snapping contract

**Evidence**

- `TextLayerRenderer` accepts a logical `renderScale`, then explicitly uses `UIGraphicsImageRendererFormat.scale = 1` at `TextLayerRenderer.swift:83-85`.
- Preview overlay geometry calls `TextLayerRenderer.geometry(... renderScale: 1)` at `PreviewTransformCanvas.swift:1031-1035` and `1098-1102`.
- `CompositionRenderService.preparePreview` derives compositor scale from preview width divided by project width at `CompositionRenderService.swift:340-346`.
- Several preview/control paths pass literal `renderScale: 1`.
- Rendering coordinates mix project pixels, preview points, source pixels, normalized transform values, and output pixels.

**Work**

- [ ] Document named coordinate spaces: source pixels, oriented source pixels, project pixels, preview points, preview backing pixels, and export pixels.
- [ ] Introduce a small `RenderGeometryContext` carrying project size, target size, display scale, render scale, and conversion helpers.
- [ ] Replace unexplained literal scale values with context-derived values.
- [ ] Snap translation and raster bounds to target pixel centers only at the final raster/composite boundary.
- [ ] Round raster canvas bounds outward so glyph shadows, strokes, and rotated edges are never clipped.
- [ ] Keep geometry calculations in floating point until final buffer allocation.

**Acceptance criteria**

- A 1 px test grid has crisp, stable lines at 100% scale.
- A text layer does not change apparent sharpness when selected, dragged, released, paused, or exported.
- Repeated transform edits do not accumulate position or size drift.

**Effort:** L

## P1.2 Fix text rasterization quality and text-preview consistency

**Evidence**

- `TextLayerRenderer.swift:83-126` rasterizes text into a `UIImage` at format scale 1 and converts it to `CIImage`.
- Text raster cache keys include full floating-point render dimensions and scale, which may create churn during interactive resizing.
- `PreviewTransformCanvas.swift:1255+` creates a separate live preview image during interaction, while the player uses the compositor.
- The renderer claims exact preview/export pixels, but this claim is not currently protected by pixel tests.

**Work**

- [ ] Rasterize at actual target backing resolution, not an ambiguous mix of logical points and scale-1 bitmap pixels.
- [ ] Audit font baseline, fractional origins, line-fragment rounding, stroke width, shadow extents, background padding, emoji, combining marks, RTL scripts, and fallback fonts.
- [ ] Quantize cache keys to meaningful pixel dimensions and style values to avoid near-duplicate entries.
- [ ] Preserve color space and premultiplication when converting UIKit output into Core Image.
- [ ] Make live-transform text use the same raster provider and geometry context as compositor preview.
- [ ] Add text fixtures at 12–200 pt, thin/regular/bold weights, multiline alignment, stroke, shadow, background, typewriter reveal, and animated scale/rotation.

**Acceptance criteria**

- No blurry text at 1x, 2x, or 3x display scale in supported preview sizes.
- Text does not visibly jump between editing, playback, and export.
- Baseline, wrapping, stroke, background, and shadow match the reference render at all supported output sizes.
- Raster cache stays within its memory budget during 60 seconds of text animation and resizing.

**Effort:** L

## P1.3 Fix source-media sampling, transforms, and crop behavior

**Evidence**

- Media travels through source transforms, Core Image transforms, preview-quality composition sizes, thumbnail/live-transform images, and final export.
- `PreviewTransformCanvas.previewBaseSize` fits source media independently at `PreviewTransformCanvas.swift:1018-1023`.
- `MotionaryVideoCompositor` has separate orientation, transform, crop, effect, mask, and composite stages.
- Timeline and live-transform thumbnail paths create additional `CIContext` and `UIGraphicsImageRenderer` instances.

**Work**

- [ ] Centralize orientation normalization and aspect-fit/fill math in tested geometry helpers.
- [ ] Define sampling policy for downscale, upscale, rotation, and fractional translation. Set Core Image sampler behavior deliberately.
- [ ] Prevent low-resolution timeline thumbnails or live-transform proxies from surviving after gesture commit.
- [ ] Verify that still images retain full source resolution and are not pre-downsampled below required export size during import.
- [ ] Remove or redesign the current `MediaImportService` 2560 px still-image cap and avoid forced opaque JPEG-backed conversion for transparent or high-detail sources.
- [ ] Preserve original stills or generate a lossless/high-quality mezzanine based on required crop and export dimensions.
- [ ] Audit transparent edge handling to prevent dark/colored halos after transforms and masks.
- [ ] Validate portrait video transform matrices and odd-dimension sources.

**Acceptance criteria**

- Checkerboard and diagonal fixtures remain sharp without shimmer during motion.
- Preview and export use the same crop and source orientation.
- Releasing a gesture replaces proxy media with the full preview within one rendered frame.
- Transparent PNG edges have no visible fringe on black, white, and saturated backgrounds.

**Effort:** L

## P1.4 Establish an explicit color-management and HDR policy

**Evidence**

- `VideoExportService.swift:175-179` always tags output as Rec.709.
- The compositor creates `CIContext` without an explicit working/output color-space policy.
- Source pixel buffers accept full-range and video-range YUV plus BGRA.
- No tests cover Display-P3, HDR, range conversion, or alpha/color-space behavior.

**Work**

- [ ] Decide v1 policy: SDR Rec.709 only with deterministic tone mapping, or end-to-end HDR support.
- [ ] Configure Core Image working and output color spaces explicitly.
- [ ] Normalize full-range/video-range input correctly.
- [ ] Preserve embedded image profiles on import and convert exactly once.
- [ ] If HDR is deferred, detect HDR media and communicate that Motionary exports SDR.

**Acceptance criteria**

- Color-bar fixtures and P3 imagery produce measured, documented output values.
- Preview and export do not show obvious gamma or saturation shifts.
- HDR input never exports washed out, clipped, or unpredictably dark video.

**Effort:** M–L

## P1.5 Make masks, effects, and background removal deterministic

**Evidence**

- `CompositionRenderService.preparePreview` uses `.omitUnavailable` for background removal, while final composition uses `.required` at `CompositionRenderService.swift:441-446`.
- During compositor rendering, a configured background-removal clip without a mask can become a transparent image.
- Effects and analysis implementations are newly added and currently untracked.

**Work**

- [ ] Define visible states for analysis queued, processing, ready, failed, stale, and cancelled.
- [ ] Never silently replace unavailable output with different preview semantics. Show an explicit placeholder or non-destructive original.
- [ ] Version analysis artifacts by source fingerprint and algorithm version.
- [ ] Add effect/mask edge tests at preview and export resolution.
- [ ] Add cancellation, app-backgrounding, low-disk, and source-replacement tests.

**Acceptance criteria**

- Preview clearly communicates when export output would differ.
- Missing/stale masks cannot make customer media unexpectedly disappear.
- Replacing or editing source media invalidates only affected artifacts.

**Effort:** M–L

## P1.6 Profile and budget the renderer

**Evidence**

- Large per-frame path in `MotionaryVideoCompositor.swift` combines multiple clips, effects, masks, text rasterization, and caches.
- Several independent caches each allow tens of MB.
- UI files create additional image renderers and Core Image contexts.
- Interactive rebuild scheduling targets roughly 60 ms, while composition rebuilding can be expensive.

**Work**

- [ ] Add `os_signpost` intervals around preview rebuild, frame composition, text rasterization, thumbnail load, analysis, import, save, and export.
- [ ] Reuse Core Image/Metal resources rather than creating contexts in view-adjacent paths.
- [ ] Define a central memory budget and respond to memory warnings by evicting derived data.
- [ ] Profile CPU, GPU, allocations, hangs, and thermal behavior with 1080p and 4K stress projects.
- [ ] Separate topology rebuilds from parameter-only frame updates wherever AVFoundation permits.
- [ ] Cap expensive concurrent import and analysis work based on device capacity.

**Acceptance criteria**

- 1080p30 preview sustains at least 28 rendered fps on the oldest supported device for the reference project.
- Scrub-to-visible-frame p95 is under 100 ms for a medium project.
- Interactive transform response p95 is under 50 ms, with full-quality settle under 250 ms.
- Memory remains under a documented device-specific budget and no jetsam occurs in a 10-minute stress session.
- Export progress is monotonic and cancellation releases large buffers promptly.

**Effort:** L

---

# Phase 2: Reliability, data integrity, and concurrency

## P0.6 Make save failures visible and projects recoverable

**Evidence**

- `ProjectRepository` has a thoughtful primary/recovery/backup design.
- Autosave paths still swallow failures, for example `EditorViewModel+Playback.swift:27-28` uses `try? await repository.save(...)`.
- `ProjectRepository.load` attempts `try? restorePrimary` at `ProjectRepository.swift:66-68`, so failed repair is invisible.

**Work**

- [ ] Route every save through one serialized save coordinator with generation/version tracking.
- [ ] Surface durable “Saving”, “Saved”, and “Couldn’t save” states without interrupting every edit.
- [ ] Retry transient failures with bounded backoff and preserve the recovery file.
- [ ] Detect low disk and report actionable errors.
- [ ] Add explicit recovery UI when loading backup/recovery content.
- [ ] Flush pending saves on scene background and editor dismissal using an appropriate background task.

**Acceptance criteria**

- Killing the app at every point in the save sequence leaves either the previous or new valid project, never an unreadable project.
- Save failure is visible and retryable.
- Rapid edits followed by immediate backgrounding restore the newest acknowledged edit.

**Effort:** M–L

## P1.7 Audit task ownership, cancellation, and stale-result protection

**Evidence**

- The app uses many unstructured `Task {}` calls, detached media-analysis tasks, sleeps for debouncing, continuations, dispatch queues, and `@unchecked Sendable` render descriptors.
- Preview generation has generation checks, which is a good pattern, but it is not consistently applied to import, thumbnails, analysis, save, and export.

**Work**

- [ ] Inventory all long-lived tasks and assign an owner and cancellation event.
- [ ] Apply generation/token checks before committing asynchronous results.
- [ ] Tear down NotificationCenter observers, AV/player observers, Firestore listeners, and other callbacks deterministically when their owner closes or deinitializes.
- [ ] Prevent one thumbnail consumer cancelling a shared in-flight request needed by another consumer.
- [ ] Ensure every checked continuation resumes exactly once on success, failure, and cancellation.
- [ ] Replace `@unchecked Sendable` with immutable Sendable value types where possible and document remaining invariants.
- [ ] Isolate UI state to `@MainActor` and media/file state to actors or serial executors.
- [ ] Enable strict concurrency checking incrementally, then make it a CI gate.

**Acceptance criteria**

- Closing a project cancels its preview, thumbnails, analysis, import, and export tasks.
- Results from an old project, source, or selection never overwrite current state.
- Thread Sanitizer and strict-concurrency builds show no app-code violations in covered flows.

**Effort:** L

## P1.8 Make import and file lifecycle transactional

**Evidence**

- `HomeView.createProject` creates the project before all selected media imports finish.
- Import uses batches of concurrent work and temporary files.
- Media analysis and background-removal artifacts add more project-local files.

**Work**

- [ ] Stage new-project import in a temporary project folder.
- [ ] Commit the project to the dashboard only after required metadata and files are durable.
- [ ] On partial failure, offer retry, continue with successful items, or cancel and clean up.
- [ ] Add orphan/temp cleanup with conservative age checks.
- [ ] Add bounded thumbnail disk-cache eviction by size and age, with cache versioning.
- [ ] Garbage-collect media and analysis artifacts no longer referenced by project content.
- [ ] Store media/artifact manifest checksums and validate them during load.

**Acceptance criteria**

- Cancelling or failing a multi-item import creates no broken dashboard project or leaked files.
- Relaunch during import recovers or cleans the staged transaction safely.
- Missing media is identified by name with relink/remove options.

**Effort:** M–L

## P2.1 Split maintainability hotspots after behavior is protected

**Evidence**

- The project contains 34,760 Swift lines.
- Largest files include `EditorWorkspaces.swift` (2,129), `PreviewTransformCanvas.swift` (1,712), `CompositionRenderService.swift` (1,251), and `MotionaryVideoCompositor.swift` (749).

**Work**

- [ ] First add characterization tests. Do not refactor renderer behavior without them.
- [ ] Split preview geometry, gesture state machine, overlay drawing, and live-proxy loading.
- [ ] Split composition assembly, source insertion, audio mix, and descriptor compilation.
- [ ] Split compositor stages into pure/testable processors.
- [ ] Add protocols only at real substitution boundaries, not as blanket abstraction.

**Acceptance criteria**

- Core render math can be unit-tested without SwiftUI or an active player.
- Major files have a single clear reason to change.
- Refactor produces no reference-frame difference outside approved tolerances.

**Effort:** L

---

# Phase 3: Customer-facing UX and polish

## P1.9 Design complete loading, empty, error, cancellation, and recovery states

**Evidence**

- Home import currently shows a generic blocking “Importing” overlay.
- Many lower-level operations use `try?`, so failures may appear as missing thumbnails, absent waveforms, stale previews, or no visible action.
- Export and analysis can be long-running but need consistent progress and cancellation behavior.

**Work**

- [ ] Create a shared operation-state model and visual pattern for import, save, analysis, preview, and export.
- [ ] Show item-level import progress and partial failures.
- [ ] Add export stage, progress, estimated remaining time where reliable, cancel, and retry.
- [ ] Add missing-media and corrupt-project recovery flows.
- [ ] Use customer-language errors with a technical detail disclosure and copy button for support.

**Acceptance criteria**

- Every asynchronous customer action ends in success, actionable failure, or explicit cancellation.
- No indefinite spinner survives task completion or cancellation.
- Errors identify what was affected and whether work was preserved.

**Effort:** M

## P1.10 Finish accessibility and Dynamic Type support

**Evidence**

- The editor has meaningful accessibility work already, including labels on many controls and transform handles.
- Most strings are hard-coded English.
- Dense editor controls use one-line labels and minimum scale factors, and timeline gestures require alternative accessible actions.

**Work**

- [ ] Run VoiceOver audits for dashboard, editor, timeline, workspaces, export, settings, and suggestions.
- [ ] Add accessibility identifiers for end-to-end automation.
- [ ] Add adjustable actions for timeline positioning, trimming, keyframes, transforms, and sliders.
- [ ] Test Dynamic Type through accessibility sizes, Bold Text, Button Shapes, Increase Contrast, Reduce Motion, Reduce Transparency, and Differentiate Without Color.
- [ ] Ensure 44×44 pt minimum hit targets and visible keyboard/focus navigation on iPad.
- [ ] Respect Reduce Motion in text/editor UI animations without changing exported creative motion.

**Acceptance criteria**

- Core create-edit-export flow is completable with VoiceOver without pixel hunting.
- No customer text clips or overlaps at supported Dynamic Type sizes.
- All icon-only buttons have accurate label, value, hint, and state.

**Effort:** L

## P1.11 Prepare localization and international text

**Evidence**

- Customer-facing strings are mostly inline English literals.
- Text rendering must support user-created multilingual text even if the app initially ships in one language.

**Work**

- [ ] Move UI strings to a String Catalog with translator comments and pluralization.
- [ ] Use locale-aware numeric, duration, file-size, bitrate, frame-rate, and date formatting.
- [ ] Test RTL interface mirroring separately from project-canvas coordinates.
- [ ] Test CJK wrapping, Arabic shaping, emoji, combining marks, and font fallback in text layers.
- [ ] Decide launch languages and add pseudolocalization CI/screenshot checks.

**Acceptance criteria**

- Pseudolocalized UI has no truncation in core flows.
- User-created international text renders consistently in preview and export.

**Effort:** M–L

## P2.2 Standardize editor interaction and visual hierarchy

**Work**

- [ ] Define selected, pressed, disabled, destructive, loading, and focused states in the design system.
- [ ] Standardize spacing, corner radii, material/glass usage, typography, icon sizes, and haptics.
- [ ] Make destructive actions confirm scope and support undo where feasible.
- [ ] Replace immediate project deletion with confirmation plus a recoverable Recently Deleted/undo window, and test deletion while a project task is active.
- [ ] Add onboarding or contextual tips for timeline, layers, transforms, keyframes, and export.
- [ ] Add reset-to-default affordances and precise numeric entry for all critical values.
- [ ] Preserve workspace, zoom, scroll, selection, and playhead context across temporary navigation.

**Acceptance criteria**

- A design-token audit finds no unexplained one-off styling in core screens.
- All editable parameters have a discoverable reset and accessible value.
- Common actions give immediate visual feedback and are undoable where expected.

**Effort:** L

## P2.3 Improve iPad and device adaptation

**Evidence**

- The target supports iPhone and iPad (`TARGETED_DEVICE_FAMILY = "1,2"`).
- iPhone is portrait-only, while iPad supports all orientations.

**Work**

- [ ] Define compact and regular editor layouts rather than relying only on adaptive grids.
- [ ] Test split view, Stage Manager sizes, rotation, safe areas, keyboard, pointer, and trackpad.
- [ ] Decide whether iPhone landscape editing should be supported or explicitly deferred.
- [ ] Preserve edit state across size-class and orientation changes.

**Acceptance criteria**

- No clipped editor controls or lost canvas/timeline state at supported iPad window sizes.
- Pointer hover, keyboard shortcuts, and focus order cover primary iPad workflows.

**Effort:** M–L

---

# Phase 4: Privacy, security, observability, and release operations

## P0.7 Add and validate the privacy manifest

**Evidence**

- No app-owned `PrivacyInfo.xcprivacy` was found.
- The app uses `UserDefaults`, file metadata/storage APIs, Photos saving, Firebase Authentication, Firestore, and App Check.
- `Documentation/AppStorePrivacyAndCompliance.md` already lists manual privacy and moderation obligations.

**Work**

- [ ] Add `PrivacyInfo.xcprivacy` with accurate collected-data and required-reason API declarations.
- [ ] Generate and inspect the archive privacy report, including Firebase SDK manifests.
- [ ] Align App Store privacy answers with actual data flow and retention.
- [ ] Verify Photos add-only usage text and denial/recovery behavior.
- [ ] Document account/UID lifecycle, deletion, suggestion deletion, report retention, and moderation access.

**Acceptance criteria**

- Archive validation has no privacy-manifest warnings.
- App Store Connect declarations match the archive privacy report and privacy policy.
- Data deletion and moderation procedures are tested and assigned to an owner.

**Effort:** M

## P0.8 Put user-generated suggestions through server-enforced moderation

**Evidence**

- `SuggestionsViewModel` writes new suggestions with `status: "approved"` directly from the client.
- `SuggestionContentPolicy` provides only a small client-side blocked-term/link/repetition filter.
- Firestore rules validate field shape and lengths but cannot provide semantic moderation.

**Work**

- [ ] Write all new submissions as `pending` through a trusted backend or tightly constrained Firestore rule path.
- [ ] Prevent clients from setting approval/moderation fields or changing ownership.
- [ ] Add server-side rate limiting, abuse detection, moderation queue, audit trail, and takedown tooling.
- [ ] Hide or clearly label pending/rejected content and provide submitter status/appeal behavior.
- [ ] Add emulator tests for attempts to self-approve, edit another user’s content, spam, and bypass length/status rules.

**Acceptance criteria**

- No untrusted client can publish approved content or change moderation state.
- New public content appears only after the documented moderation path succeeds.
- Moderator actions are attributable and reversible where legally appropriate.

**Effort:** L plus ongoing moderation operations

## P0.9 Verify Firebase and user-generated-content safety before launch

**Evidence**

- The app initializes Firebase at launch and uses anonymous/pseudonymous authentication, Firestore, and App Check.
- Repository documentation requires App Attest enforcement, Firestore rules/index deployment, moderation, notices, retention, and legal review.

**Work**

- [ ] Test Firestore rules with the Firebase emulator for read/write/report/delete abuse cases.
- [ ] Verify Release builds use App Attest and Debug tokens cannot authorize production traffic after launch.
- [ ] Add rate limits and abuse controls appropriate to the suggestions feature.
- [ ] Execute the moderation and illegal-content-notice runbook end to end.
- [ ] Complete German/EU legal review listed in `Documentation/AppStorePrivacyAndCompliance.md`.

**Acceptance criteria**

- Automated security-rule tests reject unauthorized mutations and cross-user ownership changes.
- A production-like TestFlight build works with App Check enforcement.
- Report, moderation, deletion, appeal, and legal-notice drills are documented with responsible owners.

**Effort:** M plus external legal/operations work

## P1.12 Add privacy-conscious diagnostics and crash reporting

**Evidence**

- No app-owned crash reporting, structured logging, or performance telemetry was identified.
- Rendering and export failures need device/media context to be supportable after launch.

**Work**

- [ ] Add unified logging categories with privacy redaction for app lifecycle, persistence, import, preview, renderer, analysis, and export.
- [ ] Adopt crash reporting only after updating consent/privacy declarations as required.
- [ ] Record non-sensitive render metadata: app/build version, device class, OS, project dimensions, codec/container, duration bucket, stage, and error code. Never upload user media, text content, filenames, or project titles by default.
- [ ] Add an in-app “Export diagnostics” package with logs and sanitized project structure, controlled by the user.
- [ ] Define alert thresholds for crash-free sessions, export failure, save failure, and startup hangs.

**Acceptance criteria**

- A simulated crash and export failure appear with symbolicated, actionable context.
- Diagnostics contain no user-created content unless the user explicitly opts to attach it.

**Effort:** M

## P1.13 Complete release configuration and App Store QA

**Work**

- [ ] Separate Debug and Release service configuration and verify entitlements.
- [ ] Set automatic monotonically increasing build numbers in CI.
- [ ] Validate Release optimization, debug symbol upload, dead-code stripping, and no debug App Check provider.
- [ ] Audit third-party SDK licenses and update README’s inaccurate “no third-party runtime dependencies” statement.
- [ ] Add export-compliance answers and encryption review.
- [ ] Run App Store static validation, TestFlight internal testing, external beta, and phased-release planning.
- [ ] Prepare support contact, FAQ, known limitations, incident response, rollback/hotfix process, and release notes.

**Acceptance criteria**

- TestFlight build installs and passes the full release checklist on supported devices.
- No debug endpoints, tokens, logging, or development entitlements are present in Release.
- Support and rollback procedures have named owners.

**Effort:** M

---

# Phase 5: Test matrix and measurable quality gates

## Automated test pyramid

### Unit tests

- Geometry and coordinate conversion for every orientation/aspect ratio.
- Text layout, font fallback, animation evaluation, and pixel-bound rounding.
- Timeline placement, trim, speed maps, keyframes, undo/redo, and invalidation.
- Persistence migrations, corruption, backup recovery, missing media, and low-disk errors.
- Color-space, range, crop, blend, mask, and effect parameter behavior.

### Integration tests

- Photos import to durable project.
- Project relaunch after every save stage.
- AVFoundation composition and exact frame extraction.
- Export codecs/containers, audio presence, frame count, duration, dimensions, and metadata.
- Firebase authentication, App Check, rules, suggestions, reports, and deletion using emulators where possible.

### UI tests

Current UI tests only cover launch. Add stable, accessibility-identifier-driven flows:

- Create project from one image and one video.
- Add/edit text and confirm it remains after relaunch.
- Move, scale, rotate, trim, split, reorder, undo, and redo.
- Add an effect and keyframe.
- Export, cancel export, deny Photos access, grant access, retry, and verify success.
- Recover a damaged project and relink missing media.
- Complete the core flow with VoiceOver-oriented accessible actions.

### Visual tests

- Dashboard, empty state, editor, each workspace, error states, export, and settings.
- Light/dark mode, smallest/largest supported devices, iPad window sizes, Dynamic Type, high contrast, and pseudolocalization.
- Renderer contact sheets for every reference fixture.

## Device and media matrix

At minimum:

- Oldest supported iPhone, a current standard iPhone, a current Pro device, and representative iPad.
- Minimum supported iOS plus latest public iOS.
- 720p, 1080p, 4K, portrait, landscape, rotated metadata, 24/25/30/50/60 fps, variable frame rate.
- H.264, HEVC, still images, transparency, wide color, HDR input policy, silent video, mono/stereo audio, long media, and malformed/unsupported files.
- Projects with 1, 10, 50, and 100 timeline items.

## Quality budgets

Finalize after profiling, then gate releases:

| Metric | Initial target |
|---|---|
| Crash-free editing sessions | ≥ 99.8% beta, ≥ 99.9% production |
| Save success | ≥ 99.99%, with no unrecoverable acknowledged edits |
| Export success for supported projects | ≥ 99% beta |
| Cold launch p95 | < 2 s on oldest supported device |
| Scrub-to-frame p95 | < 100 ms for medium reference project |
| Interactive transform response p95 | < 50 ms |
| 1080p30 preview | ≥ 28 fps reference project |
| Memory | Device-specific budget, zero jetsam in 10-minute stress run |
| Preview/export geometry difference | ≤ 0.5 output pixel |

---

# Suggested feature additions before or shortly after v1

These are lower priority than correctness and should not delay rendering stabilization unless they are central to the product promise.

## P2 feature candidates

- [ ] Project duplication and explicit project export/import package for backup and support.
- [ ] Autosave status and “last saved” visibility.
- [ ] Missing-media relink workflow.
- [ ] Export presets: social portrait, square, landscape, source resolution, and custom.
- [ ] Export destination choice: Photos, Files, and share sheet.
- [ ] Recent fonts/colors/effects and copy/paste style.
- [ ] Multi-select and grouped transforms if current model can support it safely.
- [ ] Contextual onboarding and sample project.
- [ ] Keyboard shortcuts on iPad for play/pause, undo/redo, split, delete, frame stepping, and export.

## P3 post-launch candidates

- [ ] Cloud/project sync only after conflict resolution, privacy, quotas, and media transfer are fully designed.
- [ ] Reusable templates and brand kits.
- [ ] Proxy-media workflow for long 4K projects.
- [ ] Background export with user-visible lifecycle constraints.
- [ ] Optional opt-in product analytics, only with a clear data-minimization and consent model.

---

# Recommended execution order

1. **Create a clean, reproducible baseline:** P0.1–P0.3.
2. **Build the render parity harness:** P0.4.
3. **Fix scale/text/source/color/mask correctness:** P1.1–P1.5.
4. **Profile and meet budgets:** P1.6.
5. **Harden persistence, concurrency, and import:** P0.6, P1.7–P1.8.
6. **Complete UX, accessibility, localization, and iPad polish:** P1.9–P2.3.
7. **Finish privacy, Firebase safety, moderation, diagnostics, and release operations:** P0.7–P1.13.
8. **Run TestFlight beta against the full matrix and fix all P0/P1 regressions.**

Do not start broad architectural rewrites or new large features before the render parity harness and save/recovery gates exist. Those feedback loops turn subjective “buggy/blurry” reports into reproducible, measurable work.

---

# Release-candidate checklist

## Build and code

- [ ] Clean clone builds Debug and Release.
- [ ] Unit, integration, UI smoke, visual, privacy-rule, and archive validation pass.
- [ ] No P0/P1 issues, no unexplained app-code warnings, no tracked generated/user files.
- [ ] Version/build number, symbols, entitlements, service configuration, and licenses verified.

## Rendering

- [ ] Reference fixtures pass preview/export parity thresholds.
- [ ] Text is sharp and stable through editing, playback, and export.
- [ ] Preserve full-resolution still-image inputs and transparency through 4K export.
- [ ] Blend-intensity and every compositor-visible property update preview immediately.
- [ ] Source orientation, crop, transforms, alpha, effects, masks, color, frame rate, and audio sync verified.
- [ ] 10-minute stress edit and representative 4K export pass memory and thermal checks.

## Data and reliability

- [ ] Save interruption, low disk, corruption, missing media, backgrounding, and relaunch tests pass.
- [ ] Import, analysis, preview, and export cancellation leave no stale UI or leaked files.
- [ ] Recovery and support diagnostics are customer-usable.

## UX and accessibility

- [ ] Core flow passes on supported iPhone/iPad layouts, light/dark, Dynamic Type, VoiceOver, Reduce Motion, high contrast, keyboard, and pointer.
- [ ] Loading/error/empty/cancel/retry states are complete.
- [ ] Pseudolocalization passes and launch languages are reviewed.

## Privacy, safety, and operations

- [ ] Privacy manifest and App Store privacy answers match actual behavior.
- [ ] Firebase rules, App Check, pending-by-default server-enforced moderation, report, deletion, and legal-notice workflows verified.
- [ ] Legal review complete.
- [ ] Crash/error monitoring, support, incident response, rollback, and phased release ready.

## Final ship decision

- [ ] Internal TestFlight sign-off.
- [ ] External beta success metrics meet budgets.
- [ ] Known limitations documented.
- [ ] Product, engineering, privacy/legal, moderation, and support owners approve release.
