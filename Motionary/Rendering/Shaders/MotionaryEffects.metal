#include <metal_stdlib>
using namespace metal;

// Keep this layout in sync with MotionaryEffectUniforms in MetalRenderingTypes.swift.
struct MotionaryEffectUniforms {
    uint2 size;
    uint effectKind;
    uint seed;
    float time;
    float frameIndex;
    float2 direction;
    float4 parameters;
    float4 sourceBounds;
    float4 parameters2;
    float4 parameters3;
};

;

constexpr sampler linearSampler(
    coord::normalized,
    address::clamp_to_zero,
    filter::linear
);

static float hash12(float2 value, uint seed) {
    float3 p = fract(float3(value.xyx) * 0.1031f + float(seed & 0xffffu) * 0.000013f);
    p += dot(p, p.yzx + 33.33f + float(seed >> 16u) * 0.000017f);
    return fract((p.x + p.y) * p.z);
}

static float3 unpremultiplied(float4 color) {
    return color.a > 0.00001f ? color.rgb / color.a : float3(0.0f);
}

static float4 premultiplied(float3 color, float alpha) {
    return float4(max(color, float3(0.0f)) * alpha, alpha);
}

static float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

static float3 saturation(float3 color, float amount) {
    return mix(float3(luminance(color)), color, amount);
}

static float3 screen(float3 base, float3 overlay) {
    return 1.0f - (1.0f - base) * (1.0f - overlay);
}

kernel void motionaryShapeKernel(
    texture2d<half, access::write> outputTexture [[texture(0)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float2 size = float2(uniforms.size);
    float2 rasterScale = max(uniforms.direction, float2(0.0001f));
    float2 logicalSize = size / rasterScale;
    float2 point = (float2(gid) + 0.5f - size * 0.5f) / rasterScale;
    // Shape uniforms use frameIndex for the project-to-output scale. Keep
    // the transparent edge inset in project units as output resolution changes.
    float logicalRenderScale = max(uniforms.frameIndex, 0.0001f);
    float2 halfSize = max(logicalSize * 0.5f - logicalRenderScale / rasterScale, float2(0.5f) / rasterScale);
    float distance = -1.0f;
    if (uniforms.effectKind == 1u) {
        float radius = min(max(uniforms.time, 0.0f), min(halfSize.x, halfSize.y));
        float2 q = abs(point) - halfSize + radius;
        distance = length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - radius;
    } else if (uniforms.effectKind == 2u) {
        float2 normalized = point / max(halfSize, float2(0.5f));
        distance = (length(normalized) - 1.0f) * min(halfSize.x, halfSize.y);
    } else {
        float2 q = abs(point) - halfSize;
        distance = max(q.x, q.y);
    }
    float pixelDistance = distance * min(rasterScale.x, rasterScale.y);
    float coverage = 1.0f - smoothstep(-0.5f, 0.75f, pixelDistance);
    float3 srgb = uniforms.parameters.xyz;
    float3 low = srgb / 12.92f;
    float3 high = pow((srgb + 0.055f) / 1.055f, float3(2.4f));
    float3 linear = select(high, low, srgb <= 0.04045f);
    float alpha = uniforms.parameters.w * coverage;
    outputTexture.write(half4(half3(linear * alpha), half(alpha)), gid);
}

// Shared boundary handling for every single-pass effect. Unfold mirrors each
// neighboring tile, keeping displaced samples continuous at image boundaries.
static float4 sampleEffectInput(texture2d<float, access::sample> texture, float2 uv, uint mode, float4 bounds) {
    constexpr sampler edgeSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    if (mode == 0u) { return texture.sample(linearSampler, uv); }
    float2 local = (uv - bounds.xy) / max(bounds.zw, float2(0.00001f));
    if (mode == 2u) { local = fract(local); }
    if (mode == 3u) { local = 1.0f - abs(fract(local * 0.5f) * 2.0f - 1.0f); }
    float2 halfTexel = 0.5f / float2(texture.get_width(), texture.get_height());
    float2 firstCenter = ceil(bounds.xy / (2.0f * halfTexel)) * (2.0f * halfTexel) + halfTexel;
    float2 lastCenter = floor((bounds.xy + bounds.zw) / (2.0f * halfTexel)) * (2.0f * halfTexel) - halfTexel;
    float2 coordinate = clamp(bounds.xy + local * bounds.zw, firstCenter, max(firstCenter, lastCenter));
    return texture.sample(edgeSampler, coordinate);
}

kernel void motionaryDisplacementMapKernel(
    texture2d<half, access::write> mapTexture [[texture(0)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float2 size = float2(uniforms.size);
    float2 centered = (float2(gid) + 0.5f) / size - 0.5f;
    float2 point = centered * size / min(size.x, size.y) * uniforms.parameters.y * 6.2831853f;
    float phase = uniforms.time * uniforms.parameters.z;
    float detail = uniforms.parameters.w;
    float2 map = float2(sin(point.y + phase + sin(point.x * 0.63f)),
                        cos(point.x - phase + cos(point.y * 0.71f)));
    map += float2(sin(point.x * 2.1f + point.y), cos(point.y * 1.9f - point.x)) * detail * 0.5f;
    map /= 1.0f + detail * 0.5f;
    mapTexture.write(half4(half2(map), 0.0h, 1.0h), gid);
}

// Editable colors are sRGB; the frame graph works in linear light.
static float3 creativeLinear(float3 color) {
    color = max(color, float3(0));
    return select(pow((color + 0.055f) / 1.055f, float3(2.4f)), color / 12.92f, color <= 0.04045f);
}

static float3 creativePerceptual(float3 color) {
    color = max(color, float3(0));
    return select(1.055f * pow(color, float3(1.0f / 2.4f)) - 0.055f, color * 12.92f, color <= 0.0031308f);
}

kernel void motionaryEffectKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    texture2d<float, access::sample> displacementTexture [[texture(2)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    uint edgeMode = uint(uniforms.direction.x);
    float2 size = float2(uniforms.size);
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 centered = uv - 0.5f;
    float radial = length(centered) * 2.0f;
    float4 source = sampleEffectInput(inputTexture, uv, edgeMode, uniforms.sourceBounds);
    float alpha = source.a;
    float3 color = unpremultiplied(source);
    float p0 = uniforms.parameters.x;
    float p1 = uniforms.parameters.y;
    float p2 = uniforms.parameters.z;

    switch (uniforms.effectKind) {
        case 0u: { // Prism Split
            float edge = smoothstep(max(0.05f, 0.78f - p1 * 0.55f), 1.15f, radial);
            float2 shift = normalize(centered + float2(0.0001f)) * (0.002f + p0 * 0.045f) * edge;
            float4 redSample = sampleEffectInput(inputTexture, uv + shift, edgeMode, uniforms.sourceBounds);
            float4 blueSample = sampleEffectInput(inputTexture, uv - shift, edgeMode, uniforms.sourceBounds);
            float3 red = unpremultiplied(redSample);
            float3 blue = unpremultiplied(blueSample);
            color = float3(red.r, color.g, blue.b);
            alpha = max(alpha, max(redSample.a, blueSample.a));
            break;
        }
        case 1u: { // Analog Glitch
            float row = floor(uv.y * (28.0f + p0 * 92.0f));
            float rowNoise = hash12(float2(row, floor(uniforms.frameIndex)), uniforms.seed);
            float gate = smoothstep(0.68f, 0.98f, rowNoise);
            float drift = (rowNoise - 0.5f) * gate * (2.0f + p0 * 30.0f) / size.x;
            float channelShift = (0.6f + p0 * 5.0f) / size.x;
            float3 left = unpremultiplied(sampleEffectInput(inputTexture, uv + float2(drift + channelShift, 0.0f), edgeMode, uniforms.sourceBounds));
            float3 right = unpremultiplied(sampleEffectInput(inputTexture, uv + float2(drift - channelShift, 0.0f), edgeMode, uniforms.sourceBounds));
            float3 middle = unpremultiplied(sampleEffectInput(inputTexture, uv + float2(drift, 0.0f), edgeMode, uniforms.sourceBounds));
            // Integrate the sinusoid over the authored pixel footprint. Point
            // sampling at Nyquist exaggerates contrast and aliases on export.
            // A half-pixel Gaussian reconstruction filter suppresses that
            // phase instability before arbitrary output-size resampling.
            const float pi = 3.14159265f;
            const float coverage = (2.0f / pi) * exp(-0.5f * pi * pi * 0.25f);
            float scanline = sin((float(gid.y) + 0.5f) * pi)
                * coverage * (0.025f + p1 * 0.10f);
            color = float3(left.r, middle.g, right.b) * (1.0f - scanline);
            break;
        }
        case 2u: { // Bleach Bypass
            float luma = luminance(color);
            float3 silver = mix(color, float3(luma), 0.35f + p1 * 0.62f);
            silver = (silver - 0.5f) * (1.0f + p0 * 1.15f) + 0.5f;
            float detail = luminance(unpremultiplied(sampleEffectInput(inputTexture, uv + float2(1.0f / size.x, 0.0f), edgeMode, uniforms.sourceBounds)))
                + luminance(unpremultiplied(sampleEffectInput(inputTexture, uv - float2(1.0f / size.x, 0.0f), edgeMode, uniforms.sourceBounds)))
                + luminance(unpremultiplied(sampleEffectInput(inputTexture, uv + float2(0.0f, 1.0f / size.y), edgeMode, uniforms.sourceBounds)))
                + luminance(unpremultiplied(sampleEffectInput(inputTexture, uv - float2(0.0f, 1.0f / size.y), edgeMode, uniforms.sourceBounds)))
                - luma * 4.0f;
            color = silver - detail * p2 * 0.18f;
            break;
        }
        case 3u: { // Cine Teal
            float luma = luminance(color);
            float shadow = 1.0f - smoothstep(0.18f, 0.62f, luma);
            float highlight = smoothstep(0.48f, 0.92f, luma);
            color += float3(-0.07f, 0.035f, 0.09f) * shadow;
            color += float3(0.08f + p0 * 0.08f, 0.022f, -0.045f) * highlight;
            color = saturation(color, 0.9f + p1 * 0.35f);
            color = (color - 0.5f) * (1.0f + p2 * 0.55f) + 0.5f;
            break;
        }
        case 4u: { // Kodak Print
            color.r += 0.045f + p0 * 0.075f;
            color.g += p0 * 0.018f;
            color.b -= 0.035f + p0 * 0.05f;
            color = saturation(color, 1.10f);
            color = smoothstep(float3(-0.05f), float3(1.03f), color);
            color = mix(color, color * 0.86f + 0.07f, p1);
            float grain = hash12(float2(gid) + uniforms.frameIndex * 17.0f, uniforms.seed) - 0.5f;
            color += grain * p2 * 0.055f;
            break;
        }
        case 5u: { // Portra Soft
            float luma = luminance(color);
            color = mix(color, float3(luma), p2 * 0.40f);
            color += float3(0.055f + p1 * 0.035f, 0.018f, -0.025f) * smoothstep(0.3f, 1.0f, luma);
            color = mix(color, sqrt(max(color, float3(0.0f))), p0 * 0.38f);
            color = saturation(color, 1.0f - p2 * 0.35f);
            break;
        }
        case 6u: { // Cool Fade
            float luma = luminance(color);
            color = mix(color, float3(0.055f, 0.075f, 0.12f), (1.0f - luma) * p0 * 0.55f);
            color += float3(-0.025f, 0.008f, 0.055f) * p0;
            color = saturation(color, 1.0f - p1 * 0.18f);
            color = (color - 0.5f) * (1.0f + p2 * 0.3f) + 0.5f;
            break;
        }
        case 7u: { // Matte Contrast
            color = (color - 0.5f) * (1.0f + p1 * 0.75f) + 0.5f;
            color = max(color, float3(0.015f + p0 * 0.12f));
            color = min(color, float3(0.98f));
            break;
        }
        case 8u: { // Fine Grain
            float noise = hash12(float2(gid) + uniforms.frameIndex * float2(31.0f, 47.0f), uniforms.seed) - 0.5f;
            float lumaWeight = mix(1.0f, 0.35f + 0.65f * (1.0f - abs(luminance(color) * 2.0f - 1.0f)), p1);
            // Grain strength is a perceptual contrast, not linear-light
            // energy. Adding it in linear light makes black grain dramatically
            // brighter and changes its contrast when the output is resampled.
            float3 perceptual = creativePerceptual(color);
            perceptual += noise * (0.015f + p0 * 0.095f) * lumaWeight;
            color = creativeLinear(clamp(perceptual, float3(0), float3(1)));
            break;
        }
        case 9u: { // Light Leak
            float angle = p0 * 0.01745329252f;
            float2 axis = float2(cos(angle), sin(angle));
            float projected = dot(centered, axis);
            float across = abs(dot(centered, float2(-axis.y, axis.x)));
            float spread = 0.08f + p2 * 0.48f;
            float leak = exp(-across * across / max(spread * spread, 0.001f))
                * smoothstep(-0.7f, 0.35f, projected);
            float pulse = 0.86f + hash12(float2(floor(uniforms.frameIndex / 3.0f), 7.0f), uniforms.seed) * 0.14f;
            float3 tint = mix(float3(1.0f, 0.22f, 0.035f), float3(1.0f, 0.66f, 0.16f), p1);
            color = screen(color, tint * leak * pulse * 0.82f);
            break;
        }
        case 10u: { // Chromatic Aberration
            float edge = smoothstep(max(0.02f, 0.92f - p1 * 0.62f), 1.18f, radial);
            float2 direction = normalize(centered + float2(0.0001f));
            float2 shift = direction * edge * (0.001f + p0 * 0.028f);
            float4 redSample = sampleEffectInput(inputTexture, uv + shift, edgeMode, uniforms.sourceBounds);
            float4 blueSample = sampleEffectInput(inputTexture, uv - shift, edgeMode, uniforms.sourceBounds);
            color.r = unpremultiplied(redSample).r;
            color.b = unpremultiplied(blueSample).b;
            alpha = max(alpha, max(redSample.a, blueSample.a));
            break;
        }
        case 11u: { // Barrel / pincushion warp
            float r2 = dot(centered, centered);
            float strength = p0 * 0.42f;
            float2 warped = centered * (1.0f + strength * r2 * 4.0f);
            float4 warpedSample = sampleEffectInput(inputTexture, warped + 0.5f, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(warpedSample);
            alpha = warpedSample.a;
            break;
        }
        case 12u: { // Wave Warp: metric in fractions of the shorter image side.
            float2 metric = size / min(size.x, size.y);
            float2 axis = float2(cos(p2), sin(p2));
            float2 normal = float2(-axis.y, axis.x);
            float phase = dot(centered * metric, axis) * 6.2831853f / max(p1, 0.02f)
                + uniforms.time * uniforms.parameters.w * 6.2831853f;
            float2 warped = uv + normal * sin(phase) * p0 / metric;
            float4 sampled = sampleEffectInput(inputTexture, warped, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 33u: { // Radial ripple, measured in fractions of the shorter side.
            float2 metric = size / min(size.x, size.y);
            float2 delta = (uv - uniforms.parameters2.xy) * metric;
            float distance = length(delta);
            float2 direction = distance > 0.00001f ? delta / distance : float2(0.0f);
            float wavelength = max(p1, 0.02f);
            float phase = distance * 6.2831853f / wavelength - uniforms.time * p2 * 6.2831853f;
            // A water surface loses energy as the wave travels. Soften the
            // origin too, where a radial direction is otherwise undefined.
            float originFade = smoothstep(0.0f, wavelength * 0.7f, distance);
            float falloff = 1.0f / sqrt(1.0f + distance * 3.0f);
            // Amount controls the actual displacement across its full range.
            float amplitude = max(p0, 0.0f);
            float slope = sin(phase) * amplitude / wavelength * originFade * falloff;
            // Treat the ripple as a raised surface: its slope drives both
            // refraction and the normal used for directional lighting.
            float3 normal = normalize(float3(-direction * slope * 3.5f, 1.0f));
            float2 warped = uv + direction * (slope * wavelength) / metric;
            float4 sampled = sampleEffectInput(inputTexture, warped, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            float3 light = normalize(float3(-0.5f, 0.65f, 0.8f));
            float diffuse = dot(normal, light) - light.z;
            float3 halfVector = normalize(light + float3(0.0f, 0.0f, 1.0f));
            float specular = max(pow(max(dot(normal, halfVector), 0.0f), 32.0f)
                - pow(halfVector.z, 32.0f), 0.0f);
            float reflection = clamp(uniforms.parameters.w, 0.0f, 1.0f) / 0.7f;
            color = max(color * (1.0f + diffuse * 0.65f * reflection) + specular * 0.22f * reflection, float3(0.0f));
            break;
        }
        case 13u: { // Twirl with a smooth, bounded influence radius.
            float2 metric = size / min(size.x, size.y);
            float2 delta = (uv - uniforms.parameters2.xy) * metric;
            float influence = max(1.0f - length(delta) / max(p1, 0.001f), 0.0f);
            float angle = p0 * influence * influence;
            float2 rotated = float2(cos(angle) * delta.x - sin(angle) * delta.y,
                                    sin(angle) * delta.x + cos(angle) * delta.y);
            float4 sampled = sampleEffectInput(inputTexture, uniforms.parameters2.xy + rotated / metric, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 14u: { // Pixelate, square cells even on non-square media.
            float cell = max(1.0f, p0 * min(size.x, size.y));
            float2 snapped = (floor((float2(gid) + 0.5f) / cell) + 0.5f) * cell / size;
            float4 sampled = sampleEffectInput(inputTexture, snapped, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 15u: { // Posterize in perceptual rather than linear-light steps.
            float levels = max(round(p0), 2.0f) - 1.0f;
            float3 perceptual = pow(max(color, float3(0)), float3(1.0f / 2.2f));
            color = pow(round(clamp(perceptual, 0.0f, 1.0f) * levels) / levels, float3(2.2f));
            break;
        }
        case 18u: { // Mirror / Kaleidoscope
            float2 metric = size / min(size.x, size.y);
            float2 delta = (uv - uniforms.parameters2.xy) * metric;
            float sector = 6.2831853f / max(round(p0), 1.0f);
            float angle = atan2(delta.y, delta.x) - p1;
            angle = abs(fract(angle / sector + 0.5f) * sector - sector * 0.5f);
            float2 folded = float2(cos(angle + p1), sin(angle + p1)) * length(delta);
            float4 sampled = sampleEffectInput(inputTexture, uniforms.parameters2.xy + folded / metric, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 19u: { // The auxiliary map contains independent signed X/Y displacement.
            float2 metric = size / min(size.x, size.y);
            float2 map = displacementTexture.sample(linearSampler, uv).rg;
            float4 sampled = sampleEffectInput(inputTexture, uv + map * p0 / metric, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 24u: { // Duotone: editable sRGB colors, mixed in linear light.
            float4 low = uniforms.parameters;
            float4 high = uniforms.parameters2;
            float3 lowLinear = select(pow((low.rgb + 0.055f) / 1.055f, float3(2.4f)), low.rgb / 12.92f, low.rgb <= 0.04045f);
            float3 highLinear = select(pow((high.rgb + 0.055f) / 1.055f, float3(2.4f)), high.rgb / 12.92f, high.rgb <= 0.04045f);
            float luma = clamp(luminance(color), 0.0f, 1.0f);
            color = mix(lowLinear, highLinear, luma);
            alpha *= mix(low.a, high.a, luma);
            break;
        }
        case 25u: { // Light sweep, clipped to the incoming alpha.
            float2 axis = float2(cos(p1), sin(p1));
            float span = abs(axis.x) + abs(axis.y);
            float coordinate = dot(centered, axis) / max(span, 0.001f) + 0.5f;
            float position = p0;
            float speed = uniforms.parameters2.w;
            if (abs(speed) > 0.00001f) {
                position = fract((p0 + 0.5f + uniforms.time * speed) / 2.0f) * 2.0f - 0.5f;
            }
            float band = exp(-pow((coordinate - position) / max(p2 * 0.35f, 0.001f), 2.0f));
            float3 tint = creativeLinear(uniforms.parameters2.rgb);
            color += tint * band * uniforms.parameters.w * uniforms.parameters3.x;
            break;
        }
        case 26u: { // Aspect-correct sinusoidal refraction through glass ridges.
            float2 metric = size / min(size.x, size.y);
            float2 axis = float2(cos(p2), sin(p2));
            float coordinate = dot(centered * metric, axis);
            float width = max(p0, 0.001f);
            float phase = (coordinate / width + uniforms.parameters.w) * 6.2831853f;
            float offset = sin(phase) * width * p1 * 0.45f;
            float4 sampled = sampleEffectInput(inputTexture, uv + axis * offset / metric, edgeMode, uniforms.sourceBounds);
            color = unpremultiplied(sampled); alpha = sampled.a;
            break;
        }
        case 27u: { // Ordered 4x4 Bayer threshold in perceptual luminance.
            float cell = max(uniforms.parameters.w * min(size.x, size.y), 1.0f);
            uint2 pixel = uint2(floor(float2(gid) / cell));
            constexpr float bayer[16] = {0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
            float2 snapped = (floor(float2(gid) / cell) + 0.5f) * cell / size;
            float3 sampled = unpremultiplied(sampleEffectInput(inputTexture, snapped, edgeMode, uniforms.sourceBounds));
            float luma = pow(clamp(luminance(sampled), 0.0f, 1.0f), 1.0f / 2.2f);
            luma = clamp((luma - 0.5f) * uniforms.parameters2.w + 0.5f, 0.0f, 1.0f);
            float threshold = (bayer[(pixel.y % 4u) * 4u + pixel.x % 4u] + 0.5f) / 16.0f;
            float high = step(threshold, luma);
            color = creativeLinear(mix(uniforms.parameters.rgb, uniforms.parameters2.rgb, high));
            alpha *= mix(uniforms.parameters3.x, uniforms.parameters3.y, high);
            break;
        }
        case 28u: { // Rotated, antialiased ink-dot lattice.
            float spacing = max(uniforms.parameters.w * min(size.x, size.y), 2.0f);
            float a = uniforms.direction.y;
            float2 axis = float2(cos(a), sin(a));
            float2 perpendicular = float2(-axis.y, axis.x);
            float2 point = centered * size;
            float2 grid = float2(dot(point, axis), dot(point, perpendicular)) / spacing;
            float2 cell = floor(grid) + 0.5f;
            float2 sampleUV = (axis * cell.x + perpendicular * cell.y) * spacing / size + 0.5f;
            float3 sampled = unpremultiplied(sampleEffectInput(inputTexture, sampleUV, edgeMode, uniforms.sourceBounds));
            float luma = pow(clamp(luminance(sampled), 0.0f, 1.0f), 1.0f / 2.2f);
            luma = clamp((luma - 0.5f) * uniforms.parameters2.w + 0.5f, 0.0f, 1.0f);
            float radius = sqrt(1.0f - luma) * 0.707107f;
            float distance = length(grid - cell);
            float aa = 0.75f / spacing;
            float ink = 1.0f - smoothstep(radius - aa, radius + aa, distance);
            if (luma >= 0.99999f) { ink = 0; }
            color = creativeLinear(mix(uniforms.parameters2.rgb, uniforms.parameters.rgb, ink));
            alpha *= mix(uniforms.parameters3.y, uniforms.parameters3.x, ink);
            break;
        }
        case 29u: { // Circular hue selection; neutral pixels stay neutral.
            float3 target = uniforms.parameters2.rgb;
            float3 perceptual = creativePerceptual(color);
            float targetHue = atan2(1.7320508f * (target.g - target.b), 2.0f * target.r - target.g - target.b);
            float hue = atan2(1.7320508f * (perceptual.g - perceptual.b), 2.0f * perceptual.r - perceptual.g - perceptual.b);
            float delta = abs(atan2(sin(hue - targetHue), cos(hue - targetHue))) / 6.2831853f;
            float selection = 1.0f - smoothstep(p0, p0 + max(p1, 0.001f), delta);
            float chroma = max(perceptual.r, max(perceptual.g, perceptual.b)) - min(perceptual.r, min(perceptual.g, perceptual.b));
            selection *= smoothstep(0.01f, 0.08f, chroma);
            color = mix(float3(luminance(color)), color, mix(p2, 1.0f, selection));
            break;
        }
        case 30u: { // Sobel contours at a resolution-independent line width.
            float2 offset = float2(max(p0 * min(size.x, size.y), 0.75f)) / size;
            float samples[9];
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float4 sample = sampleEffectInput(inputTexture, uv + float2(x, y) * offset, edgeMode, uniforms.sourceBounds);
                    samples[(y + 1) * 3 + x + 1] = pow(clamp(luminance(unpremultiplied(sample)), 0.0f, 1.0f), 1.0f / 2.2f) * sample.a;
                }
            }
            float gx = -samples[0] + samples[2] - 2 * samples[3] + 2 * samples[5] - samples[6] + samples[8];
            float gy = -samples[0] - 2 * samples[1] - samples[2] + samples[6] + 2 * samples[7] + samples[8];
            float edge = smoothstep(p1, p1 + 0.25f, length(float2(gx, gy)));
            float3 tint = creativeLinear(uniforms.parameters2.rgb);
            color = color * uniforms.parameters.w + tint * edge * (1.0f + p2) * uniforms.parameters2.a;
            break;
        }
        case 31u: { // Inverse camera transform in aspect-correct image space.
            float2 metric = size / min(size.x, size.y);
            float2 pivot = uniforms.parameters2.xy;
            float2 point = (uv - pivot - uniforms.parameters.zw) * metric;
            float c = cos(p1), s = sin(p1);
            point = float2(c * point.x + s * point.y, -s * point.x + c * point.y);
            float2 coordinate = pivot + point / (max(p0, 0.01f) * metric);
            float4 sampled = sampleEffectInput(inputTexture, coordinate, edgeMode, uniforms.sourceBounds);
            outputTexture.write(half4(sampled), gid);
            return;
        }
        case 32u: { // Reflect only the opposite half across the selected axis.
            float2 metric = size / min(size.x, size.y);
            float2 pivot = uniforms.parameters2.xy;
            float2 point = (uv - pivot) * metric;
            float2 normal = uniforms.parameters.xy;
            float distance = dot(point, normal);
            if (distance * p2 < 0) { point -= 2 * distance * normal; }
            float4 sampled = sampleEffectInput(inputTexture, pivot + point / metric, edgeMode, uniforms.sourceBounds);
            outputTexture.write(half4(sampled), gid);
            return;
        }
        default:
            break;
    }

    if (alpha <= 0.00001f) {
        outputTexture.write(half4(0.0h), gid);
    } else {
        outputTexture.write(half4(premultiplied(color, alpha)), gid);
    }
}

kernel void motionaryHighlightKernel(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float4 sample = inputTexture.read(gid);
    float3 color = unpremultiplied(sample);
    float luma = luminance(color);
    float threshold = clamp(uniforms.parameters.y, 0.02f, 0.98f);
    float selection = smoothstep(threshold, min(threshold + 0.24f, 1.2f), luma) * sample.a;
    float3 tint = float3(1.0f);
    if (uniforms.effectKind == 21u) {
        tint = mix(float3(1.0f, 0.20f, 0.03f), float3(1.0f, 0.52f, 0.10f), uniforms.parameters.z);
    } else if (uniforms.effectKind == 23u) {
        tint = mix(float3(0.12f, 0.38f, 1.0f), float3(1.0f, 0.55f, 0.16f), uniforms.parameters.z);
    }
    outputTexture.write(half4(half3(color * tint * selection), half(selection)), gid);
}

kernel void motionarySeparableBlurKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float2 size = float2(uniforms.size);
    float2 uv = (float2(gid) + 0.5f) / size;
    float radius = max(uniforms.parameters.x, 0.0f);
    if (radius < 0.5f) {
        outputTexture.write(half4(inputTexture.sample(linearSampler, uv)), gid);
        return;
    }
    constexpr int maximumSamples = 24;
    float sigma = max(radius * 0.36f, 0.5f);
    float stepSize = max(1.0f, radius / float(maximumSamples));
    int count = min(maximumSamples, int(ceil(radius / stepSize)));
    float4 sum = inputTexture.sample(linearSampler, uv);
    float total = 1.0f;
    for (int index = 1; index <= count; ++index) {
        float distance = float(index) * stepSize;
        float weight = exp(-(distance * distance) / (2.0f * sigma * sigma));
        float2 delta = uniforms.direction * distance / size;
        sum += inputTexture.sample(linearSampler, uv + delta) * weight;
        sum += inputTexture.sample(linearSampler, uv - delta) * weight;
        total += weight * 2.0f;
    }
    outputTexture.write(half4(sum / total), gid);
}

kernel void motionaryGlowCompositeKernel(
    texture2d<float, access::read> sourceTexture [[texture(0)]],
    texture2d<float, access::read> glowTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    texture2d<float, access::read> wideGlowTexture [[texture(3)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float4 source = sourceTexture.read(gid);
    float4 glow = glowTexture.read(gid);
    if (uniforms.effectKind == 34u) {
        float4 wide = wideGlowTexture.read(gid);
        float intensity = max(uniforms.parameters.w, 0.0f) * 1.8f;
        float3 light = (glow.rgb * 0.65f + wide.rgb * 0.85f) * intensity;
        float alpha = source.a + (1.0f - source.a) * clamp((glow.a * 0.65f + wide.a * 0.85f) * intensity, 0.0f, 1.0f);
        outputTexture.write(half4(half3(source.rgb + light), half(alpha)), gid);
        return;
    }
    float3 base = unpremultiplied(source);
    float3 halo = unpremultiplied(glow) * glow.a;
    float strength = 0.72f;
    if (uniforms.effectKind == 20u) {
        base = saturation((base - 0.5f) * 1.08f + 0.5f, 1.0f + uniforms.parameters.z * 0.22f);
        strength = 0.92f;
    } else if (uniforms.effectKind == 21u) {
        strength = 0.82f;
    } else if (uniforms.effectKind == 22u) {
        strength = 0.48f;
    } else if (uniforms.effectKind == 23u) {
        strength = 2.8f;
    }
    float3 result = screen(base, halo * strength);
    float alpha = source.a + (1.0f - source.a) * clamp(glow.a * strength, 0.0f, 1.0f);
    outputTexture.write(half4(premultiplied(result, alpha)), gid);
}

static float3 rgbToHsl(float3 color) {
    float maximum = max(color.r, max(color.g, color.b));
    float minimum = min(color.r, min(color.g, color.b));
    float delta = maximum - minimum;
    float lightness = (maximum + minimum) * 0.5f;
    float saturationValue = delta <= 0.00001f
        ? 0.0f
        : delta / max(1.0f - abs(2.0f * lightness - 1.0f), 0.00001f);
    float hue = 0.0f;
    if (delta > 0.00001f) {
        if (maximum == color.r) {
            hue = fmod((color.g - color.b) / delta, 6.0f);
        } else if (maximum == color.g) {
            hue = (color.b - color.r) / delta + 2.0f;
        } else {
            hue = (color.r - color.g) / delta + 4.0f;
        }
        hue = fract(hue / 6.0f);
    }
    return float3(hue, saturationValue, lightness);
}

static float hueChannel(float p, float q, float t) {
    t = fract(t);
    if (t < 1.0f / 6.0f) { return p + (q - p) * 6.0f * t; }
    if (t < 0.5f) { return q; }
    if (t < 2.0f / 3.0f) { return p + (q - p) * (2.0f / 3.0f - t) * 6.0f; }
    return p;
}

static float3 hslToRgb(float3 hsl) {
    if (hsl.y <= 0.00001f) { return float3(hsl.z); }
    float q = hsl.z < 0.5f
        ? hsl.z * (1.0f + hsl.y)
        : hsl.z + hsl.y - hsl.z * hsl.y;
    float p = 2.0f * hsl.z - q;
    return float3(
        hueChannel(p, q, hsl.x + 1.0f / 3.0f),
        hueChannel(p, q, hsl.x),
        hueChannel(p, q, hsl.x - 1.0f / 3.0f)
    );
}

static float3 blendFunction(float3 background, float3 foreground, uint mode) {
    switch (mode) {
        case 1u: return min(background, foreground); // darken
        case 2u: return background * foreground; // multiply
        case 3u: return 1.0f - min((1.0f - background) / max(foreground, float3(0.00001f)), 1.0f); // color burn
        case 4u: return max(background, foreground); // lighten
        case 5u: return screen(background, foreground);
        case 6u: return min(background / max(1.0f - foreground, float3(0.00001f)), 1.0f); // color dodge
        case 7u: return select(
            1.0f - 2.0f * (1.0f - background) * (1.0f - foreground),
            2.0f * background * foreground,
            background <= 0.5f
        );
        case 8u: { // soft light
            float3 d = select(
                sqrt(max(background, float3(0.0f))),
                ((16.0f * background - 12.0f) * background + 4.0f) * background,
                background <= 0.25f
            );
            return select(
                background + (2.0f * foreground - 1.0f) * (d - background),
                background - (1.0f - 2.0f * foreground) * background * (1.0f - background),
                foreground <= 0.5f
            );
        }
        case 9u: return select(
            1.0f - 2.0f * (1.0f - background) * (1.0f - foreground),
            2.0f * background * foreground,
            foreground <= 0.5f
        );
        case 10u: return abs(background - foreground);
        case 11u: return background + foreground - 2.0f * background * foreground;
        case 12u: { // hue
            float3 bh = rgbToHsl(background);
            float3 fh = rgbToHsl(foreground);
            return hslToRgb(float3(fh.x, bh.y, bh.z));
        }
        case 13u: { // saturation
            float3 bh = rgbToHsl(background);
            float3 fh = rgbToHsl(foreground);
            return hslToRgb(float3(bh.x, fh.y, bh.z));
        }
        case 14u: { // color
            float3 bh = rgbToHsl(background);
            float3 fh = rgbToHsl(foreground);
            return hslToRgb(float3(fh.x, fh.y, bh.z));
        }
        case 15u: { // luminosity
            float3 bh = rgbToHsl(background);
            float3 fh = rgbToHsl(foreground);
            return hslToRgb(float3(bh.x, bh.y, fh.z));
        }
        default: return foreground;
    }
}

kernel void motionaryBlendKernel(
    texture2d<float, access::read> foregroundTexture [[texture(0)]],
    texture2d<float, access::read> backgroundTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float4 foregroundSample = foregroundTexture.read(gid);
    float4 backgroundSample = backgroundTexture.read(gid);
    float3 foreground = unpremultiplied(foregroundSample);
    float3 background = unpremultiplied(backgroundSample);
    float foregroundAlpha = foregroundSample.a;
    float backgroundAlpha = backgroundSample.a;
    float outputAlpha = foregroundAlpha + backgroundAlpha * (1.0f - foregroundAlpha);

    float3 normal = foregroundSample.rgb + backgroundSample.rgb * (1.0f - foregroundAlpha);
    float3 blendedColor = blendFunction(background, foreground, uniforms.effectKind);
    float3 blended =
        backgroundSample.rgb * (1.0f - foregroundAlpha)
        + foregroundSample.rgb * (1.0f - backgroundAlpha)
        + blendedColor * foregroundAlpha * backgroundAlpha;
    float amount = clamp(uniforms.parameters.x, 0.0f, 1.0f);
    outputTexture.write(half4(half3(mix(normal, blended, amount)), half(outputAlpha)), gid);
}
