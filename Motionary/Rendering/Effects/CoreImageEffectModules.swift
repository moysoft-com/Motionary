import CoreImage
import Foundation

private enum CoreImageEffectSupport {
    static func filter(
        _ name: String,
        input: CIImage,
        configure: (CIFilter) -> Void = { _ in }
    ) -> CIImage {
        guard let filter = CIFilter(name: name) else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        configure(filter)
        return filter.outputImage ?? input
    }

    static func sourceAlpha(_ source: CIImage) -> CIImage {
        filter("CIColorMatrix", input: source) { filter in
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        }
    }

    static func clippedToSourceAlpha(_ image: CIImage, source: CIImage) -> CIImage {
        let extent = source.extent
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        guard let filter = CIFilter(name: "CIBlendWithAlphaMask") else {
            return image.cropped(to: extent)
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        filter.setValue(sourceAlpha(source), forKey: kCIInputMaskImageKey)
        return (filter.outputImage ?? image).cropped(to: extent)
    }
}

struct SepiaEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .sepia

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let warmth = scalar(.warmth, in: effect, at: context.clipTime)
        let contrast = scalar(.contrast, in: effect, at: context.clipTime)
        let sepia = CoreImageEffectSupport.filter("CISepiaTone", input: image) {
            $0.setValue(0.45 + warmth * 0.55, forKey: kCIInputIntensityKey)
        }
        let graded = CoreImageEffectSupport.filter("CIColorControls", input: sepia) {
            $0.setValue(1 + contrast * 0.35, forKey: kCIInputContrastKey)
            $0.setValue(0.9 + warmth * 0.18, forKey: kCIInputSaturationKey)
        }
        return EffectRenderResult(image: graded.cropped(to: image.extent))
    }
}

struct NoirEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .noir

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let contrast = scalar(.contrast, in: effect, at: context.clipTime)
        let grain = scalar(.grain, in: effect, at: context.clipTime)
        var output = CoreImageEffectSupport.filter("CIPhotoEffectNoir", input: image)
        output = CoreImageEffectSupport.filter("CIColorControls", input: output) {
            $0.setValue(1 + contrast * 0.65, forKey: kCIInputContrastKey)
            $0.setValue(-contrast * 0.035, forKey: kCIInputBrightnessKey)
        }
        if grain > 0.000_1,
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage
        {
            let seed = context.deterministicSeed(storedSeed: effect.seed, effectID: effect.id)
            let translatedNoise = noise
                .transformed(by: CGAffineTransform(
                    translationX: CGFloat(seed & 1023),
                    y: CGFloat((seed >> 10) & 1023)
                ))
                .cropped(to: image.extent)
            let monochrome = CoreImageEffectSupport.filter("CIColorControls", input: translatedNoise) {
                $0.setValue(0, forKey: kCIInputSaturationKey)
                $0.setValue(0.5 + grain * 0.45, forKey: kCIInputContrastKey)
                $0.setValue(-0.18, forKey: kCIInputBrightnessKey)
            }
            if let overlay = CIFilter(name: "CISoftLightBlendMode") {
                overlay.setValue(monochrome, forKey: kCIInputImageKey)
                overlay.setValue(output, forKey: kCIInputBackgroundImageKey)
                output = overlay.outputImage ?? output
            }
        }
        return EffectRenderResult(
            image: CoreImageEffectSupport.clippedToSourceAlpha(output, source: image)
        )
    }
}

struct ChromeEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .chrome

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let color = scalar(.saturation, in: effect, at: context.clipTime)
        let contrast = scalar(.contrast, in: effect, at: context.clipTime)
        let chrome = CoreImageEffectSupport.filter("CIPhotoEffectChrome", input: image)
        let graded = CoreImageEffectSupport.filter("CIColorControls", input: chrome) {
            $0.setValue(1 + color * 0.35, forKey: kCIInputSaturationKey)
            $0.setValue(1 + contrast * 0.45, forKey: kCIInputContrastKey)
        }
        return EffectRenderResult(image: graded.cropped(to: image.extent))
    }
}

struct BlurEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .blur

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let normalizedRadius = scalar(.radius, in: effect, at: context.clipTime)
        let radius = max(CGFloat(normalizedRadius) * 36 * context.renderScale, 0)
        guard radius > 0.05 else { return EffectRenderResult(image: image) }
        let margin = ceil(radius * 2.6)
        let expandedExtent = image.extent.insetBy(dx: -margin, dy: -margin)
        let blurred = CoreImageEffectSupport.filter("CIGaussianBlur", input: image) {
            $0.setValue(radius, forKey: kCIInputRadiusKey)
        }
        return EffectRenderResult(
            image: blurred.cropped(to: expandedExtent),
            requiredMargin: margin
        )
    }
}

struct VignetteEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .vignette

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let radius = scalar(.radius, in: effect, at: context.clipTime)
        let softness = scalar(.softness, in: effect, at: context.clipTime)
        let output = CoreImageEffectSupport.filter("CIVignetteEffect", input: image) {
            $0.setValue(CIVector(x: image.extent.midX, y: image.extent.midY), forKey: kCIInputCenterKey)
            $0.setValue(1.8, forKey: kCIInputIntensityKey)
            $0.setValue(min(image.extent.width, image.extent.height) * (0.18 + radius * 0.32), forKey: kCIInputRadiusKey)
            $0.setValue(1 - softness * 0.75, forKey: "inputFalloff")
        }
        return EffectRenderResult(image: output.cropped(to: image.extent))
    }
}

struct CleanSharpenEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .cleanSharpen

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let sharpness = scalar(.sharpness, in: effect, at: context.clipTime)
        let radius = scalar(.radius, in: effect, at: context.clipTime)
        let sharpened = CoreImageEffectSupport.filter("CIUnsharpMask", input: image) {
            $0.setValue((0.45 + radius * 2.2) * Double(context.renderScale), forKey: kCIInputRadiusKey)
            $0.setValue(0.2 + sharpness * 1.05, forKey: kCIInputIntensityKey)
        }
        return EffectRenderResult(image: sharpened.cropped(to: image.extent))
    }
}


struct InvertEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .invert
    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        EffectRenderResult(image: CoreImageEffectSupport.filter("CIColorInvert", input: image).cropped(to: image.extent))
    }
}

struct HorizontalMirrorEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .horizontalMirror
    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                          tx: image.extent.minX + image.extent.maxX, ty: 0)
        return EffectRenderResult(image: image.transformed(by: transform).cropped(to: image.extent))
    }
}

/// Each time slot has a deterministic duration and strength, independent of render order.
enum FlashSampling {
    static func intensity(time: Double, frequency: Double, duration: Double, seed: UInt64) -> Double {
        guard time.isFinite, frequency.isFinite, duration.isFinite, frequency > 0 else { return 0 }
        let position = min(max(time, 0) * frequency, 1e12)
        let index = UInt64(position.rounded(.down))
        func random(_ salt: UInt64) -> Double {
            var value = seed &+ index &* 0x9e3779b97f4a7c15 &+ salt
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return Double(value >> 11) / Double(UInt64(1) << 53)
        }
        let width = min(duration * frequency * (0.7 + 0.6 * random(1)), 0.9)
        guard position - floor(position) < width else { return 0 }
        return 0.65 + 0.35 * random(2)
    }
}

struct FlashEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .flash
    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let frequency = scalar(.frequency, in: effect, at: context.clipTime)
        let duration = scalar("duration", in: effect, at: context.clipTime)
        let amount = scalar(.amount, in: effect, at: context.clipTime)
        let strength = amount * FlashSampling.intensity(time: context.clipTime, frequency: frequency,
                                                        duration: duration, seed: effect.seed)
        guard strength > 0, case .color(let color)? = EffectRegistry.shared.resolvedValue(
            for: "flashColor", in: effect, at: context.clipTime) else { return EffectRenderResult(image: image) }
        let overlay = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue,
                                              alpha: color.alpha * strength)).cropped(to: image.extent)
        let output = CoreImageEffectSupport.filter("CISourceAtopCompositing", input: overlay) {
            $0.setValue(image, forKey: kCIInputBackgroundImageKey)
        }
        return EffectRenderResult(image: output.cropped(to: image.extent))
    }
}
