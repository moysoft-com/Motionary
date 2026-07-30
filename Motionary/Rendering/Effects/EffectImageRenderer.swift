// Standalone facade for effect thumbnails and focused image rendering. It uses
// the exact same module registry and Metal frame graph as AVFoundation.

import CoreImage
import UIKit

enum EffectImageRenderer {
    private static let renderer = Result { try MetalFrameRenderer() }

    static func render(
        _ stack: EffectStack,
        to image: CIImage,
        at time: Double,
        renderScale: CGFloat
    ) -> CIImage {
        do {
            return try renderer.get().renderEffectsSynchronously(
                stack,
                to: image,
                at: time,
                renderScale: renderScale
            )
        } catch {
            EffectRenderDiagnostics.shared.report(EffectRenderDiagnostic(
                severity: .error,
                moduleID: "standalone-preview",
                effectID: UUID(),
                message: error.localizedDescription
            ))
            return image
        }
    }
}

enum EffectThumbnailRenderer {
    private static let outputContext = CIContext(options: [.cacheIntermediates: false])
    private static let lock = NSLock()
    private static var cachedInput: CIImage?

    static func preview(for moduleID: EffectModuleID, scale: CGFloat = 2) -> UIImage? {
        guard let descriptor = EffectRegistry.shared.descriptor(for: moduleID),
            var effect = EffectRegistry.shared.makeEffect(moduleID: moduleID),
            let input = normalizedPreviewInput()
        else { return nil }
        effect.mix = AnimatableProperty(baseValue: descriptor.previewMix)
        for parameter in descriptor.parameters {
            effect.parameters[parameter.id.rawValue] = EffectParameterState(
                baseValue: parameter.previewValue
            )
        }
        let output = EffectImageRenderer.render(
            EffectStack(effects: [effect]),
            to: input,
            at: 0,
            renderScale: max(scale, 1)
        )
        return previewImage(from: output, extent: input.extent, scale: scale)
    }

    static func originalPreview(scale: CGFloat = 2) -> UIImage? {
        guard let input = normalizedPreviewInput() else { return nil }
        return previewImage(from: input, extent: input.extent, scale: scale)
    }

    private static func normalizedPreviewInput() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedInput { return cachedInput }
        guard let uiImage = UIImage(named: "EffectsShowcase"),
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
        cachedInput = normalized
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
