# Effect catalog and render inputs

The effect registry is the shared source for library tiles, parameter controls,
keyframes, persistence and renderer construction. New entries have stable module
IDs and versioned parameters. The catalog currently contains 43 modules.

## Additional effects

| Effect | Category | Controls | Render path |
| --- | --- | --- | --- |
| Wave Warp | Distortion | Amount, wavelength, angle, signed animation speed | Metal, unfold |
| Twirl | Distortion | Twist, radius, center X/Y | Metal, unfold |
| Pixelate | Essentials | Pixel size relative to the shorter image dimension | Metal, clamp |
| Posterize | Color Grade | Tonal levels | Metal, perceptual quantization |
| Directional Blur | Lens | Length, angle | Core Image motion blur, unfold |
| Zoom Blur | Lens | Amount, center X/Y | Core Image zoom blur, unfold |
| Mirror / Kaleidoscope | Distortion | Segments, rotation, center X/Y | Metal, unfold |
| Duotone | Color Grade | Shadow/highlight RGBA, contrast | Metal, linear-light color interpolation |
| Displacement Map | Distortion | Amount, scale, signed speed, detail | Procedural map pass, Metal, unfold |
| Echo / Trails | Lens | Echo count, time spacing, decay, spatial drift | Historical video source frames and normalized accumulation |

All presets start with full mix. Parameters use the existing typed value and
keyframe infrastructure. Center coordinates use top-left UI coordinates. Spatial
amounts are normalized to the layer's authored effect input, fitted to project
pixels independently of proxy and output resolution. The internal edge strategy is absent from user
controls.

Spatial effect passes are clipped to the original layer bounds before mixing.
Motion Blur preserves its expanded trail bounds for subsequent passes. Unfold and other edge strategies extend sampling
only; their tiles and render margins never enlarge the object's visible bounds.
Clipping happens before layer placement, so it follows rotation and scaling in
both preview and export.

## Camera motion

| Effect | Controls |
| --- | --- |
| Shake | Strength, frequency in Hz, independent horizontal/vertical amount, rotation, exponential decay, zoom, variation, edges |
| Camera Wiggle | Strength, frequency in Hz, independent axes, rotation, zoom, variation, edges |
| Zoom | In / Out / Pulse / Static, minimum/maximum zoom, duration in seconds, easing, center, X/Y offset, edges |
| Mirror | Vertical / Horizontal / Custom axis, retained side, angle, center, edges |
| Motion Blur | Position / Rotation / Scale in any combination, shutter angle (0–720°), exposure samples (2–32), mix and keyframes |

Camera noise is seeded from the persisted effect seed and variation, addressed
by clip time independently of frame rate, seek order and output resolution.
Shake interpolates sharp random targets. Camera Wiggle sums continuous oscillators
with independent phases and frequencies, avoiding stops at noise lattice points.
Position strength is relative to the shorter source dimension.

Zoom runs from the lower to the upper scale for In, in the opposite direction
for Out, and repeats a full out-and-back cycle per Duration for Pulse. Static
uses Minimum Zoom directly. Below 1, Unfold reveals reflected neighboring
tiles inside the original layer bounds. Positive offsets move the picture right
and down. Center coordinates use the existing top-left convention.
The edge menu offers Unfold, Repeat Tiles, Transparent and Clamp. Shake and
Wiggle additionally support Auto Crop, which fits the complete movement envelope
without changing the crop on every random sample.
Choice controls participate in undo and persistence; numeric controls support keyframes.

Reverse Time has been removed. Persisted legacy markers are ignored by preview and export.

Motion Blur integrates object transforms and preceding Shake, Camera Wiggle and
Zoom effects at every shutter sample. Movement inside video footage is never
temporally sampled. For object transforms, position, rotation and scale can be
included independently in any combination. Static
objects pass through unchanged; blur can extend beyond the original object bounds.
Masks are applied before integration. On adjustment layers, the compositor samples
the placements of all underlying layers while freezing their source pixels,
then applies the adjustment layer's mask and opacity to the result.
All paths use the authored sample count, up to 32, without an interaction cap.

The effect library prepares all static effect thumbnails before displaying its
grid. Scrolling therefore never reveals an unprocessed source image while a
thumbnail renders. Visible animated previews use cached 24-frame loops at 12 fps.

## Auxiliary inputs

`EffectRenderConfiguration` declares edge sampling, procedural displacement-map
requirements and temporal-frame requirements. Displacement Map generates an
independent, signed two-channel map texture before sampling the source. Its
current map is procedural; choosing an external map asset is a separate UI/input
feature.

`EffectTemporalSource` addresses original video frames by clip time, accounting
for source trim and speed mapping. This avoids a playback-history accumulator:
seeking backward or exporting a frame out of order does not change its inputs.
The decoder uses a bounded 96 MiB / 32-frame cache and at most four generators.
Historical samples use the requested effect-input dimensions and source times
on all paths. Decoding runs on the render worker and has a bounded wait. Echo can
therefore cost substantially more than a spatial effect on an uncached seek.
Decoded cache hits bypass the decoder lock.

Historical video frames receive color adjustments and the spatial prefix of the
effect stack. Temporal effects are excluded from that prefix to avoid recursive
history expansion. Historical samples are limited to the current clip. Foreground
history uses the current foreground alpha as a clipping mask. On still images,
generated layers and adjustment layers without a temporal video source, Trails
repeats the current input using the configured spatial drift. It does not replay
historical text/shape animations, layer placement or the full composition.

## Validation

The app and Metal shaders compile for iOS Simulator and an unsigned device
Release build. Automated coverage includes every registered effect's interactive
and export appearance, persistence round trips, GPU rendering, effect bypass,
transparent inputs, Color Splash hue selection and encoded exports at multiple
resolutions. Physical-device performance and a manual export review remain release gates.

Focused suites cover deterministic preview seeds, transform-only shutter integration,
component selection, static/bypass behavior, removed Reverse Time compatibility,
zoom directions, edge sampling, crop geometry and registry persistence.

## Creative modules

| Effect | Controls | Render path |
| --- | --- | --- |
| Light Sweep | Position, angle, width, brightness, signed speed, light color | Metal light band, preserving source alpha |
| Ribbed Glass | Ridge width, refraction, angle, phase offset | Metal aspect-correct periodic refraction, unfold |
| Dither | Pixel size, contrast, shadow/highlight colors | Metal 4×4 Bayer threshold in perceptual luminance |
| Halftone | Dot spacing, angle, contrast, ink/paper colors | Metal antialiased rotated lattice with cell-center sampling |
| Color Splash | Keep color, hue range, softness, background saturation | Metal circular hue selection with neutral suppression |
| Neon Edges | Line width, threshold, glow, original image, neon color | Metal Sobel contours followed by Core Image bloom |

Raster, ridge and line sizes are relative to the shorter source dimension.
All six use the shared typed parameter, keyframe, mix, thumbnail and persistence
paths. Light Sweep animates from clip time; set Speed to zero to animate Position
entirely with keyframes. Neon glow stays within the original layer bounds and
source alpha, as required by the effect stack's clipping policy.

The creative modules' tests include nonuniform inputs, half transparency and
bypass. The wider CanvasAndRenderingTests suite also passes on iOS 26.3.1,
including blur opacity, fine-grain resolution matching on adjustment layers and
glitch-export brightness. See [the release review](ReleaseReadiness.md) for the
separate iOS 18 compatibility findings.

## Interactive effect rendering

Scrubbing uses the same preview dimensions and vector supersampling as playback.
Every effect processes its full authored input without an additional interactive
downscale. Text keeps the requested timeline time at 60/120 fps; Motion Blur and
Echo do not discard samples during interaction.

Completed preview pixel buffers are reused directly through a memory-bounded LRU
cache (32–128 MiB according to device memory). The cache clears under memory
pressure. Session, visual revision and timeline time isolate entries; graph
rebuilds and player replacement invalidate the cache. A GPU completion from an
older revision cannot populate the new revision. Cached scrubbing needs neither
decoder work nor another effect render, and no CPU pixel readback.

Generated/image-only intervals render at new times directly on the asynchronous
Metal path using the current immutable graph. Video intervals reuse decoded
sources only at their original time; unseen video frames continue through
coalesced AVFoundation seeks. Pending requests retain only the latest destination.
On release, the exact seek waits for frame presentation and uncovers the canonical
player image, without a second quality rebuild. Adjustment motion scenes are only
constructed when an active adjustment layer actually uses Motion Blur.

Media effects run in project-pixel coordinates, matching generated and adjustment
layers. Proxy dimensions and export dimensions do not redefine an authored effect
radius or procedural cell. Grain is added in perceptual color space so its contrast does not brighten dark
pixels disproportionately when resampled. Scanlines integrate their authored pixel footprint.


### Adjustment render groups

Adjustment inputs are composited in project-canvas coordinates into a transparent
canvas-sized image before running the adjustment stack once per contiguous run. Small layer extents
must be expanded with a transparent canvas, not merely cropped. Preview and export
use the same group compositor. Source preparation remains once per active clip;
adding group members does not multiply adjustment effect invocations. Motion blur
still samples the group's shared motion scene over its shutter interval.

Excluded inputs retain their original depth and split selected inputs into
contiguous runs. Each run is composited into a full canvas before effects are
applied, preserving shared coordinates, transparency and the excluded input's
stack position. The number of adjustment evaluations follows depth runs rather
than source count. Spatial filters cannot mix pixels across an excluded depth
boundary; this is the defined tradeoff for preserving the original flat stack.
The canvas background remains outside selective runs. `All` includes it as before.

Earlier adjustment outputs are atomic group inputs. Selecting any member includes
the whole earlier group, and excluding any member excludes it. The workspace shows
these groups as single rows and stores selections by stable track identities.
The input list follows active sources at the playhead (clamped to the selected
adjustment's interval). Effects, masks, opacity, and group transforms retain their
canvas coordinate domain through nested groups.

### Depth Map

Depth Anything V2 Small runs locally. Video depth is prepared before a composition
is installed, at 24 depth samples per second, and cached as immutable PNGs under
Caches/DepthTracks-v5. Rendering interpolates adjacent depth samples. It does not
invoke Core ML. Scrub order therefore cannot change the resulting depth.

Medium/High stabilization uses an offline three-frame median with a difference
gate to avoid smearing moving edges and cuts. This reduces local temporal noise;
it does not turn the single-image model into a video depth model.

Cache identity includes the source URL and modification date, trim, speed map,
orientation and stabilization mode. Output contrast, brightness,
direction and style are applied afterwards and reuse the analysis. Source color
adjustments are intentionally excluded from depth inference. Preparation supports
cancellation; incomplete tracks have no completion marker and are rebuilt. Old
tracks beyond the eight most recent are eligible for eviction after seven days.
The decoded depth image cache is bounded to 32 MB. Stills use a content hash at
model resolution and reuse one stored inference result.

Depth output replaces the clip's source before adjustments and other effects.
The Bands control is shown only for the Bands style. Legacy Source mix styles
fall back to Grayscale. The effect library normalizes its bundled DepthMapPreview
asset to the same square framing as the original, without model loading.
