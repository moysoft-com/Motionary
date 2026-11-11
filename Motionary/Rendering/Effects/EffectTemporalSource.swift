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
               renderScale: CGFloat = 1, videoSampleRanges: [CMTimeRange] = []) throws -> CIImage {
        let sourceTime = sourceStart + speedMap.sourceTime(at: clipTime, sourceDuration: sourceDuration)
        let image = try EffectTemporalFrameStore.shared.image(url: url, time: sourceTime,
            size: extent.size, quality: quality, videoSampleRanges: videoSampleRanges)
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

/// Bounded decoded-frame cache. Generator access is serialized per asset
/// because a single asset generator must not be mutated while another render
/// uses it. Assets are independent, so one slow decoder no longer blocks
/// temporal samples for every other asset on the compositor queue.
private final class EffectTemporalFrameStore: @unchecked Sendable {
    static let shared = EffectTemporalFrameStore()
    private let lock = NSLock()
    private var urlLocks: [URL: NSLock] = [:]
    private let frames = NSCache<NSString, CGImage>()
    private let generators = NSCache<NSURL, AVAssetImageGenerator>()
    private func lockFor(url: URL) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = urlLocks[url] { return existing }
        let created = NSLock()
        urlLocks[url] = created
        return created
    }

    private init() {
        frames.totalCostLimit = 96 * 1024 * 1024
        frames.countLimit = 32
        generators.countLimit = 4
    }

    func image(url: URL, time: Double, size: CGSize, quality: RenderQualityProfile,
               videoSampleRanges: [CMTimeRange] = []) throws -> CIImage {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let requested = CMTime(seconds: max(time, 0), preferredTimescale: 60_000)
        // A depth bake can encounter audio padding or empty video edits. Keep
        // these requests inside the nearest nonempty video segment.
        func distance(to range: CMTimeRange) -> CMTime {
            max(range.start - requested, requested - range.end, .zero)
        }
        let videoSampleRange = videoSampleRanges.first { $0.start <= requested && requested < $0.end }
            ?? videoSampleRanges.min { distance(to: $0) < distance(to: $1) }
        let target: CMTime
        if let range = videoSampleRange {
            let last = max(range.start, range.end - CMTime(value: 1, timescale: 60_000))
            let clamped = min(max(requested, range.start), last).convertScale(60_000, method: .roundTowardZero)
            target = max(clamped, range.start)
        } else {
            target = requested
        }
        var key = "\(url.absoluteString)|\(target.value)/\(target.timescale)|\(width)x\(height)"
        if let range = videoSampleRange {
            // Approximate depth samples cannot satisfy exact temporal effects.
            key += "|depth|\(range.start.seconds)|\(range.end.seconds)"
        }
        // Cache hits must not wait behind another asset's decoder request.
        if let frame = frames.object(forKey: key as NSString) { return VideoSourceGeometry.engineImage(CIImage(cgImage: frame)) }
        let urlLock = lockFor(url: url)
        urlLock.lock()
        defer { urlLock.unlock() }
        if let frame = frames.object(forKey: key as NSString) { return VideoSourceGeometry.engineImage(CIImage(cgImage: frame)) }
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
        let frame: CGImage
        do {
            frame = try decode(generator, at: target, quality: quality)
        } catch {
            generators.removeObject(forKey: url as NSURL)
            guard let range = videoSampleRange else { throw error }
            try Task.checkCancellation()
            // Some sources have irregular sample times or edit lists.
            // Retry with a fresh decoder and bounded, in-track tolerance.
            let retry = AVAssetImageGenerator(asset: AVURLAsset(url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
            retry.appliesPreferredTrackTransform = false
            retry.maximumSize = generator.maximumSize
            let tolerance = CMTime(value: 1, timescale: 12)
            retry.requestedTimeToleranceBefore = min(tolerance, target - range.start)
            retry.requestedTimeToleranceAfter = min(tolerance, range.end - target)
            frame = try decode(retry, at: target, quality: quality)
        }
        frames.setObject(frame, forKey: key as NSString, cost: frame.bytesPerRow * frame.height)
        return VideoSourceGeometry.engineImage(CIImage(cgImage: frame))
    }

    private func decode(_ generator: AVAssetImageGenerator, at target: CMTime,
                        quality: RenderQualityProfile) throws -> CGImage {
        let decoded = DecodedFrame()
        let ready = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: target)]) { _, image, _, result, error in
            decoded.complete(image: result == .succeeded ? image : nil, error: error)
            ready.signal()
        }
        // Decode waits run on the compositor's single render queue. Export
        // keeps the full 8 s budget because it has no fallback frame; preview
        // already finishes a timed-out request with the compositor's
        // last-good-frame fallback, so interactive frames keep a 1 s budget
        // and balanced frames 2 s instead of pinning the queue for 8 s when a
        // thumbnail or slow decoder stalls.
        let deadline: DispatchTime
        switch quality {
        case .export: deadline = .now() + 8
        case .balanced: deadline = .now() + 2
        case .interactive: deadline = .now() + 1
        }
        guard ready.wait(timeout: deadline) == .success else {
            generator.cancelAllCGImageGeneration()
            throw MetalRenderingError.sourceFrameUnavailable
        }
        return try decoded.get()
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
