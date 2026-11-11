@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import Foundation

struct PreviewVideoProxy: Sendable {
    let url: URL
    let originalSize: CGSize
    let encodedSize: CGSize

    /// Proxies retain raw source orientation. This restores authored source
    /// pixels before the existing effects/masks/placement graph runs.
    var sourcePixelTransform: CGAffineTransform {
        CGAffineTransform(scaleX: originalSize.width / encodedSize.width,
                          y: originalSize.height / encodedSize.height)
    }
}

/// Durable, disposable editing media. Every encoded frame is a sync frame:
/// random/reverse access never needs to decode an earlier GOP first.
actor PreviewProxyStore {
    static let shared = PreviewProxyStore()
    private nonisolated let directory: URL
    private var ready: [String: PreviewVideoProxy] = [:]
    private var inFlight: [String: Task<PreviewVideoProxy, Error>] = [:]
    private var warming = Set<String>()
    private let bitsPerPixelFrame: Double
    private let queue = DispatchQueue(label: "com.moysoft.motionary.preview-proxy", qos: .utility)

    init(directory: URL? = nil, bitsPerPixelFrame: Double = 0.9) {
        self.bitsPerPixelFrame = bitsPerPixelFrame
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionaryPreviewProxies/v1", isDirectory: true)
    }

    nonisolated func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    private func request(for source: CachedMediaAsset) throws -> (key: String, proxy: PreviewVideoProxy)? {
        guard source.videoTrack != nil, let size = source.naturalSize,
            size.width >= 2, size.height >= 2,
            max(size.width, size.height) >= 256,
            source.asset.url.isFileURL,
            FileManager.default.fileExists(atPath: source.asset.url.path)
        else { return nil }
        let values = try source.asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "v4-960-yuv-color|\(bitsPerPixelFrame)|\(source.asset.url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        // Match the compositor's maximum preview resolution. Decoding 720 px
        // and then enlarging it to a 960 px preview discards visible detail.
        let scale = min(960 / max(size.width, size.height), 1)
        let encodedSize = CGSize(width: max(2, floor(size.width * scale / 2) * 2),
                                 height: max(2, floor(size.height * scale / 2) * 2))
        let url = directory.appendingPathComponent(key).appendingPathExtension("mov")
        let proxy = PreviewVideoProxy(url: url, originalSize: size, encodedSize: encodedSize)
        return (key, proxy)
    }

    private func cachedProxy(key: String, proxy: PreviewVideoProxy, source: CachedMediaAsset) async -> PreviewVideoProxy? {
        let url = proxy.url
        if let cached = ready[key], FileManager.default.fileExists(atPath: cached.url.path) { return cached }
        if FileManager.default.fileExists(atPath: url.path) {
            let cachedAsset = AVURLAsset(url: url)
            if let cachedTrack = try? await cachedAsset.loadTracks(withMediaType: .video).first,
                let duration = try? await cachedAsset.load(.duration),
                let cachedSize = try? await cachedTrack.load(.naturalSize),
                cachedSize == proxy.encodedSize,
                abs(CMTimeGetSeconds(duration) - source.duration) < 0.1 {
                ready[key] = proxy
                return proxy
            }
            // Interrupted/corrupt/OS-purged cache entries are disposable.
            try? FileManager.default.removeItem(at: url)
        }
        return nil
    }

    /// Composition preparation may use a completed proxy, but never waits for
    /// a whole asset to transcode. The original source is immediately usable.
    /// Warmups are deduplicated, and installed player items stay immutable.
    func availableProxy(source: CachedMediaAsset) async throws -> PreviewVideoProxy? {
        guard let (key, proxy) = try request(for: source) else { return nil }
        if let cached = await cachedProxy(key: key, proxy: proxy, source: source) { return cached }
        if warming.insert(key).inserted {
            Task(priority: .utility) {
                defer { warming.remove(key) }
                do { _ = try await prepare(source: source) }
                catch { AppLogger.rendering.debug("Background preview proxy unavailable: \(error.localizedDescription, privacy: .public)") }
            }
        }
        return nil
    }

    func prepare(source: CachedMediaAsset) async throws -> PreviewVideoProxy? {
        guard let track = source.videoTrack,
            let (key, proxy) = try request(for: source) else { return nil }
        if let cached = await cachedProxy(key: key, proxy: proxy, source: source) { return cached }
        if let task = inFlight[key] { return try await task.value }
        let url = proxy.url
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("\(key)-\(UUID().uuidString).partial.mov")
        let queue = queue
        let bitsPerPixelFrame = bitsPerPixelFrame
        let task = Task<PreviewVideoProxy, Error> {
            let fps = try await track.load(.nominalFrameRate)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try Self.transcode(source: source, track: track, target: proxy.encodedSize, fps: fps, bitsPerPixelFrame: bitsPerPixelFrame, to: partial)
                        if FileManager.default.fileExists(atPath: url.path) {
                            try? FileManager.default.removeItem(at: partial)
                        } else {
                            try FileManager.default.moveItem(at: partial, to: url)
                        }
                        continuation.resume()
                    } catch {
                        try? FileManager.default.removeItem(at: partial)
                        continuation.resume(throwing: error)
                    }
                }
            }
            return proxy
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        ready[key] = result
        return result
    }

    private nonisolated static func transcode(source: CachedMediaAsset, track: AVAssetTrack,
                                             target: CGSize, fps: Float, bitsPerPixelFrame: Double, to url: URL) throws {
        let reader = try AVAssetReader(asset: source.asset)
        // Keep YUV excursions until Core Image performs color matching; an
        // intermediate 8-bit RGB decode clips them in the source gamut.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaImportError.videoWriterUnavailable }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(target.width), AVVideoHeightKey: Int(target.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: Int(max(target.width * target.height * bitsPerPixelFrame * Double(max(fps, 24)), 1_000_000)),
                AVVideoExpectedSourceFrameRateKey: max(fps, 1),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(target.width),
            kCVPixelBufferHeightKey as String: Int(target.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        guard writer.canAdd(input) else { throw MediaImportError.videoWriterUnavailable }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? MediaImportError.videoWriterUnavailable
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = VideoColorSpace.rec709 else { throw MediaImportError.videoWriterUnavailable }
        let extent = CGRect(origin: .zero, size: target)
        let original = source.naturalSize!
        let scale = CGAffineTransform(scaleX: target.width / original.width, y: target.height / original.height)
        var sampleCount = 0
        var lastEnd = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                guard let pixels = CMSampleBufferGetImageBuffer(sample),
                    let pool = adaptor.pixelBufferPool else { throw MediaImportError.pixelBufferCreationFailed }
                var scaledBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaledBuffer) == kCVReturnSuccess,
                    let scaledBuffer else { throw MediaImportError.pixelBufferCreationFailed }
                context.render(CIImage(cvPixelBuffer: pixels).transformed(by: scale).cropped(to: extent),
                               to: scaledBuffer, bounds: extent, colorSpace: colorSpace)
                // Offline backpressure only, on our serial encoding queue.
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw writer.error ?? MediaImportError.videoWriterUnavailable
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard adaptor.append(scaledBuffer, withPresentationTime: time) else {
                    throw writer.error ?? MediaImportError.videoWriterUnavailable
                }
                let duration = CMSampleBufferGetDuration(sample)
                let safeDuration = duration.isNumeric && CMTimeGetSeconds(duration) > 0
                    ? duration : CMTime(seconds: 1 / Double(max(fps, 1)), preferredTimescale: 60_000)
                lastEnd = CMTimeAdd(time, safeDuration)
                sampleCount += 1
            }
        }
        guard reader.status == .completed, sampleCount > 0 else {
            throw reader.error ?? MediaImportError.unsupportedMedia
        }
        // Preserve a final partial frame and source offsets; never shorten a
        // trimmed clip or shift a variable-frame-rate source to a new cadence.
        writer.endSession(atSourceTime: CMTimeMaximum(lastEnd, CMTime(seconds: source.duration, preferredTimescale: 60_000)))
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
            throw writer.error ?? MediaImportError.videoWriterUnavailable
        }
    }
}
