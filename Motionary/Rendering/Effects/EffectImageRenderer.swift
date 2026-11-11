// Standalone facade for effect thumbnails and focused image rendering. It uses
// the exact same module registry and Metal frame graph as AVFoundation.

import CoreImage
import UIKit

extension EffectModuleDescriptor {
    var hasAnimatedPreview: Bool {
        [.flash, .shake, .cameraWiggle, .zoom, .motionBlur, .waveWarp, .ripple,
         .displacementMap, .lightSweep, .analogGlitch, .fineGrain, .lightLeak, .echoTrails].contains(id)
    }
}

enum EffectImageRenderer {
    private static let renderer = Result { try MetalFrameRenderer() }
    private static let fallbackDiagnosticEffectID = UUID(
        uuidString: "8C76B92C-AF30-4B9E-889A-B296487B57D3"
    )!

    static func diagnosticEffectID(for stack: EffectStack) -> UUID {
        stack.effects.first?.id ?? fallbackDiagnosticEffectID
    }

    static func render(
        _ stack: EffectStack,
        to image: CIImage,
        at time: Double,
        renderScale: CGFloat,
        layerMotion: EffectLayerMotion? = nil
    ) -> CIImage {
        do {
            return try renderer.get().renderEffectsSynchronously(
                stack,
                to: image,
                at: time,
                renderScale: renderScale,
                layerMotion: layerMotion
            )
        } catch {
            EffectRenderDiagnostics.shared.report(EffectRenderDiagnostic(
                severity: .error,
                moduleID: "standalone-preview",
                effectID: diagnosticEffectID(for: stack),
                message: error.localizedDescription
            ))
            return image
        }
    }
}

enum EffectThumbnailRenderer {
    private static let outputContext = CIContext(options: [.cacheIntermediates: false])
    private static let lock = NSLock()
    private static var cachedInputs: [EffectCategory: CIImage] = [:]

    static func preview(for moduleID: EffectModuleID, scale: CGFloat = 2, at time: Double = 0,
                        animated: Bool = false) -> UIImage? {
        if moduleID == .depthMap {
            guard let image = UIImage(named: "DepthMapPreview")?.cgImage else { return nil }
            let input = CIImage(cgImage: image)
            let size: CGFloat = 320
            let normalized = input.transformed(by: CGAffineTransform(
                scaleX: size / input.extent.width, y: size / input.extent.height))
            return previewImage(from: normalized, extent: CGRect(x: 0, y: 0, width: size, height: size), scale: scale)
        }
        guard let descriptor = EffectRegistry.shared.descriptor(for: moduleID),
            var effect = EffectRegistry.shared.makeEffect(moduleID: moduleID,
                id: UUID(uuidString: "28977F36-7EB7-459A-8D78-66D86927D612")!),
            var input = normalizedPreviewInput(for: descriptor.category)
        else { return nil }
        effect.seed = EffectInstance.deterministicSeed(for: effect.id)
        effect.mix = AnimatableProperty(baseValue: descriptor.previewMix)
        for parameter in descriptor.parameters {
            effect.parameters[parameter.id.rawValue] = EffectParameterState(
                baseValue: parameter.previewValue
            )
        }
        var stack: [EffectInstance] = []
        var layerMotion: EffectLayerMotion?
        if animated {
            input = input.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            if moduleID == .zoom {
                effect.parameters["mode"] = EffectParameterState(baseValue: .option("Pulse"))
                effect.parameters["startScale"] = EffectParameterState(baseValue: .scalar(1))
                effect.parameters["duration"] = EffectParameterState(baseValue: .scalar(3))
            }
            if moduleID == .echoTrails {
                let bounds = input.extent
                let t = time
                input = input.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
                    .transformed(by: CGAffineTransform(scaleX: 1.3, y: 1.3))
                    .transformed(by: CGAffineTransform(translationX: bounds.midX + sin(t * 2 * .pi / 3) * bounds.width * 0.12,
                        y: bounds.midY))
                    .cropped(to: bounds)
            }
        }
        let previewTime = animated ? time : 0.7
        if moduleID == .motionBlur {
            let previewBounds = input.extent
            let transform = ClipTransform(positionX: AnimatableProperty(baseValue: 0, keyframes: [
                Keyframe(time: 0, value: -0.5), Keyframe(time: 1, value: 0.5),
                Keyframe(time: 2, value: -0.5)
            ]))
            layerMotion = EffectLayerMotion(transform: transform, canvasSize: input.extent.size, isGenerated: false)
            input = input.transformed(by: CGAffineTransform(translationX:
                transform.positionX.value(at: previewTime) * input.extent.width * 0.5, y: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: previewBounds.width, height: previewBounds.height))
        }
        stack.append(effect)
        let output = EffectImageRenderer.render(
            EffectStack(effects: stack),
            to: input,
            at: previewTime,
            renderScale: max(scale, 1),
            layerMotion: layerMotion
        )
        return previewImage(from: output, extent: input.extent, scale: scale)
    }

    static func originalPreview(for moduleID: EffectModuleID, scale: CGFloat = 2) -> UIImage? {
        guard let category = EffectRegistry.shared.descriptor(for: moduleID)?.category,
            let input = normalizedPreviewInput(for: category)
        else { return nil }
        return previewImage(from: input, extent: input.extent, scale: scale)
    }

    private static func normalizedPreviewInput(for category: EffectCategory) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedInput = cachedInputs[category] { return cachedInput }
        guard let uiImage = UIImage(named: category.showcaseImageAssetName),
            let cgImage = uiImage.cgImage
        else { return nil }
        let square = centerCropSquare(CIImage(cgImage: cgImage))
        let targetSize: CGFloat = 320
        let normalized = square
            .transformed(by: CGAffineTransform(
                translationX: -square.extent.minX,
                y: -square.extent.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: targetSize / square.extent.width,
                y: targetSize / square.extent.height
            ))
            .cropped(to: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        cachedInputs[category] = normalized
        return normalized
    }

    private static func centerCropSquare(_ image: CIImage) -> CIImage {
        let side = min(image.extent.width, image.extent.height)
        return image.cropped(to: CGRect(
            x: image.extent.midX - side * 0.5,
            y: image.extent.midY - side * 0.5,
            width: side,
            height: side
        ))
    }

    private static func previewImage(from image: CIImage, extent: CGRect, scale: CGFloat) -> UIImage? {
        let upright = image
            .cropped(to: extent)
            .transformed(
                by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            )
            .cropped(to: CGRect(origin: .zero, size: extent.size))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImage = outputContext.createCGImage(
                upright,
                from: upright.extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        else { return nil }
        return UIImage(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
    }
}
