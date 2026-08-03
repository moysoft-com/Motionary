import CoreImage
import Foundation
import Metal

enum MetalLayerCompositor {
    static func blend(
        foreground: CIImage,
        background: CIImage,
        in extent: CGRect,
        mode: BlendMode,
        intensity: Double,
        resources: MetalFrameResources
    ) throws -> CIImage {
        let extent = pixelAligned(extent)
        let clampedIntensity = min(max(intensity, 0), 1)

        // The normal blend equation is exactly Core Image source-over. Keeping
        // it in the lazy CI graph avoids two full-frame FP16 rasterizations,
        // one scratch output and one compute encoder for the overwhelmingly
        // common layer path. A zero-intensity artistic blend also resolves to
        // the same source-over result.
        if mode == .normal || clampedIntensity <= 0.000_001 {
            return foreground
                .composited(over: background)
                .cropped(to: extent)
        }

        let foregroundTexture = try rasterize(foreground, in: extent, resources: resources)
        let backgroundTexture = try rasterize(background, in: extent, resources: resources)
        let outputTexture = try resources.makeScratchTexture(
            width: foregroundTexture.width,
            height: foregroundTexture.height
        )
        let pipeline = try resources.owner.pipeline(named: "motionaryBlendKernel")
        guard let encoder = resources.commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        encoder.label = "\(mode.rawValue) layer blend"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(foregroundTexture, index: 0)
        encoder.setTexture(backgroundTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        let uniforms = try resources.writeUniforms(MotionaryEffectUniforms(
            size: SIMD2(UInt32(outputTexture.width), UInt32(outputTexture.height)),
            effectKind: mode.metalBlendIndex,
            seed: 0,
            time: 0,
            frameIndex: 0,
            direction: .zero,
            parameters: SIMD4(Float(clampedIntensity), 0, 0, 0)
        ))
        encoder.setBuffer(uniforms.buffer, offset: uniforms.offset, index: 0)
        resources.dispatch(
            encoder: encoder,
            pipeline: pipeline,
            width: outputTexture.width,
            height: outputTexture.height
        )
        encoder.endEncoding()
        resources.releaseScratchTexture(foregroundTexture)
        resources.releaseScratchTexture(backgroundTexture)

        guard let image = CIImage(
            mtlTexture: outputTexture,
            options: [.colorSpace: resources.owner.workingColorSpace]
        ) else { throw MetalRenderingError.invalidRenderTarget }
        return image
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
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
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let transparentBase = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: bounds)
        resources.owner.ciContext.render(
            localImage
                .composited(over: transparentBase)
                .cropped(to: bounds),
            to: texture,
            commandBuffer: resources.commandBuffer,
            bounds: bounds,
            colorSpace: resources.owner.workingColorSpace
        )
        return texture
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

private extension BlendMode {
    var metalBlendIndex: UInt32 {
        switch self {
        case .normal: 0
        case .darken: 1
        case .multiply: 2
        case .colorBurn: 3
        case .lighten: 4
        case .screen: 5
        case .colorDodge: 6
        case .overlay: 7
        case .softLight: 8
        case .hardLight: 9
        case .difference: 10
        case .exclusion: 11
        case .hue: 12
        case .saturation: 13
        case .color: 14
        case .luminosity: 15
        }
    }
}
