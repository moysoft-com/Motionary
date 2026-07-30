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
};

struct MotionaryYUVUniforms {
    uint2 size;
    uint fullRange;
    uint matrix;
};

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

kernel void motionaryYUVToRGBA(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    constant MotionaryYUVUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float2 uv = (float2(gid) + 0.5f) / float2(uniforms.size);
    float y = lumaTexture.sample(linearSampler, uv).r;
    float2 chroma = chromaTexture.sample(linearSampler, uv).rg;
    if (uniforms.fullRange == 0u) {
        y = clamp((y - 16.0f / 255.0f) * (255.0f / 219.0f), 0.0f, 1.0f);
        chroma = (chroma - 0.5f) * (255.0f / 224.0f);
    } else {
        chroma -= 0.5f;
    }
    float3 rgb;
    if (uniforms.matrix == 0u) { // Rec.601
        rgb = float3(
            y + 1.4020f * chroma.y,
            y - 0.344136f * chroma.x - 0.714136f * chroma.y,
            y + 1.7720f * chroma.x
        );
    } else if (uniforms.matrix == 2u) { // Rec.2020 non-constant luminance
        rgb = float3(
            y + 1.4746f * chroma.y,
            y - 0.164553f * chroma.x - 0.571353f * chroma.y,
            y + 1.8814f * chroma.x
        );
    } else { // Rec.709
        rgb = float3(
            y + 1.5748f * chroma.y,
            y - 0.1873f * chroma.x - 0.4681f * chroma.y,
            y + 1.8556f * chroma.x
        );
    }
    // The conversion matrix produces gamma-encoded Rec.709. Core Image performs
    // the explicit conversion into the engine's linear working space afterwards.
    outputTexture.write(half4(half3(clamp(rgb, 0.0f, 1.0f)), half(1.0f)), gid);
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
    float2 halfSize = max(logicalSize * 0.5f - 1.0f / rasterScale, float2(0.5f) / rasterScale);
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

kernel void motionaryEffectKernel(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float2 size = float2(uniforms.size);
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 centered = uv - 0.5f;
    float radial = length(centered) * 2.0f;
    float4 source = inputTexture.sample(linearSampler, uv);
    float alpha = source.a;
    float3 color = unpremultiplied(source);
    float p0 = uniforms.parameters.x;
    float p1 = uniforms.parameters.y;
    float p2 = uniforms.parameters.z;

    switch (uniforms.effectKind) {
        case 0u: { // Prism Split
            float edge = smoothstep(max(0.05f, 0.78f - p1 * 0.55f), 1.15f, radial);
            float2 shift = normalize(centered + float2(0.0001f)) * ((0.5f + p0 * 18.0f) / size) * edge;
            float4 redSample = inputTexture.sample(linearSampler, uv + shift);
            float4 blueSample = inputTexture.sample(linearSampler, uv - shift);
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
            float3 left = unpremultiplied(inputTexture.sample(linearSampler, uv + float2(drift + channelShift, 0.0f)));
            float3 right = unpremultiplied(inputTexture.sample(linearSampler, uv + float2(drift - channelShift, 0.0f)));
            float3 middle = unpremultiplied(inputTexture.sample(linearSampler, uv + float2(drift, 0.0f)));
            float scanline = sin((float(gid.y) + 0.5f) * 3.14159265f) * (0.025f + p1 * 0.10f);
            color = float3(left.r, middle.g, right.b) * (1.0f - scanline);
            break;
        }
        case 2u: { // Bleach Bypass
            float luma = luminance(color);
            float3 silver = mix(color, float3(luma), 0.35f + p1 * 0.62f);
            silver = (silver - 0.5f) * (1.0f + p0 * 1.15f) + 0.5f;
            float detail = luminance(unpremultiplied(inputTexture.sample(linearSampler, uv + float2(1.0f / size.x, 0.0f))))
                + luminance(unpremultiplied(inputTexture.sample(linearSampler, uv - float2(1.0f / size.x, 0.0f))))
                + luminance(unpremultiplied(inputTexture.sample(linearSampler, uv + float2(0.0f, 1.0f / size.y))))
                + luminance(unpremultiplied(inputTexture.sample(linearSampler, uv - float2(0.0f, 1.0f / size.y))))
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
            color = mix(color, float3(luma), p2 * 0.10f);
            color += float3(0.055f + p1 * 0.035f, 0.018f, -0.025f) * smoothstep(0.3f, 1.0f, luma);
            color = mix(color, sqrt(max(color, float3(0.0f))), p0 * 0.15f);
            color = saturation(color, 0.92f + p2 * 0.12f);
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
            color += noise * (0.015f + p0 * 0.095f) * lumaWeight;
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
            float2 shift = direction * edge * (0.4f + p0 * 12.0f) / size;
            float4 redSample = inputTexture.sample(linearSampler, uv + shift);
            float4 blueSample = inputTexture.sample(linearSampler, uv - shift);
            color.r = unpremultiplied(redSample).r;
            color.b = unpremultiplied(blueSample).b;
            alpha = max(alpha, max(redSample.a, blueSample.a));
            break;
        }
        case 11u: { // Barrel / pincushion warp
            float r2 = dot(centered, centered);
            float strength = p0 * 0.42f;
            float2 warped = centered * (1.0f + strength * r2 * 4.0f);
            float falloff = 1.0f - smoothstep(0.72f + p1 * 0.18f, 1.18f, length(warped) * 2.0f);
            float4 warpedSample = inputTexture.sample(linearSampler, warped + 0.5f);
            color = unpremultiplied(warpedSample);
            alpha = warpedSample.a * falloff;
            break;
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
    constant MotionaryEffectUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uniforms.size)) { return; }
    float4 source = sourceTexture.read(gid);
    float4 glow = glowTexture.read(gid);
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
        strength = 1.15f;
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
