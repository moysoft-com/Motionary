@preconcurrency import AVFoundation
import CoreImage
import CryptoKit
import VideoToolbox

enum SmoothMotionMode: String, Codable, CaseIterable, Sendable {
    case opticalFlow
    case frameGen

    var title: String {
        switch self {
        case .opticalFlow: "Fast"
        case .frameGen: "High Quality"
        }
    }
}

/// Describes the frames of a clip independently of its effects and absolute
/// timeline position. Only the alignment to the project frame grid matters.
struct SmoothMotionRecipe: Codable, Equatable, Sendable {
    let sourceRange: TimeRangeValue
    let speedMap: SpeedMap
    let frameRate: Int32
    let firstFrameOffset: Double
    let mode: SmoothMotionMode

    init(
        sourceRange: TimeRangeValue, speedMap: SpeedMap, timelineStart: Double,
        frameRate: Int32, mode: SmoothMotionMode = .frameGen
    ) {
        self.sourceRange = sourceRange
        self.speedMap = speedMap
        self.frameRate = max(frameRate, 1)
        self.mode = mode
        let start = CMTime(seconds: timelineStart, preferredTimescale: 600)
        let firstFrame = start.convertScale(max(frameRate, 1), method: .roundTowardPositiveInfinity)
        firstFrameOffset = max(0, (firstFrame - start).seconds)
    }

    var duration: Double { speedMap.timelineDuration(sourceDuration: sourceRange.duration) }

    func sourceTime(at localTime: Double) -> CMTime {
        CMTime(seconds: sourceRange.start + speedMap.sourceTime(
            at: localTime, sourceDuration: sourceRange.duration), preferredTimescale: 600_000)
    }

    func interpolationPhase(
        at localTime: Double, target: CMTime, current: CMTime, next: CMTime
    ) -> Float? {
        guard current < target, target < next, next.seconds < sourceRange.end,
            speedMap.timeRemap?.holdsSource(at: localTime) != true
        else { return nil }
        let interval = (next - current).seconds
        let phase = Float((target - current).seconds / interval)
        return phase > 0.002 && phase < 0.998 ? phase : nil
    }
}

extension MediaTimelineItem {
    var canUseSmoothMotion: Bool { mediaType == .video }

    func smoothMotionRecipe(frameRate: Int32, mode: SmoothMotionMode? = nil) -> SmoothMotionRecipe {
        SmoothMotionRecipe(sourceRange: sourceRange, speedMap: speedMap,
            timelineStart: timelineStart, frameRate: frameRate, mode: mode ?? smoothMotionMode)
    }
}

enum SmoothMotionError: LocalizedError {
    case incompatibleSource
    case insufficientStorage
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .incompatibleSource: "Motionary couldn’t read the source video for Smooth Motion."
        case .insufficientStorage: "Free up storage to prepare Smooth Motion for this clip."
        case .processingFailed: "Motionary couldn’t prepare Smooth Motion for this clip."
        }
    }
}

enum SmoothMotion {
    static func cachedURL(source: URL, recipe: SmoothMotionRecipe, allowsPreviousVersion: Bool = false) -> URL? {
        guard let url = cacheURL(source: source, recipe: recipe) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard allowsPreviousVersion else { return nil }
        let previous = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MotionarySmoothMotion-v2", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: previous.path) ? previous : nil
    }

    private static func cacheURL(source: URL, recipe: SmoothMotionRecipe) -> URL? {
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize
        else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(recipe) else { return nil }
        let identity = "\(source.standardizedFileURL.path)|\(size)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|"
        let hash = SHA256.hash(data: Data(identity.utf8) + encoded).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appendingPathComponent("MotionarySmoothMotion-v3", isDirectory: true)
            .appendingPathComponent(hash).appendingPathExtension("mov")
    }

    /// The result is a silent source-space video on the clip's timeline frame
    /// grid. A completed file is published atomically for preview and export.
    static func prepare(
        source: URL, recipe: SmoothMotionRecipe, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        guard let output = cacheURL(source: source, recipe: recipe) else {
            throw SmoothMotionError.incompatibleSource
        }
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let job = Task.detached(priority: .userInitiated) {
            try await write(source: source, recipe: recipe, output: output, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }
}

private extension SmoothMotion {
    static func write(
        source: URL, recipe: SmoothMotionRecipe, output: URL, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let metadata = try await MediaAssetCache.shared.metadata(for: source)
        guard let track = metadata.videoTrack, let size = metadata.naturalSize,
            size.width > 0, size.height > 0,
            let count = Int(exactly: ceil((recipe.duration - recipe.firstFrameOffset) * Double(recipe.frameRate) - 0.000_001))
        else { throw SmoothMotionError.incompatibleSource }
        let frameCount = max(count, 1)
        let (formats, range, segments, nominalRate) = try await track.load(.formatDescriptions, .timeRange, .segments, .nominalFrameRate)
        let isHDR = formats.contains(where: isHDRFormat)
        let directory = output.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(UUID().uuidString + ".partial.mov")
        defer { try? files.removeItem(at: scratch) }
        let editRanges = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        let videoRanges = editRanges.isEmpty ? [range] : editRanges
        // Encoder capabilities vary independently of the timeline rate.
        // Keep its exact timestamps while adapting the cached raster.
        var lastFailure: Error?
        var previousSize: CGSize?
        for limit in [4096.0, 1920.0, 1280.0] {
            let scale = min(1, limit / max(size.width, size.height))
            let target = CGSize(width: max(floor(size.width * scale / 2) * 2, 2),
                height: max(floor(size.height * scale / 2) * 2, 2))
            guard target != previousSize else { continue }
            previousSize = target
            try Task.checkCancellation()
            // Every cached frame is encoded independently for random access.
            // Give the intermediate more headroom than a delivery encode.
            let bitRate = Int(min(max(target.width * target.height * Double(recipe.frameRate) * 0.60, 2_000_000), 160_000_000))
            let estimatedBytes = Double(bitRate) / 8 * recipe.duration
            if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, Double(available) < estimatedBytes * 1.25 {
                lastFailure = SmoothMotionError.insufficientStorage
                continue
            }
            do {
                let writer = try SmoothMotionWriter(url: scratch, size: target, rate: recipe.frameRate, bitRate: bitRate)
                let ordinaryDecoder = RemapFrameDecoder(asset: metadata.asset, track: track, range: range,
                    rawSize: size, frameRate: nominalRate)
                var decoder = ordinaryDecoder
                if isHDR {
                    let hdrDecoder = RemapFrameDecoder(asset: metadata.asset, track: track, range: range,
                        rawSize: size, frameRate: nominalRate, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                    let target = max(range.start, min(recipe.sourceTime(at: recipe.firstFrameOffset),
                        range.end - CMTime(value: 1, timescale: 600_000)))
                    if (try? hdrDecoder.samples(at: target)) != nil { decoder = hdrDecoder }
                }
                try await writeFrames(recipe: recipe, frameCount: frameCount, decoder: decoder,
                    range: range, videoRanges: videoRanges, nominalRate: nominalRate,
                    isHDR: isHDR, writer: writer, progress: progress)
                lastFailure = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
                try? files.removeItem(at: scratch)
            }
        }
        if let lastFailure { throw lastFailure }
        try Task.checkCancellation()
        guard cacheURL(source: source, recipe: recipe) == output else { throw SmoothMotionError.incompatibleSource }
        do {
            try files.moveItem(at: scratch, to: output)
        } catch {
            guard files.fileExists(atPath: output.path) else { throw error }
        }
        await progress(1)
        return output
    }

    static func writeFrames(
        recipe: SmoothMotionRecipe, frameCount: Int, decoder: RemapFrameDecoder,
        range: CMTimeRange, videoRanges: [CMTimeRange], nominalRate: Float, isHDR: Bool,
        writer: SmoothMotionWriter, progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        var generator: MotionFrameGenerator?
        var mayStartNative = recipe.mode == .frameGen
        let flow = SmoothMotionOpticalFlow(highQuality: recipe.mode == .frameGen)
        let validation = SmoothMotionInterpolationCheck()
        var cachedPair: (current: CMTime, next: CMTime, isSafe: Bool)?
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(value: Int64(index), timescale: recipe.frameRate)
            let localTime = recipe.firstFrameOffset + time.seconds
            let target = recipe.sourceTime(at: localTime)
            let last = min(range.end, CMTime(seconds: recipe.sourceRange.end, preferredTimescale: 600_000))
                - CMTime(value: 1, timescale: 600_000)
            let samples = try decoder.samples(at: max(range.start, min(target, last)))
            var image = CIImage(cvPixelBuffer: samples.current.buffer, options: [.toneMapHDRtoSDR: isHDR])
            if let next = samples.next,
                next.time.seconds < recipe.sourceRange.end,
                abs((target - next.time).seconds) <= 1.0 / 600_000
            {
                // Source PTS may use a different timescale from the speed map.
                image = CIImage(cvPixelBuffer: next.buffer, options: [.toneMapHDRtoSDR: isHDR])
            } else if let next = samples.next,
                let phase = recipe.interpolationPhase(at: localTime, target: target, current: samples.current.time, next: next.time)
            {
                if cachedPair?.current != samples.current.time || cachedPair?.next != next.time {
                    let maxGap = max(3 / Double(max(nominalRate, 1)), 0.25)
                    let continuous = (next.time - samples.current.time).seconds <= maxGap && videoRanges.contains {
                        $0.containsTime(samples.current.time) && $0.containsTime(next.time)
                    }
                    cachedPair = (samples.current.time, next.time,
                        continuous && !isHardCut(samples.current.buffer, next.buffer))
                }
                if cachedPair?.isSafe == true {
                    let following = CIImage(cvPixelBuffer: next.buffer, options: [.toneMapHDRtoSDR: isHDR])
                    if mayStartNative {
                        mayStartNative = false
                        #if !targetEnvironment(simulator)
                        if #available(iOS 26, *), VTFrameRateConversionConfiguration.isSupported {
                            generator = try? SmoothMotionProcessor(first: samples.current.buffer, isHDR: isHDR)
                        }
                        #endif
                    }
                    var generated: CIImage?
                    if let native = generator {
                        do {
                            generated = try await native.interpolate(samples.current, next: next, at: target, phase: phase)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            generator = nil
                        }
                    }
                    if let generated, validation.accepts(generated, between: image, and: following,
                        current: samples.current.time, next: next.time)
                    {
                        image = generated
                    } else {
                        image = flow.interpolate(image, following, current: samples.current.time, next: next.time, phase: phase)
                    }
                }
            }
            try await writer.append(image, at: time)
            if index.isMultiple(of: max(frameCount / 100, 4)) {
                await progress(Double(index) / Double(frameCount))
            }
        }
        try await writer.finish(at: CMTime(value: Int64(frameCount), timescale: recipe.frameRate))
    }

    static func isHDRFormat(_ format: CMFormatDescription) -> Bool {
        let transfer = CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    static func isHardCut(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        guard let a = lumaSamples(first), let b = lumaSamples(second) else { return true }
        var differences = 0
        var histogram = Array(repeating: 0, count: 16)
        for (left, right) in zip(a, b) {
            differences += abs(left - right)
            histogram[left / 16] += 1
            histogram[right / 16] -= 1
        }
        return differences > a.count * 78
            || (differences > a.count * 48 && histogram.reduce(0) { $0 + abs($1) } > a.count / 2)
    }

    static func lumaSamples(_ buffer: CVPixelBuffer) -> [Int]? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
            CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let isTenBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        return (0..<9).flatMap { row in
            (0..<16).map { column in
                let row = base.advanced(by: ((row * 2 + 1) * height / 18) * rowBytes)
                let column = (column * 2 + 1) * width / 32
                return isTenBit ? Int(row.load(fromByteOffset: column * 2, as: UInt16.self) >> 8)
                    : Int(row.load(fromByteOffset: column, as: UInt8.self))
            }
        }
    }
}

/// Rejects obvious native interpolation failures such as flashes and corrupted
/// regions. The coarse check tolerates movement between the reference frames.
final class SmoothMotionInterpolationCheck {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let size = CGSize(width: 48, height: 28)
    private var references: (CMTime, CMTime, lower: [UInt8], upper: [UInt8])?

    func accepts(_ image: CIImage, between current: CIImage, and next: CIImage,
                 current currentTime: CMTime, next nextTime: CMTime) -> Bool {
        guard image.extent == current.extent else { return false }
        if references?.0 != currentTime || references?.1 != nextTime {
            let a = luma(current)
            let b = luma(next)
            let pairs = zip(a, b)
            references = (currentTime, nextTime, pairs.map { min($0, $1) }, pairs.map { max($0, $1) })
        }
        guard let references else { return false }
        let output = luma(image)
        var error = 0
        var outliers = 0
        for index in output.indices {
            let pixel = Int(output[index])
            let delta = max(Int(references.lower[index]) - pixel, pixel - Int(references.upper[index]), 0)
            error += delta
            if delta > 48 { outliers += 1 }
        }
        return error <= output.count * 14 && outliers <= output.count / 12
    }

    private func luma(_ image: CIImage) -> [UInt8] {
        let bounds = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height))
        var output = [UInt8](repeating: 0, count: Int(size.width * size.height))
        context.render(scaled, toBitmap: &output, rowBytes: Int(size.width),
            bounds: CGRect(origin: .zero, size: size), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return output
    }
}

private protocol MotionFrameGenerator {
    func interpolate(_ current: RemapFrameDecoder.Sample, next: RemapFrameDecoder.Sample,
        at time: CMTime, phase: Float) async throws -> CIImage
}

#if !targetEnvironment(simulator)
@available(iOS 26, *)
private final class SmoothMotionProcessor: MotionFrameGenerator {
    private let processor = VTFrameProcessor()
    private let destinationPool: CVPixelBufferPool
    private let inputPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    private let isHDR: Bool
    private let rgbColorSpace: CGColorSpace?
    private lazy var colorContext = CIContext(options: [.cacheIntermediates: false])
    private var cachedInput: (VTFrameProcessorFrame, VTFrameProcessorFrame)?
    private var previousPhase: Float = 0

    init(first: CVPixelBuffer, isHDR: Bool) throws {
        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)
        let tenBitFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard !isHDR || CVPixelBufferGetPixelFormatType(first) == tenBitFormat else {
            throw SmoothMotionError.processingFailed
        }
        self.isHDR = isHDR
        let halfFloat = kCVPixelFormatType_64RGBAHalf
        let supportedFormats = isHDR ? [tenBitFormat, halfFloat] : [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
            halfFloat
        ]
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
            qualityPrioritization: .quality, revision: VTFrameRateConversionConfiguration.defaultRevision
        ), let format = supportedFormats.first(where: { configuration.supportedPixelFormats.contains($0) })
        else { throw SmoothMotionError.incompatibleSource }
        switch format {
        case halfFloat:
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            else { throw SmoothMotionError.processingFailed }
            rgbColorSpace = space
        case kCVPixelFormatType_32BGRA:
            guard let space = VideoColorSpace.rec709 else { throw SmoothMotionError.processingFailed }
            rgbColorSpace = space
        default:
            rgbColorSpace = nil
        }

        func pool(attributes: [String: any Sendable]) throws -> CVPixelBufferPool {
            var attributes = attributes
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
            attributes[kCVPixelBufferWidthKey as String] = width
            attributes[kCVPixelBufferHeightKey as String] = height
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: String]()
            var result: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &result) == kCVReturnSuccess,
                let result
            else { throw SmoothMotionError.processingFailed }
            return result
        }
        inputPool = try pool(attributes: configuration.sourcePixelBufferAttributes)
        destinationPool = try pool(attributes: configuration.destinationPixelBufferAttributes)
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr,
            let transfer
        else {
            throw SmoothMotionError.processingFailed
        }
        self.transfer = transfer
        try processor.startSession(configuration: configuration)
    }

    deinit { processor.endSession() }

    func interpolate(
        _ current: RemapFrameDecoder.Sample, next: RemapFrameDecoder.Sample, at time: CMTime, phase: Float
    ) async throws -> CIImage {
        let previous = cachedInput
        let samePair = previous?.0.presentationTimeStamp == current.time
            && previous?.1.presentationTimeStamp == next.time
        let isNextPair = previous?.1.presentationTimeStamp == current.time
        if !samePair {
            let first = try inputFrame(current, reusing: previous?.1)
            let second = try inputFrame(next, reusing: previous?.0)
            cachedInput = (first, second)
        }
        let mode: VTFrameRateConversionParameters.SubmissionMode
        if samePair && phase > previousPhase {
            mode = .sequentialReferencesUnchanged
        } else {
            mode = isNextPair ? .sequential : .random
        }
        let buffer = try Self.buffer(in: destinationPool)
        guard let (first, second) = cachedInput,
            let output = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time),
            let parameters = VTFrameRateConversionParameters(
                sourceFrame: first, nextFrame: second, opticalFlow: nil, interpolationPhase: [phase],
                submissionMode: mode,
                destinationFrames: [output])
        else { throw SmoothMotionError.processingFailed }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        previousPhase = phase
        if let rgbColorSpace { return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: rgbColorSpace]) }
        CVBufferPropagateAttachments(first.buffer, buffer)
        return CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: isHDR])
    }

    private func inputFrame(
        _ sample: RemapFrameDecoder.Sample, reusing frame: VTFrameProcessorFrame?
    ) throws -> VTFrameProcessorFrame {
        if let frame, frame.presentationTimeStamp == sample.time { return frame }
        let buffer = try Self.buffer(in: inputPool)
        if let rgbColorSpace {
            let image = CIImage(cvPixelBuffer: sample.buffer, options: [.toneMapHDRtoSDR: isHDR])
            colorContext.render(image, to: buffer, bounds: image.extent, colorSpace: rgbColorSpace)
        } else {
            guard VTPixelTransferSessionTransferImage(transfer, from: sample.buffer, to: buffer) == noErr
            else { throw SmoothMotionError.processingFailed }
            CVBufferPropagateAttachments(sample.buffer, buffer)
        }
        guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: sample.time)
        else { throw SmoothMotionError.processingFailed }
        return frame
    }

    private static func buffer(in pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw SmoothMotionError.processingFailed
        }
        return buffer
    }
}
#endif

private final class SmoothMotionWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let extent: CGRect
    private let colorSpace: CGColorSpace
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(url: URL, size: CGSize, rate: Int32, bitRate: Int) throws {
        guard let colorSpace = VideoColorSpace.rec709,
            let width = Int(exactly: size.width), let height = Int(exactly: size.height),
            width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2)
        else { throw SmoothMotionError.incompatibleSource }
        self.colorSpace = colorSpace
        extent = CGRect(x: 0, y: 0, width: width, height: height)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let useHEVC = max(width, height) > 1920 || rate > 60
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: rate,
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoAllowFrameReorderingKey: false
        ]
        if !useHEVC { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = rate
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        guard writer.canAdd(input) else { throw SmoothMotionError.processingFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SmoothMotionError.processingFailed }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if writer.status == .writing { writer.cancelWriting() }
    }

    func append(_ source: CIImage, at time: CMTime) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? SmoothMotionError.processingFailed
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try autoreleasepool {
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else { throw SmoothMotionError.processingFailed }
            let original = source.extent
            guard original.width > 0, original.height > 0 else {
                throw SmoothMotionError.incompatibleSource
            }
            let image = source.transformed(by: CGAffineTransform(translationX: -original.minX, y: -original.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / original.width, y: extent.height / original.height))
            context.render(image, to: buffer, bounds: extent, colorSpace: colorSpace)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? SmoothMotionError.processingFailed
            }
        }
    }

    func finish(at time: CMTime) async throws {
        writer.endSession(atSourceTime: time)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SmoothMotionError.processingFailed }
    }
}
