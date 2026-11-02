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
    var backgroundRemoval: BackgroundRemovalSettings? = nil
    var backgroundMatteURL: URL? = nil
    var sourceOrientation = CGAffineTransform.identity
    var matteOrientation = CGAffineTransform.identity

    func image(at clipTime: Double, fitting extent: CGRect, quality: RenderQualityProfile,
               adjustmentTime: Double? = nil, applyCutout: Bool = false,
               renderScale: CGFloat = 1) throws -> CIImage {
        let sourceTime = sourceStart + speedMap.sourceTime(at: clipTime, sourceDuration: sourceDuration)
        let image = try EffectTemporalFrameStore.shared.image(url: url, time: sourceTime,
            size: extent.size, quality: quality)
        func fit(_ image: CIImage, orientation: CGAffineTransform) -> CIImage {
            // Apply exactly the same Core Image orientation as decoder buffers.
            // ImageGenerator's preferred-track rotation uses a different space.
            let oriented = image.transformed(by: CGAffineTransform(
                a: orientation.a, b: orientation.b, c: orientation.c, d: orientation.d, tx: 0, ty: 0))
            return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / oriented.extent.width,
                    y: extent.height / oriented.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
        }
        var fitted = fit(image, orientation: sourceOrientation)
        if applyCutout, let settings = backgroundRemoval {
            let matte: CIImage?
            if settings.requiresForegroundMatte {
                guard let backgroundMatteURL else { throw MetalRenderingError.sourceFrameUnavailable }
                matte = try EffectTemporalFrameStore.shared.image(url: backgroundMatteURL,
                    time: sourceTime, size: extent.size, quality: quality)
            } else {
                matte = nil
            }
            fitted = BackgroundRemovalImageRenderer.apply(settings,
                matte: matte.map { fit($0, orientation: matteOrientation) }, to: fitted, renderScale: renderScale)
        }
        return EffectColorAdjustments.apply(adjustments, to: fitted, at: adjustmentTime ?? clipTime)
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
    private func request(url: URL, time: Double, size: CGSize, quality: RenderQualityProfile) -> (String, CMTime, Int, Int) {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let seconds = max(time, 0)
        let target = CMTime(seconds: seconds, preferredTimescale: 60_000)
        return ("\(url.absoluteString)|\(target.value)|\(width)x\(height)", target, width, height)
    }

    private init() {
        frames.totalCostLimit = 96 * 1024 * 1024
        frames.countLimit = 32
        generators.countLimit = 4
    }

    func image(url: URL, time: Double, size: CGSize, quality: RenderQualityProfile) throws -> CIImage {
        let (key, target, width, height) = request(url: url, time: time, size: size, quality: quality)
        // Cache hits must not wait behind another asset's decoder request.
        if let frame = frames.object(forKey: key as NSString) { return CIImage(cgImage: frame) }
        lock.lock()
        defer { lock.unlock() }
        if let frame = frames.object(forKey: key as NSString) { return CIImage(cgImage: frame) }
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let generator: AVAssetImageGenerator
        if let existing = generators.object(forKey: url as NSURL) {
            generator = existing
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = false
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
        frames.setObject(frame, forKey: key as NSString, cost: frame.bytesPerRow * frame.height)
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
