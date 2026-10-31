# Effect catalog and render inputs

The effect registry is the shared source for library tiles, parameter controls,
keyframes, persistence and renderer construction. New entries have stable module
IDs and versioned parameters. The catalog currently contains 32 modules.

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
amounts are normalized to source dimensions, so they retain their meaning at
preview and export resolutions. The internal edge strategy is absent from user
controls.

Every effect pass is clipped to the original layer bounds before mixing and
before the next effect runs. Unfold and other edge strategies extend sampling
only; their tiles and render margins never enlarge the object's visible bounds.
Clipping happens before layer placement, so it follows rotation and scaling in
both preview and export.

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
Interactive historical samples are capped at 1280 pixels on their longest side;
export samples use the requested source dimensions. Decoding runs on the render
worker and has a bounded wait. Echo can therefore cost substantially more than a
spatial effect on an uncached seek.

Historical video frames receive color adjustments and the spatial prefix of the
effect stack. Temporal effects are excluded from that prefix to avoid recursive
history expansion. Historical samples are limited to the current clip. Foreground
history uses the current foreground alpha as a clipping mask. On still images,
generated layers and adjustment layers without a temporal video source, Trails
repeats the current input using the configured spatial drift. It does not replay
historical text/shape animations, layer placement or the full composition.

## Validation

The app and Metal shaders compile for iOS Simulator. The existing registry test
was updated for all 32 entries and persistence round trips. Simulator execution,
visual tuning and runtime performance checks were not run: the user requested
build-only validation for this change.
