import CoreImage
import Foundation
import simd

/// Spatial modules share the same sampling, color space and GPU resource path.
struct SpatialEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID
    let kind: MotionaryMetalEffectKind

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        func value(_ id: EffectParameterID) -> Float { Float(scalar(id, in: effect, at: context.clipTime)) }
        func radians(_ id: EffectParameterID) -> Float {
            Float(cyclicDegrees(id, in: effect, at: context.clipTime) * .pi / 180)
        }
        var center = SIMD2<Float>(0.5, 0.5)
        if case .point(let point)? = EffectRegistry.shared.resolvedValue(for: .center, in: effect, at: context.clipTime) {
            // UI coordinates start at the top, Core Image coordinates at the bottom.
            center = SIMD2(Float(point.x), 1 - Float(point.y))
        }
        let parameters: SIMD4<Float>
        switch kind {
        case .waveWarp: parameters = SIMD4(value(.amount), value(.wavelength), radians(.angle), value(.speed))
        // Twist is an amount, not a cyclic orientation: full turns still deform
        // points with partial radial influence and must not be discarded.
        case .twirl: parameters = SIMD4(Float(scalar(.angle, in: effect, at: context.clipTime) * (.pi / 180)), value(.radius), 0, 0)
        case .pixelate: parameters = SIMD4(value(.amount), 0, 0, 0)
        case .posterize: parameters = SIMD4(value(.levels), 0, 0, 0)
        case .kaleidoscope: parameters = SIMD4(value(.segments), radians(.angle), 0, 0)
        case .displacementMap: parameters = SIMD4(value(.amount), value(.frequency), value(.speed), value(.detail))
        default: throw MetalRenderingError.unavailableEffect(moduleID.rawValue)
        }
        return try MetalEffectSupport.renderSinglePass(image, kind: kind, parameters: parameters,
            center: center, margin: 0, effect: effect, context: context, resources: resources)
    }
}

/// Core Image's optical kernels keep long blurs smooth at export resolution.
/// Their infinite input extension is selected from the same internal policy
/// used by Metal samplers; the output remains in the authored source bounds.
struct OpticalBlurEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let amount = scalar(.amount, in: effect, at: context.clipTime)
        guard amount > 0.00001 else { return EffectRenderResult(image: image) }
        let extended: CIImage
        switch EffectRegistry.shared.descriptor(for: moduleID)?.renderConfiguration.edgeMode ?? .transparent {
        case .transparent: extended = image
        case .clamp: extended = image.clampedToExtent()
        case .repeatTile: extended = image.applyingFilter("CIAffineTile")
        case .unfold:
            // Core Image has no CIAffineMirrorTile filter. Build a reflected
            // 2×2 period, then repeat that finite tile in both directions.
            let bounds = image.extent
            let horizontal = image.transformed(by: CGAffineTransform(
                a: -1, b: 0, c: 0, d: 1, tx: 2 * bounds.maxX, ty: 0
            ))
            let row = horizontal.composited(over: image)
                .cropped(to: CGRect(x: bounds.minX, y: bounds.minY,
                    width: bounds.width * 2, height: bounds.height))
            let vertical = row.transformed(by: CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * bounds.maxY
            ))
            extended = vertical.composited(over: row)
                .cropped(to: CGRect(x: bounds.minX, y: bounds.minY,
                    width: bounds.width * 2, height: bounds.height * 2))
                .applyingFilter("CIAffineTile")
        }
        let output: CIImage
        if moduleID == .directionalBlur {
            output = extended.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: amount * min(image.extent.width, image.extent.height) * 0.5,
                kCIInputAngleKey: cyclicDegrees(.angle, in: effect, at: context.clipTime) * .pi / 180,
            ])
        } else {
            var center = EffectPoint(x: 0.5, y: 0.5)
            if case .point(let point)? = EffectRegistry.shared.resolvedValue(for: .center, in: effect, at: context.clipTime) {
                center = point
            }
            output = extended.applyingFilter("CIZoomBlur", parameters: [
                kCIInputAmountKey: amount * 100,
                kCIInputCenterKey: CIVector(x: image.extent.minX + image.extent.width * center.x,
                    y: image.extent.minY + image.extent.height * (1 - center.y)),
            ])
        }
        // Optical kernels can accumulate slightly non-opaque alpha even with
        // an opaque tiled input. Preserve the authored layer alpha, including
        // foreground cutouts, rather than dimming it during compositing.
        let opaque = output.unpremultiplyingAlpha().settingAlphaOne(in: image.extent)
        let masked = opaque.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: image
        ])
        return EffectRenderResult(image: masked.cropped(to: image.extent))
    }
}

struct DuotoneEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .duotone

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        func color(_ id: EffectParameterID) -> RGBAColor {
            guard case .color(let color)? = EffectRegistry.shared.resolvedValue(for: id, in: effect, at: context.clipTime)
            else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 1) }
            return color
        }
        let shadow = color(.shadowColor), highlight = color(.highlightColor)
        func vector(_ color: RGBAColor) -> SIMD4<Float> {
            SIMD4(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha))
        }
        let graded = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 + scalar(.contrast, in: effect, at: context.clipTime) * 1.5,
        ])
        return try MetalEffectSupport.renderSinglePass(graded, kind: .duotone,
            parameters: vector(shadow), secondaryParameters: vector(highlight), margin: 0,
            effect: effect, context: context, resources: resources)
    }
}

struct EchoTrailsEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .echoTrails

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let count = min(max(Int(scalar(.samples, in: effect, at: context.clipTime).rounded()), 1), 6)
        let spacing = scalar(.spacing, in: effect, at: context.clipTime)
        let decay = scalar(.decay, in: effect, at: context.clipTime)
        let drift = scalar(.drift, in: effect, at: context.clipTime) * image.extent.width
        var output = image
        var totalWeight = 1.0
        for index in 1...count {
            let weight = pow(decay, Double(index))
            guard weight > 0.0001 else { continue }
            let time = context.clipTime - Double(index) * spacing
            guard time >= 0 || context.temporalSource == nil else { continue }
            var historical: CIImage
            if let source = context.temporalSource {
                historical = try source.image(at: max(time, 0),
                    fitting: context.temporalSourceExtent ?? image.extent, quality: context.quality)
            } else { historical = image }
            if context.temporalSource != nil {
                let pastContext = EffectRenderContext(compositionTime: context.compositionTime - Double(index) * spacing,
                    clipTime: time, frameIndex: context.frameIndex - Int64((Double(index) * spacing / max(context.frameDuration, 0.0001)).rounded()),
                    itemID: context.itemID, renderScale: context.renderScale, quality: context.quality)
                historical = try EffectRenderRegistry.shared.render(context.temporalPrefix, to: historical,
                    context: pastContext, resources: resources, failurePolicy: .failOnUnavailableEffects)
                // Never reintroduce the removed background around a foreground layer.
                let sourceAlpha = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                historical = historical.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                    kCIInputMaskImageKey: sourceAlpha,
                ])
            }
            let shifted = historical.transformed(by: CGAffineTransform(translationX: drift * Double(index), y: 0))
            // Normalized accumulation preserves brightness and alpha on opaque input.
            let amount = weight / (totalWeight + weight)
            output = output.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: shifted.composited(over: image).cropped(to: image.extent),
                kCIInputTimeKey: amount,
            ]).cropped(to: image.extent)
            totalWeight += weight
        }
        return EffectRenderResult(image: output)
    }
}

struct CreativeEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID
    let kind: MotionaryMetalEffectKind

    func render(
        _ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        func v(_ id: EffectParameterID) -> Float { Float(scalar(id, in: effect, at: context.clipTime)) }
        func angle() -> Float { Float(cyclicDegrees(.angle, in: effect, at: context.clipTime) * .pi / 180) }
        func color(_ id: EffectParameterID) -> SIMD4<Float> {
            guard case .color(let c)? = EffectRegistry.shared.resolvedValue(for: id, in: effect, at: context.clipTime)
            else { return SIMD4(1, 1, 1, 1) }
            return SIMD4(Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
        }
        var p = SIMD4<Float>.zero
        var q = SIMD4<Float>.zero
        var extra = SIMD4<Float>(1, 1, 1, 1)
        switch kind {
        case .lightSweep:
            p = SIMD4(v("position"), angle(), v("width"), v(.amount))
            q = color("tintColor"); extra.x = q.w; q.w = v(.speed)
        case .ribbedGlass:
            p = SIMD4(v(.wavelength), v(.amount), angle(), v(.offset))
        case .dither, .halftone:
            p = color(.shadowColor); q = color(.highlightColor)
            extra = SIMD4(p.w, q.w, 1, 1)
            // Keep palette opacity independent of pattern geometry.
            p.w = v(.amount); q.w = v(.contrast)
        case .colorSplash:
            p = SIMD4(v("tolerance"), v(.softness), v(.saturation), 0)
            q = color("targetColor")
        case .neonEdges:
            p = SIMD4(v("width"), v(.threshold), v(.amount), v("background"))
            q = color("tintColor")
        default: throw MetalRenderingError.unavailableEffect(moduleID.rawValue)
        }
        let result = try MetalEffectSupport.renderSinglePass(
            image, kind: kind, parameters: p,
            center: SIMD2(angle(), 0), secondaryParameters: q, additionalParameters: extra, orientation: angle(),
            margin: 0,
            effect: effect, context: context, resources: resources)
        guard kind == .neonEdges else { return result }
        let glow = result.image.applyingFilter(
            "CIBloom",
            parameters: [
                kCIInputRadiusKey: max(1, Double(v("width")) * min(image.extent.width, image.extent.height) * 5),
                kCIInputIntensityKey: Double(v(.amount)) * 1.5
            ]
        ).cropped(to: image.extent)
        // Bloom must not paint into transparent parts of a cutout layer.
        let clear = CIImage(color: .clear).cropped(to: image.extent)
        let opaqueGlow = glow.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        let masked = opaqueGlow.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: image
            ])
        return EffectRenderResult(image: masked.cropped(to: image.extent))
    }
}
