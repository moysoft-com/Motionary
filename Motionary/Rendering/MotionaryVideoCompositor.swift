// Core Image compositor for layered Motionary video frames.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// Applies clip ordering, transforms, adjustments, effects, and opacity to each output frame.
final class MotionaryVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.motionary.video-compositor.render")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var shouldCancelAllRequests = false
    private var shapeImageCache: [String: CIImage] = [:]

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

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else { return }

            if self.shouldCancelAllRequests {
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

                for clip in instruction.clips where self.isClip(clip, activeAt: time) {
                    let localTime = max(0, time - clip.timelineStart)
                    var image: CIImage
                    if let shape = clip.shape {
                        image = self.shapeImage(shape, at: localTime, renderSize: renderSize)
                    } else {
                        guard let sourceBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: clip.trackID) else {
                            continue
                        }
                        image = CIImage(cvPixelBuffer: sourceBuffer)
                        image = self.orientedImage(image, sourceTransform: clip.sourceTransform)
                    }
                    image = self.applyAdjustments(clip.adjustments, to: image, at: localTime)
                    image = self.applyEffects(clip.effectStack, to: image, at: localTime)
                    image = self.place(image, clip: clip, at: localTime, renderSize: renderSize)

                    let opacity = min(max(clip.transform.opacity.value(at: localTime), 0), 1)
                    image = self.applyOpacity(opacity, to: image)
                    output = image.composited(over: output)
                }

                self.ciContext.render(output.cropped(to: canvasRect), to: destinationBuffer)
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: destinationBuffer)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.async {
            self.shouldCancelAllRequests = true
        }
        renderQueue.async {
            self.shouldCancelAllRequests = false
        }
    }

    private func isClip(_ clip: RenderClipDescriptor, activeAt time: Double) -> Bool {
        time >= clip.timelineStart && time < clip.timelineStart + clip.duration
    }

    private func orientedImage(
        _ image: CIImage,
        sourceTransform: CGAffineTransform
    ) -> CIImage {
        image.transformed(by: sourceTransform)
    }

    private func shapeImage(_ shape: ClipShape, at time: Double, renderSize: CGSize) -> CIImage {
        let resolvedWidth = shape.width.value(at: time)
        let resolvedHeight = shape.height.value(at: time)
        let resolvedCornerRadius = shape.cornerRadius.value(at: time)
        let cacheKey = [
            shape.kind.rawValue,
            String(shape.color.red),
            String(shape.color.green),
            String(shape.color.blue),
            String(shape.color.alpha),
            String(resolvedWidth),
            String(resolvedHeight),
            String(resolvedCornerRadius),
            "\(renderSize.width)",
            "\(renderSize.height)"
        ].joined(separator: ":")
        if let cached = shapeImageCache[cacheKey] {
            return cached
        }

        let width = min(max(CGFloat(resolvedWidth), 1), renderSize.width)
        let height = min(max(CGFloat(resolvedHeight), 1), renderSize.height)
        let shapeRect = CGRect(
            x: (renderSize.width - width) * 0.5,
            y: (renderSize.height - height) * 0.5,
            width: width,
            height: height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            UIColor(
                red: CGFloat(shape.color.red),
                green: CGFloat(shape.color.green),
                blue: CGFloat(shape.color.blue),
                alpha: CGFloat(shape.color.alpha)
            ).setFill()
            let bounds = shapeRect.insetBy(dx: 1, dy: 1)
            switch shape.kind {
            case .rectangle:
                context.fill(bounds)
            case .roundedRectangle:
                UIBezierPath(
                    roundedRect: bounds,
                    cornerRadius: min(CGFloat(resolvedCornerRadius), min(width, height) * 0.5)
                ).fill()
            case .circle:
                context.cgContext.fillEllipse(in: bounds)
            }
        }
        let rendered = image.cgImage.map(CIImage.init(cgImage:)) ?? CIImage.empty()
        shapeImageCache[cacheKey] = rendered
        return rendered
    }

    private func place(_ image: CIImage, clip: RenderClipDescriptor, at time: Double, renderSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let fitScale = min(renderSize.width / extent.width, renderSize.height / extent.height)
        let scale = clip.transform.scale.value(at: time)
        let scaleXValue = fitScale * max(scale.x, 0.01)
        let scaleYValue = fitScale * max(scale.y, 0.01)
        let scaleX = clip.transform.isFlippedHorizontally ? -scaleXValue : scaleXValue
        let scaleY = clip.transform.isFlippedVertically ? -scaleYValue : scaleYValue
        let rotation = clip.transform.rotationDegrees.value(at: time) * .pi / 180
        let positionX = clip.transform.positionX.value(at: time) * renderSize.width * 0.5
        let positionY = clip.transform.positionY.value(at: time) * renderSize.height * 0.5

        let centered = image.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        let scaled = centered.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rotated = scaled.transformed(by: CGAffineTransform(rotationAngle: rotation))
        return rotated.transformed(
            by: CGAffineTransform(
                translationX: renderSize.width * 0.5 + positionX,
                y: renderSize.height * 0.5 + positionY
            ))
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

    private func applyEffects(_ stack: EffectStack, to image: CIImage, at time: Double) -> CIImage {
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
                filter.radius = Float(intensity * 18)
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
