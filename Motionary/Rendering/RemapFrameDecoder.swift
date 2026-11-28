@preconcurrency import AVFoundation
import Foundation
import VideoToolbox
import os

/// Reads native video buffers for arbitrary source times. A small window of
/// preceding frames makes backward playback use sequential decoder reads.
final class RemapFrameDecoder: @unchecked Sendable {
    struct Sample {
        let buffer: CVPixelBuffer
        let time: CMTime
    }

    private struct Frame {
        let buffer: CVPixelBuffer
        let start: CMTime
        var end: CMTime?
    }

    private final class ReaderSession {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var frames: [Frame] = []
        var lastRequested: CMTime?
        var intraReader: IntraFrameReader?
        var intraReaderFailed = false

        deinit { reader?.cancelReading() }
    }

    private static let sessions: NSCache<NSUUID, ReaderSession> = {
        let cache = NSCache<NSUUID, ReaderSession>()
        cache.countLimit = 12
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private let key = NSUUID()
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let range: CMTimeRange
    private let lock = NSLock()
    private let historyCount: Int
    private let historyDuration: CMTime
    private let forwardPreroll: CMTime
    private let forwardReadLimit: CMTime
    private let historyCost: Int
    private let pixelFormat: OSType
    private let isAllIntra: Bool

    init(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, rawSize: CGSize, frameRate: Float,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, isAllIntra: Bool = false) {
        self.asset = asset
        self.track = track
        self.range = range
        self.pixelFormat = pixelFormat
        self.isAllIntra = isAllIntra
        let bytesPerPixel = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 3.0 : 1.5
        let estimatedBytes = max(rawSize.width * rawSize.height * bytesPerPixel, 1)
        historyCount = Int(min(max((28 * 1024 * 1024) / estimatedBytes, 3), 20))
        historyCost = Int(estimatedBytes) * historyCount
        historyDuration = CMTime(
            seconds: Double(historyCount - 1) / Double(max(frameRate, 24)),
            preferredTimescale: 60_000)
        forwardPreroll = CMTime(seconds: 2 / Double(max(frameRate, 24)), preferredTimescale: 60_000)
        forwardReadLimit = isAllIntra ? CMTimeMultiply(forwardPreroll, multiplier: 2) : CMTime(value: 1, timescale: 3)
    }

    deinit { Self.sessions.removeObject(forKey: key) }

    func matches(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange) -> Bool {
        self.asset === asset && self.track.trackID == track.trackID && self.range == range
    }

    func frame(at requested: CMTime) throws -> CVPixelBuffer {
        if isAllIntra, let buffer = lock.withLock({ () -> CVPixelBuffer? in
            let state = readerSession()
            guard !state.intraReaderFailed else { return nil }
            let reader = state.intraReader ?? IntraFrameReader(asset: asset, track: track, pixelFormat: pixelFormat)
            state.intraReader = reader
            do {
                return try reader.frame(at: requested)
            } catch {
                state.intraReader = nil
                state.intraReaderFailed = true
                return nil
            }
        }) {
            return buffer
        }
        return try samples(at: requested).current.buffer
    }

    func samples(at requested: CMTime) throws -> (current: Sample, next: Sample?) {
        lock.lock()
        defer { lock.unlock() }
        let session = readerSession()
        let movingBackward = session.lastRequested.map { requested < $0 } ?? false
        session.lastRequested = requested
        if let index = session.frames.lastIndex(where: {
            $0.start == requested || ($0.start < requested && $0.end.map { requested < $0 } == true)
        }) {
            let frame = session.frames[index]
            let next = index + 1 < session.frames.count ? session.frames[index + 1] : nil
            return (sample(frame), next.map(sample))
        }
        let canContinue =
            session.reader?.status == .reading
            && session.frames.last.map {
                requested >= $0.start && requested - $0.start <= forwardReadLimit
            } == true
        if !canContinue {
            // A large forward scrub does not need an entire reverse history.
            // Keep a short preroll so non-frame-aligned requests still select
            // the preceding sample; retain the larger window for reverse.
            let preroll = movingBackward && !isAllIntra ? historyDuration : forwardPreroll
            try startReader(at: max(range.start, requested - preroll), in: session)
        }
        guard var output = session.output else { throw MetalRenderingError.sourceFrameUnavailable }
        var canRetryWithHistory = (!movingBackward || isAllIntra) && forwardPreroll < historyDuration
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer, sample.presentationTimeStamp.isNumeric else { continue }
            let start = sample.presentationTimeStamp
            let previous = session.frames.last
            if start > requested, previous == nil, canRetryWithHistory {
                // Variable-frame-rate sources can have a longer gap than the
                // nominal-frame-rate preroll. Retry before returning a frame
                // from the future.
                canRetryWithHistory = false
                try startReader(at: max(range.start, requested - historyDuration), in: session)
                guard let retryOutput = session.output else { throw MetalRenderingError.sourceFrameUnavailable }
                output = retryOutput
                continue
            }
            if let previous {
                guard start > previous.start else { continue }
                // Decoded samples can have invalid or unreliable duration
                // metadata. The next presentation timestamp closes this frame.
                session.frames[session.frames.count - 1].end = start
            }
            session.frames.append(Frame(buffer: buffer, start: start))
            if session.frames.count > historyCount { session.frames.removeFirst() }
            if start == requested { return (Sample(buffer: buffer, time: start), nil) }
            if start > requested {
                let next = Sample(buffer: buffer, time: start)
                return previous.map { (self.sample($0), next) } ?? (next, nil)
            }
        }
        if session.reader?.status == .completed, let last = session.frames.last {
            session.frames[session.frames.count - 1].end = range.end
            return (sample(last), nil)
        }
        throw session.reader?.error ?? MetalRenderingError.sourceFrameUnavailable
    }

    private func sample(_ frame: Frame) -> Sample {
        Sample(buffer: frame.buffer, time: frame.start)
    }

    private func readerSession() -> ReaderSession {
        if let cached = Self.sessions.object(forKey: key) { return cached }
        let session = ReaderSession()
        Self.sessions.setObject(session, forKey: key, cost: historyCost)
        return session
    }

    private func startReader(at start: CMTime, in session: ReaderSession) throws {
        session.reader?.cancelReading()
        session.frames.removeAll(keepingCapacity: true)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: range.end)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MetalRenderingError.sourceFrameUnavailable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MetalRenderingError.sourceFrameUnavailable }
        session.reader = reader
        session.output = output
    }
}

/// All-intra cache files can decode one compressed sample in a persistent
/// session. Recreating an AVAssetReader for each scrub jump is much slower.
private final class IntraFrameReader {
    private let generator: AVSampleBufferGenerator
    private let track: AVAssetTrack
    private let pixelFormat: OSType
    private var session: VTDecompressionSession?
    private var lastFrame: (time: CMTime, buffer: CVPixelBuffer)?

    init(asset: AVURLAsset, track: AVAssetTrack, pixelFormat: OSType) {
        generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
        self.track = track
        self.pixelFormat = pixelFormat
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func frame(at time: CMTime) throws -> CVPixelBuffer? {
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let sampleTime = cursor.presentationTimeStamp
        let duration = cursor.currentSampleDuration
        // A cursor can be approximate in an irregular edit. Use the reader
        // fallback if the identified frame does not cover this exact time.
        guard sampleTime.isNumeric, sampleTime <= time,
            sampleTime == time || (duration.isNumeric && time < sampleTime + duration)
        else { return nil }
        if let lastFrame, lastFrame.time == sampleTime { return lastFrame.buffer }

        let request = AVSampleBufferRequest(start: cursor)
        request.maxSampleCount = 1
        let sample = try generator.makeSampleBuffer(for: request)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        guard attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true,
            let format = sample.formatDescription, CMSampleBufferMakeDataReady(sample) == noErr else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        let decoder = try decoder(for: format)
        let output = OSAllocatedUnfairLock(uncheckedState: nil as CVPixelBuffer?)
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr { output.withLockUnchecked { $0 = image } }
        }
        guard status == noErr, let buffer = output.withLockUnchecked({ $0 }) else {
            throw MetalRenderingError.sourceFrameUnavailable
        }
        lastFrame = (sampleTime, buffer)
        return buffer
    }

    private func decoder(for format: CMFormatDescription) throws -> VTDecompressionSession {
        if let session {
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
                return session
            }
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var decoder: VTDecompressionSession?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &decoder)
        guard status == noErr, let decoder else { throw MetalRenderingError.sourceFrameUnavailable }
        session = decoder
        return decoder
    }
}
