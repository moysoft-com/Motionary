import CoreImage
import Foundation
import Metal

struct EffectLayerMotion: Sendable {
    let transform: ClipTransform
    let canvasSize: CGSize
    let isGenerated: Bool

    func placement(at time: Double, bounds: CGRect, referenceTime: Double? = nil,
                   components: String = "All") -> CGAffineTransform {
        let reference = referenceTime ?? time
        let positionTime = components == "All" || components.contains("Position") ? time : reference
        let rotationTime = components == "All" || components.contains("Rotation") ? time : reference
        let scaleTime = components == "All" || components.contains("Scale") ? time : reference
        let fit = isGenerated ? 1 : (VideoSourceGeometry.fitScale(sourceSize: bounds.size, inside: canvasSize) ?? 1)
        let scale = transform.scale.value(at: scaleTime)
        return CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(
                scaleX: fit * max(scale.x, 0.001) * (transform.isFlippedHorizontally ? -1 : 1),
                y: fit * max(scale.y, 0.001) * (transform.isFlippedVertically ? -1 : 1)))
            .concatenating(CGAffineTransform(rotationAngle: transform.rotationDegrees.value(at: rotationTime) * .pi / 180))
            .concatenating(CGAffineTransform(
                translationX: canvasSize.width * (0.5 + transform.positionX.value(at: positionTime) * 0.5),
                y: canvasSize.height * (0.5 - transform.positionY.value(at: positionTime) * 0.5)))
    }
}

/// Integrate object transforms and preceding camera-motion effects while keeping
/// the source pixels frozen, so source video never produces temporal ghosting.
struct MotionBlurEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .motionBlur

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let exposure = scalar("shutter", in: effect, at: context.clipTime) / 360 * context.frameDuration
        let motionEffects: Set<EffectModuleID> = [.shake, .cameraWiggle, .zoom]
        let hasEffectMotion = context.temporalPrefix.effects.contains { motionEffects.contains($0.moduleID) }
        guard exposure > 0.000001, context.layerMotion != nil ||
                context.motionScene?.hasAnimatedTransforms == true || hasEffectMotion else {
            return EffectRenderResult(image: image)
        }
        let components: String
        if case .option(let value)? = EffectRegistry.shared.resolvedValue(
            for: "motion", in: effect, at: context.clipTime) { components = value }
        else { components = "All" }
        guard components != "None" else { return EffectRenderResult(image: image) }
        let requested = Int(scalar(.samples, in: effect, at: context.clipTime).rounded())
        let count = min(max(requested, 2), 32)
        let sourceBounds = context.temporalSourceExtent ?? image.extent
        let inverse = context.layerMotion?.placement(at: context.clipTime, bounds: sourceBounds).inverted() ?? .identity
        let transforms = (0..<count).map { index in
            let time = max(context.clipTime - exposure * (Double(index) + 0.5) / Double(count), 0)
            return context.layerMotion?.placement(at: time, bounds: sourceBounds,
                referenceTime: context.clipTime, components: components).concatenating(inverse) ?? .identity
        }
        guard hasEffectMotion || context.motionScene != nil || transforms.contains(where: {
            abs($0.a - 1) + abs($0.d - 1) + abs($0.b) + abs($0.c) + abs($0.tx) + abs($0.ty) > 0.000001
        }) else { return EffectRenderResult(image: image) }
        let outputBounds = transforms.reduce(image.extent) { $0.union(image.extent.applying($1)) }.integral
        let scale: CGFloat = 1
        let downscale = CGAffineTransform(scaleX: scale, y: scale)
        let bounds = outputBounds.applying(downscale).integral
        let surfaces = try (0..<2).map { _ in
            try resources.makeScratchTexture(width: Int(bounds.width), height: Int(bounds.height))
        }
        let protected = resources.activeScratchTextureIDs()
        let transparent = CIImage(color: .clear).cropped(to: bounds)
        var accumulated: CIImage?
        try resources.reusingDisplacementMaps {
            for (index, transform) in transforms.enumerated() {
                let source: CIImage
                let offset = exposure * (Double(index) + 0.5) / Double(count)
                if context.motionScene != nil || hasEffectMotion, let input = context.effectInput {
                    let base = try context.motionScene?.sample(offset, components) ?? input
                    let sampleTime = max(context.clipTime - offset, 0)
                    var sampled = base
                    // Keep non-motion effects at the current time, while evaluating camera
                    // transforms at each shutter sample in their original stack order.
                    for prefixEffect in context.temporalPrefix.effects {
                        let time = motionEffects.contains(prefixEffect.moduleID) ? sampleTime : context.clipTime
                        sampled = try EffectRenderRegistry.shared.render(EffectStack(effects: [prefixEffect]), to: sampled,
                            context: EffectRenderContext(compositionTime: context.compositionTime - (context.clipTime - time),
                                clipTime: time, frameIndex: context.frameIndex, itemID: context.itemID,
                                renderScale: context.renderScale, quality: context.quality,
                                frameDuration: context.frameDuration),
                            resources: resources, failurePolicy: .failOnUnavailableEffects)
                    }
                    source = sampled
                } else { source = image }
                let sample = source.transformed(by: transform.concatenating(downscale))
                    .composited(over: transparent).cropped(to: bounds)
                let blended: CIImage
                if let previous = accumulated {
                    blended = previous.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: sample, kCIInputTimeKey: 1 / Double(index + 1)
                    ]).cropped(to: bounds)
                } else { blended = sample }
                let texture = surfaces[index % 2]
                resources.owner.ciContext.render(blended.transformed(by: CGAffineTransform(
                    translationX: -bounds.minX, y: -bounds.minY)), to: texture,
                    commandBuffer: resources.commandBuffer, bounds: CGRect(origin: .zero, size: bounds.size),
                    colorSpace: resources.owner.workingColorSpace)
                guard let materialized = CIImage(mtlTexture: texture, options: [.colorSpace: resources.owner.workingColorSpace])
                else { throw MetalRenderingError.invalidRenderTarget }
                accumulated = materialized.transformed(by: CGAffineTransform(
                    translationX: bounds.minX, y: bounds.minY)).cropped(to: bounds)
                resources.releaseScratchTextures(excluding: protected)
            }
        }
        return EffectRenderResult(image: (accumulated ?? image)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: outputBounds))
    }
}
