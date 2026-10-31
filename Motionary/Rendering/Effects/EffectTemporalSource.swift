@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Time-addressed source access rather than a history of previously displayed
/// frames. Thus reverse scrubbing and export do not depend on playback order.
struct EffectTemporalSource: Sendable {
    let url: URL
    let sourceStart: Double
    let sourceDuration: Double
    let speedMap: SpeedMap
    var adjustments = AdjustmentSettings()

    func image(at clipTime: Double, fitting extent: CGRect, quality: RenderQualityProfile) throws -> CIImage {
        let sourceTime = sourceStart + speedMap.sourceTime(at: clipTime, sourceDuration: sourceDuration)
        let image = try EffectTemporalFrameStore.shared.image(url: url, time: sourceTime,
            size: extent.size, quality: quality)
        let fitted = image.transformed(by: CGAffineTransform(
            scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        return EffectColorAdjustments.apply(adjustments, to: fitted, at: clipTime)
    }
}

/// Shared color preparation keeps historical samples consistent with the live source.
enum EffectColorAdjustments {
    static func apply(_ adjustments: AdjustmentSettings, to image: CIImage, at time: Double) -> CIImage {
        let output = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: adjustments.brightness.value(at: time),
            kCIInputContrastKey: adjustments.contrast.value(at: time),
            kCIInputSaturationKey: adjustments.saturation.value(at: time),
        ])
        return output.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: adjustments.exposure.value(at: time),
        ])
    }
}

/// Bounded decoded-frame cache. Generator access is serialized because a single
/// asset generator must not be mutated while another render uses it.
private final class EffectTemporalFrameStore: @unchecked Sendable {
    static let shared = EffectTemporalFrameStore()
    private let lock = NSLock()
    private let frames = NSCache<NSString, CGImage>()
    private let generators = NSCache<NSURL, AVAssetImageGenerator>()

    private init() {
        frames.totalCostLimit = 96 * 1024 * 1024
        frames.countLimit = 32
        generators.countLimit = 4
    }

    func image(url: URL, time: Double, size: CGSize, quality: RenderQualityProfile) throws -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        let limit: CGFloat = quality == .interactive ? 1280 : max(size.width, size.height)
        let scale = min(1, limit / max(size.width, size.height, 1))
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        let target = CMTime(seconds: max(time, 0), preferredTimescale: 60_000)
        let key = "\(url.absoluteString)|\(target.value)|\(width)x\(height)" as NSString
        if let frame = frames.object(forKey: key) { return CIImage(cgImage: frame) }
        let generator: AVAssetImageGenerator
        if let existing = generators.object(forKey: url as NSURL) {
            generator = existing
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generators.setObject(generator, forKey: url as NSURL)
        }
        generator.maximumSize = CGSize(width: width, height: height)
        let decoded = DecodedFrame()
        let ready = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: target)]) { _, image, _, result, error in
            decoded.complete(image: result == .succeeded ? image : nil, error: error)
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 8) == .success else {
            generator.cancelAllCGImageGeneration()
            generators.removeObject(forKey: url as NSURL)
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let frame = try decoded.get()
        frames.setObject(frame, forKey: key, cost: frame.bytesPerRow * frame.height)
        return CIImage(cgImage: frame)
    }
}

private final class DecodedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var error: Error?

    func complete(image: CGImage?, error: Error?) {
        lock.lock()
        self.image = image
        self.error = error
        lock.unlock()
    }

    func get() throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        if let image { return image }
        throw error ?? MetalRenderingError.sourceFrameUnavailable
    }
}
