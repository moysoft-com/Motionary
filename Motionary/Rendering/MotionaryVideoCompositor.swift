// Core Image compositor for layered Motionary video frames.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import UIKit

/// Applies clip ordering, transforms, adjustments, effects, and opacity to each output frame.
final class MotionaryVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.motionary.video-compositor.render")
    private let renderQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let requestStateLock = NSLock()
    private var requestGeneration: UInt = 0
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(
                mtlDevice: device,
                options: [.cacheIntermediates: false]
            )
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let shapeImageCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private let textLayerRenderer = TextLayerRenderer()

    override init() {
        super.init()
        renderQueue.setSpecific(key: renderQueueSpecificKey, value: 1)
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // A preview-quality or export-size change makes the previous raster layers
        // poor cache candidates and can otherwise retain several large surfaces.
        shapeImageCache.removeAllObjects()
        textLayerRenderer.removeAllObjects()
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        requestStateLock.lock()
        let generation = requestGeneration
        renderQueue.async { [weak self] in
            guard let self else {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }

            guard self.isCurrentRequestGeneration(generation) else {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }

            autoreleasepool {
                guard
                    let instruction = asyncVideoCompositionRequest.videoCompositionInstruction
                        as? MotionaryVideoCompositionInstruction,
                    let destinationBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer()
                else {
                    asyncVideoCompositionRequest.finish(
                        with: NSError(
                            domain: "MotionaryVideoCompositor",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid video composition instruction."]
                        ))
                    return
                }

                let renderSize = instruction.renderSize
                let canvasRect = CGRect(origin: .zero, size: renderSize)
                let background = instruction.backgroundColor
                var output = CIImage(color: CIColor(
                    red: background.red,
                    green: background.green,
                    blue: background.blue,
                    alpha: background.alpha
                ))
                    .cropped(to: canvasRect)
                let time = CMTimeGetSeconds(asyncVideoCompositionRequest.compositionTime)

                for clip in instruction.activeClips(at: time) {
                    guard self.isCurrentRequestGeneration(generation) else {
                        asyncVideoCompositionRequest.finishCancelledRequest()
                        return
                    }
                    let localTime = max(0, time - clip.timelineStart)
                    var image: CIImage
                    let textAnimationSample: TextAnimationSample?
                    if let shape = clip.shape {
                        textAnimationSample = nil
                        image = self.shapeImage(
                            shape,
                            at: localTime,
                            renderSize: renderSize,
                            renderScale: instruction.renderScale
                        )
                    } else if let text = clip.text {
                        let sample = TextAnimationEvaluator.sample(
                            animations: text.animations,
                            at: localTime,
                            clipDuration: text.duration
                        )
                        textAnimationSample = sample
                        image = self.textLayerRenderer.render(
                            item: text,
                            renderSize: renderSize,
                            renderScale: instruction.renderScale,
                            at: localTime,
                            glyphReveal: sample.glyphReveal
                        ).image
                    } else {
                        textAnimationSample = nil
                        guard let sourceBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: clip.trackID) else {
                            continue
                        }
                        image = CIImage(cvPixelBuffer: sourceBuffer)
                        image = self.orientedImage(image, sourceTransform: clip.sourceTransform)
                    }
                    image = self.applyAdjustments(clip.adjustments, to: image, at: localTime)
                    image = self.applyEffects(
                        clip.effectStack,
                        to: image,
                        at: localTime,
                        renderScale: instruction.renderScale
                    )
                    if let textAnimationSample {
                        image = self.applyClipReveal(
                            textAnimationSample.clipReveal,
                            to: image
                        )
                    }
                    image = self.place(
                        image,
                        clip: clip,
                        at: localTime,
                        renderSize: renderSize,
                        isGeneratedLayer: clip.shape != nil || clip.text != nil,
                        textAnimationSample: textAnimationSample
                    )

                    var opacity = min(max(clip.transform.opacity.value(at: localTime), 0), 1)
                    opacity *= textAnimationSample?.opacity ?? 1
                    if let transition = clip.transitionOut, transition.duration > 0 {
                        let fadeStart = max(clip.duration - transition.duration, 0)
                        if localTime >= fadeStart {
                            let progress = min(max((localTime - fadeStart) / transition.duration, 0), 1)
                            switch transition.kind {
                            case .crossDissolve, .fadeToBlack:
                                opacity *= 1 - progress
                            case .wipeLeft:
                                opacity *= 1 - progress
                            }
                        }
                    }
                    image = self.applyOpacity(opacity, to: image)
                    output = image.composited(over: output)
                }

                guard self.isCurrentRequestGeneration(generation) else {
                    asyncVideoCompositionRequest.finishCancelledRequest()
                    return
                }
                self.ciContext.render(output.cropped(to: canvasRect), to: destinationBuffer)
                guard self.isCurrentRequestGeneration(generation) else {
                    asyncVideoCompositionRequest.finishCancelledRequest()
                    return
                }
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: destinationBuffer)
            }
        }
        requestStateLock.unlock()
    }

    func cancelAllPendingVideoCompositionRequests() {
        requestStateLock.lock()
        requestGeneration &+= 1
        requestStateLock.unlock()

        // Every request captured before the generation change is now stale.
        // Drain the serial queue so AVFoundation does not receive an old frame
        // after this cancellation method returns.
        if DispatchQueue.getSpecific(key: renderQueueSpecificKey) == nil {
            renderQueue.sync {}
        }
    }

    private func isCurrentRequestGeneration(_ generation: UInt) -> Bool {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return generation == requestGeneration
    }

    private func orientedImage(
        _ image: CIImage,
        sourceTransform: CGAffineTransform
    ) -> CIImage {
        image.transformed(by: sourceTransform)
    }

    private func shapeImage(
        _ shape: ClipShape,
        at time: Double,
        renderSize: CGSize,
        renderScale: CGFloat
    ) -> CIImage {
        let resolvedWidth = quantize(shape.width.value(at: time), step: 2)
        let resolvedHeight = quantize(shape.height.value(at: time), step: 2)
        let resolvedCornerRadius = quantize(shape.cornerRadius.value(at: time), step: 1)
        let cacheKey = [
            shape.kind.rawValue,
            String(shape.color.red),
            String(shape.color.green),
            String(shape.color.blue),
            String(shape.color.alpha),
            String(resolvedWidth),
            String(resolvedHeight),
            String(resolvedCornerRadius),
            String(describing: renderScale),
            "\(renderSize.width)",
            "\(renderSize.height)"
        ].joined(separator: ":")
        if let cached = shapeImageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let width = min(max(CGFloat(resolvedWidth) * renderScale, 1), renderSize.width)
        let height = min(max(CGFloat(resolvedHeight) * renderScale, 1), renderSize.height)
        let layerSize = CGSize(width: width, height: height)
        let shapeRect = CGRect(origin: .zero, size: layerSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: layerSize, format: format).image { context in
            UIColor(
                red: CGFloat(shape.color.red),
                green: CGFloat(shape.color.green),
                blue: CGFloat(shape.color.blue),
                alpha: CGFloat(shape.color.alpha)
            ).setFill()
            let bounds = shapeRect.insetBy(dx: min(1, width * 0.25), dy: min(1, height * 0.25))
            switch shape.kind {
            case .rectangle:
                context.fill(bounds)
            case .roundedRectangle:
                UIBezierPath(
                    roundedRect: bounds,
                    cornerRadius: min(
                        CGFloat(resolvedCornerRadius) * renderScale,
                        min(width, height) * 0.5
                    )
                ).fill()
            case .circle:
                context.cgContext.fillEllipse(in: bounds)
            }
        }
        let rendered = image.cgImage.map(CIImage.init(cgImage:)) ?? CIImage.empty()
        shapeImageCache.setObject(
            rendered,
            forKey: cacheKey as NSString,
            cost: max(Int(width * height * 4), 1)
        )
        return rendered
    }

    private func quantize(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func place(
        _ image: CIImage,
        clip: RenderClipDescriptor,
        at time: Double,
        renderSize: CGSize,
        isGeneratedLayer: Bool,
        textAnimationSample: TextAnimationSample?
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let fitScale = isGeneratedLayer
            ? 1
            : min(renderSize.width / extent.width, renderSize.height / extent.height)
        let scale = clip.transform.scale.value(at: time)
        let animationScale = textAnimationSample?.scale ?? 1
        let scaleXValue = fitScale * max(scale.x * animationScale, 0.001)
        let scaleYValue = fitScale * max(scale.y * animationScale, 0.001)
        let scaleX = clip.transform.isFlippedHorizontally ? -scaleXValue : scaleXValue
        let scaleY = clip.transform.isFlippedVertically ? -scaleYValue : scaleYValue
        let rotation = clip.transform.rotationDegrees.value(at: time) * .pi / 180
            + (textAnimationSample?.rotationRadians ?? 0)
        let positionX = clip.transform.positionX.value(at: time) * renderSize.width * 0.5
            + (textAnimationSample?.translationX ?? 0) * extent.width
        let positionY = clip.transform.positionY.value(at: time) * renderSize.height * 0.5
            - (textAnimationSample?.translationY ?? 0) * extent.height

        let centered = image.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        let scaled = centered.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rotated = scaled.transformed(by: CGAffineTransform(rotationAngle: rotation))
        return rotated.transformed(
            by: CGAffineTransform(
                translationX: renderSize.width * 0.5 + positionX,
                y: renderSize.height * 0.5 + positionY
            ))
    }

    private func applyClipReveal(_ progress: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let progress = min(max(progress, 0), 1)
        guard progress < 0.999_999 else { return image }

        let transparent = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ).cropped(to: extent)
        guard progress > 0.000_001 else { return transparent }
        let visibleRect = CGRect(
            x: extent.minX,
            y: extent.minY,
            width: extent.width * progress,
            height: extent.height
        )
        return image
            .cropped(to: visibleRect)
            .composited(over: transparent)
            .cropped(to: extent)
    }

    private func applyAdjustments(_ adjustments: AdjustmentSettings, to image: CIImage, at time: Double) -> CIImage {
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = image
        colorControls.brightness = Float(adjustments.brightness.value(at: time))
        colorControls.contrast = Float(adjustments.contrast.value(at: time))
        colorControls.saturation = Float(adjustments.saturation.value(at: time))
        var output = colorControls.outputImage ?? image

        let exposure = adjustments.exposure.value(at: time)
        if abs(exposure) > 0.001 {
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = output
            exposureFilter.ev = Float(exposure)
            output = exposureFilter.outputImage ?? output
        }

        return output
    }

    private func applyEffects(
        _ stack: EffectStack,
        to image: CIImage,
        at time: Double,
        renderScale: CGFloat
    ) -> CIImage {
        stack.effects.reduce(image) { current, effect in
            guard effect.isEnabled else { return current }
            let intensity = min(max(effect.intensity.value(at: time), 0), 1)

            switch effect.kind {
            case .sepia:
                let filter = CIFilter.sepiaTone()
                filter.inputImage = current
                filter.intensity = Float(intensity)
                return filter.outputImage ?? current
            case .noir:
                let filter = CIFilter.photoEffectNoir()
                filter.inputImage = current
                return self.blend(
                    from: current,
                    to: filter.outputImage ?? current,
                    amount: intensity
                )
            case .chrome:
                let filter = CIFilter.photoEffectChrome()
                filter.inputImage = current
                return self.blend(
                    from: current,
                    to: filter.outputImage ?? current,
                    amount: intensity
                )
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = current.clampedToExtent()
                filter.radius = Float(intensity * 18 * Double(renderScale))
                return (filter.outputImage ?? current).cropped(to: current.extent)
            case .vignette:
                let filter = CIFilter.vignette()
                filter.inputImage = current
                filter.intensity = Float(intensity * 1.6)
                filter.radius = Float(max(current.extent.width, current.extent.height) * 0.45)
                return filter.outputImage ?? current
            }
        }
    }

    private func applyOpacity(_ opacity: Double, to image: CIImage) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        return filter.outputImage ?? image
    }

    private func blend(from source: CIImage, to target: CIImage, amount: Double) -> CIImage {
        guard amount > 0.001 else { return source }
        guard amount < 0.999 else { return target }
        let transition = CIFilter.dissolveTransition()
        transition.inputImage = source
        transition.targetImage = target
        transition.time = Float(amount)
        return transition.outputImage ?? source
    }
}
