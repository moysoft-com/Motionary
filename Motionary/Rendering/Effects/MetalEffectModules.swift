import CoreImage
import Foundation
import Metal
import simd

private enum MetalEffectSupport {
    static func renderSinglePass(
        _ image: CIImage,
        kind: MotionaryMetalEffectKind,
        parameters: SIMD4<Float>,
        margin: CGFloat,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let extent = pixelAligned(image.extent.insetBy(dx: -margin, dy: -margin))
        let inputTexture = try rasterize(image, in: extent, resources: resources)
        let outputTexture = try resources.makeScratchTexture(
            width: inputTexture.width,
            height: inputTexture.height
        )
        let uniforms = MotionaryEffectUniforms(
            size: SIMD2(UInt32(inputTexture.width), UInt32(inputTexture.height)),
            effectKind: kind.rawValue,
            seed: context.deterministicSeed(storedSeed: effect.seed, effectID: effect.id),
            time: Float(context.compositionTime),
            frameIndex: Float(context.frameIndex),
            direction: .zero,
            parameters: parameters
        )
        try encode(
            pipelineName: "motionaryEffectKernel",
            textures: [(inputTexture, 0), (outputTexture, 1)],
            uniforms: uniforms,
            width: outputTexture.width,
            height: outputTexture.height,
            label: EffectRegistry.shared.descriptor(for: effect.moduleID)?.name ?? effect.moduleID.rawValue,
            resources: resources
        )
        resources.releaseScratchTexture(inputTexture)
        return EffectRenderResult(
            image: try makeImage(from: outputTexture, positionedAt: extent, resources: resources),
            requiredMargin: margin
        )
    }

    static func renderGlow(
        _ image: CIImage,
        kind: MotionaryMetalEffectKind,
        radius: Float,
        threshold: Float,
        tint: Float,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        let radius = max(radius * context.quality.blurScale, 0.5)
        let margin = ceil(CGFloat(radius) * (kind == .anamorphicFlare ? 1.25 : 2.5))
        let extent = pixelAligned(image.extent.insetBy(dx: -margin, dy: -margin))
        let sourceTexture = try rasterize(image, in: extent, resources: resources)
        let highlights = try resources.makeScratchTexture(
            width: sourceTexture.width,
            height: sourceTexture.height
        )
        let horizontal = try resources.makeScratchTexture(
            width: sourceTexture.width,
            height: sourceTexture.height
        )
        let size = SIMD2(UInt32(sourceTexture.width), UInt32(sourceTexture.height))
        let seed = context.deterministicSeed(storedSeed: effect.seed, effectID: effect.id)
        let commonParameters = SIMD4(radius, min(max(threshold, 0), 1), min(max(tint, 0), 1), 0)

        try encode(
            pipelineName: "motionaryHighlightKernel",
            textures: [(sourceTexture, 0), (highlights, 1)],
            uniforms: MotionaryEffectUniforms(
                size: size,
                effectKind: kind.rawValue,
                seed: seed,
                time: Float(context.compositionTime),
                frameIndex: Float(context.frameIndex),
                direction: .zero,
                parameters: commonParameters
            ),
            width: sourceTexture.width,
            height: sourceTexture.height,
            label: "Highlight selection",
            resources: resources
        )

        try encode(
            pipelineName: "motionarySeparableBlurKernel",
            textures: [(highlights, 0), (horizontal, 1)],
            uniforms: MotionaryEffectUniforms(
                size: size,
                effectKind: kind.rawValue,
                seed: seed,
                time: Float(context.compositionTime),
                frameIndex: Float(context.frameIndex),
                direction: SIMD2(1, 0),
                parameters: commonParameters
            ),
            width: sourceTexture.width,
            height: sourceTexture.height,
            label: "Horizontal glow blur",
            resources: resources
        )
        // The horizontal pass is ordered after highlight selection, so the
        // highlight surface can become the vertical-pass destination.
        resources.releaseScratchTexture(highlights)
        let blurred = try resources.makeScratchTexture(
            width: sourceTexture.width,
            height: sourceTexture.height
        )

        var verticalParameters = commonParameters
        if kind == .anamorphicFlare {
            verticalParameters.x = min(max(radius * 0.025, 1), 3)
        }
        try encode(
            pipelineName: "motionarySeparableBlurKernel",
            textures: [(horizontal, 0), (blurred, 1)],
            uniforms: MotionaryEffectUniforms(
                size: size,
                effectKind: kind.rawValue,
                seed: seed,
                time: Float(context.compositionTime),
                frameIndex: Float(context.frameIndex),
                direction: SIMD2(0, 1),
                parameters: verticalParameters
            ),
            width: sourceTexture.width,
            height: sourceTexture.height,
            label: "Vertical glow blur",
            resources: resources
        )
        resources.releaseScratchTexture(horizontal)
        let output = try resources.makeScratchTexture(
            width: sourceTexture.width,
            height: sourceTexture.height
        )

        try encode(
            pipelineName: "motionaryGlowCompositeKernel",
            textures: [(sourceTexture, 0), (blurred, 1), (output, 2)],
            uniforms: MotionaryEffectUniforms(
                size: size,
                effectKind: kind.rawValue,
                seed: seed,
                time: Float(context.compositionTime),
                frameIndex: Float(context.frameIndex),
                direction: .zero,
                parameters: commonParameters
            ),
            width: sourceTexture.width,
            height: sourceTexture.height,
            label: "Glow composite",
            resources: resources
        )
        resources.releaseScratchTexture(sourceTexture)
        resources.releaseScratchTexture(blurred)

        return EffectRenderResult(
            image: try makeImage(from: output, positionedAt: extent, resources: resources),
            requiredMargin: margin
        )
    }

    private static func rasterize(
        _ image: CIImage,
        in extent: CGRect,
        resources: MetalFrameResources
    ) throws -> MTLTexture {
        let width = max(Int(extent.width.rounded(.up)), 1)
        let height = max(Int(extent.height.rounded(.up)), 1)
        let texture = try resources.makeScratchTexture(width: width, height: height)
        let localImage = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        resources.owner.ciContext.render(
            localImage,
            to: texture,
            commandBuffer: resources.commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: resources.owner.workingColorSpace
        )
        return texture
    }

    private static func makeImage(
        from texture: MTLTexture,
        positionedAt extent: CGRect,
        resources: MetalFrameResources
    ) throws -> CIImage {
        guard let image = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: resources.owner.workingColorSpace]
        ) else { throw MetalRenderingError.invalidRenderTarget }
        return image
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private static func encode(
        pipelineName: String,
        textures: [(MTLTexture, Int)],
        uniforms: MotionaryEffectUniforms,
        width: Int,
        height: Int,
        label: String,
        resources: MetalFrameResources
    ) throws {
        let pipeline = try resources.owner.pipeline(named: pipelineName)
        guard let encoder = resources.commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        encoder.label = label
        encoder.setComputePipelineState(pipeline)
        for (texture, index) in textures {
            encoder.setTexture(texture, index: index)
        }
        let uniformAllocation = try resources.writeUniforms(uniforms)
        encoder.setBuffer(uniformAllocation.buffer, offset: uniformAllocation.offset, index: 0)
        resources.dispatch(
            encoder: encoder,
            pipeline: pipeline,
            width: width,
            height: height
        )
        encoder.endEncoding()
    }

    private static func pixelAligned(_ extent: CGRect) -> CGRect {
        CGRect(
            x: floor(extent.minX),
            y: floor(extent.minY),
            width: ceil(extent.maxX) - floor(extent.minX),
            height: ceil(extent.maxY) - floor(extent.minY)
        )
    }
}

struct CinematicBloomEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .cinematicBloom

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let radius = Float((8 + scalar(.radius, in: effect, at: context.clipTime) * 36) * Double(context.renderScale))
        return try MetalEffectSupport.renderGlow(
            image,
            kind: .cinematicBloom,
            radius: radius,
            threshold: Float(scalar(.threshold, in: effect, at: context.clipTime)),
            tint: Float(scalar(.saturation, in: effect, at: context.clipTime)),
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct FilmHalationEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .filmHalation

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let radius = Float((8 + scalar(.radius, in: effect, at: context.clipTime) * 42) * Double(context.renderScale))
        return try MetalEffectSupport.renderGlow(
            image,
            kind: .filmHalation,
            radius: radius,
            threshold: Float(scalar(.threshold, in: effect, at: context.clipTime)),
            tint: Float(scalar(.warmth, in: effect, at: context.clipTime)),
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct PrismSplitEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .prismSplit

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let offset = scalar(.offset, in: effect, at: context.clipTime)
        let margin = ceil(CGFloat(2 + offset * 20) * context.renderScale)
        return try MetalEffectSupport.renderSinglePass(
            image,
            kind: .prismSplit,
            parameters: SIMD4(Float(offset), Float(scalar(.spread, in: effect, at: context.clipTime)), 0, 0),
            margin: margin,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct AnalogGlitchEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .analogGlitch

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let offset = scalar(.offset, in: effect, at: context.clipTime)
        return try MetalEffectSupport.renderSinglePass(
            image,
            kind: .analogGlitch,
            parameters: SIMD4(Float(offset), Float(scalar(.scanlines, in: effect, at: context.clipTime)), 0, 0),
            margin: ceil(CGFloat(4 + offset * 34) * context.renderScale),
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct BleachBypassEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .bleachBypass

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .bleachBypass,
            parameters: SIMD4(
                Float(scalar(.contrast, in: effect, at: context.clipTime)),
                Float(scalar(.saturation, in: effect, at: context.clipTime)),
                Float(scalar(.sharpness, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct CineTealEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .cineTeal

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .cineTeal,
            parameters: SIMD4(
                Float(scalar(.warmth, in: effect, at: context.clipTime)),
                Float(scalar(.saturation, in: effect, at: context.clipTime)),
                Float(scalar(.contrast, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct KodakPrintEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .kodakPrint

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .kodakPrint,
            parameters: SIMD4(
                Float(scalar(.warmth, in: effect, at: context.clipTime)),
                Float(scalar(.fade, in: effect, at: context.clipTime)),
                Float(scalar(.grain, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct PortraSoftEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .portraSoft

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .portraSoft,
            parameters: SIMD4(
                Float(scalar(.softness, in: effect, at: context.clipTime)),
                Float(scalar(.warmth, in: effect, at: context.clipTime)),
                Float(scalar(.saturation, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct CoolFadeEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .coolFade

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .coolFade,
            parameters: SIMD4(
                Float(scalar(.fade, in: effect, at: context.clipTime)),
                Float(scalar(.saturation, in: effect, at: context.clipTime)),
                Float(scalar(.contrast, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct MatteContrastEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .matteContrast

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .matteContrast,
            parameters: SIMD4(
                Float(scalar(.fade, in: effect, at: context.clipTime)),
                Float(scalar(.contrast, in: effect, at: context.clipTime)),
                0,
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct FineGrainEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .fineGrain

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .fineGrain,
            parameters: SIMD4(
                Float(scalar(.grain, in: effect, at: context.clipTime)),
                Float(scalar(.contrast, in: effect, at: context.clipTime)),
                0,
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct SoftGlowEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .softGlow

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let radius = Float((7 + scalar(.radius, in: effect, at: context.clipTime) * 30) * Double(context.renderScale))
        return try MetalEffectSupport.renderGlow(
            image,
            kind: .softGlow,
            radius: radius,
            threshold: Float(scalar(.threshold, in: effect, at: context.clipTime)),
            tint: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct AnamorphicFlareEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .anamorphicFlare

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let radius = Float((20 + scalar(.spread, in: effect, at: context.clipTime) * 80) * Double(context.renderScale))
        return try MetalEffectSupport.renderGlow(
            image,
            kind: .anamorphicFlare,
            radius: radius,
            threshold: Float(scalar(.threshold, in: effect, at: context.clipTime)),
            tint: Float(scalar(.warmth, in: effect, at: context.clipTime)),
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct LightLeakEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .lightLeak

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .lightLeak,
            parameters: SIMD4(
                Float(scalar(.angle, in: effect, at: context.clipTime)),
                Float(scalar(.warmth, in: effect, at: context.clipTime)),
                Float(scalar(.spread, in: effect, at: context.clipTime)),
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct ChromaticAberrationEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .chromaticAberration

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        let offset = scalar(.offset, in: effect, at: context.clipTime)
        return try MetalEffectSupport.renderSinglePass(
            image,
            kind: .chromaticAberration,
            parameters: SIMD4(Float(offset), Float(scalar(.softness, in: effect, at: context.clipTime)), 0, 0),
            margin: ceil(CGFloat(2 + offset * 14) * context.renderScale),
            effect: effect,
            context: context,
            resources: resources
        )
    }
}

struct BarrelWarpEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .barrelWarp

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext, resources: MetalFrameResources) throws -> EffectRenderResult {
        try MetalEffectSupport.renderSinglePass(
            image,
            kind: .barrelWarp,
            parameters: SIMD4(
                Float(scalar(.warp, in: effect, at: context.clipTime)),
                Float(scalar(.softness, in: effect, at: context.clipTime)),
                0,
                0
            ),
            margin: 0,
            effect: effect,
            context: context,
            resources: resources
        )
    }
}
