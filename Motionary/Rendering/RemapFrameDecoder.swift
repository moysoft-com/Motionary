@preconcurrency import AVFoundation
import Foundation

/// Reads native video buffers for arbitrary source times. A small window of
/// preceding frames makes backward playback use sequential decoder reads.
final class RemapFrameDecoder: @unchecked Sendable {
    private struct Frame {
        let buffer: CVPixelBuffer
        let start: CMTime
        var end: CMTime?
    }

    private final class ReaderSession {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var frames: [Frame] = []

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
    private let historyCost: Int

    init(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, rawSize: CGSize, frameRate: Float) {
        self.asset = asset
        self.track = track
        self.range = range
        let estimatedBytes = max(rawSize.width * rawSize.height * 1.5, 1)
        historyCount = Int(min(max((28 * 1024 * 1024) / estimatedBytes, 3), 20))
        historyCost = Int(estimatedBytes) * historyCount
        historyDuration = CMTime(
            seconds: Double(historyCount - 1) / Double(max(frameRate, 24)),
            preferredTimescale: 60_000)
    }

    deinit { Self.sessions.removeObject(forKey: key) }

    func frame(at requested: CMTime) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        let session: ReaderSession
        if let cached = Self.sessions.object(forKey: key) {
            session = cached
        } else {
            session = ReaderSession()
            Self.sessions.setObject(session, forKey: key, cost: historyCost)
        }
        if let frame = session.frames.last(where: {
            $0.start == requested || ($0.start < requested && $0.end.map { requested < $0 } == true)
        }) {
            return frame.buffer
        }
        let canContinue =
            session.reader?.status == .reading
            && session.frames.last.map {
                requested >= $0.start && requested - $0.start <= CMTime(value: 1, timescale: 3)
            } == true
        if !canContinue {
            try startReader(at: max(range.start, requested - historyDuration), in: session)
        }
        guard let output = session.output else { throw MetalRenderingError.sourceFrameUnavailable }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer, sample.presentationTimeStamp.isNumeric else { continue }
            let start = sample.presentationTimeStamp
            let previous = session.frames.last
            if let previous {
                guard start > previous.start else { continue }
                // Decoded samples can have invalid or unreliable duration
                // metadata. The next presentation timestamp closes this frame.
                session.frames[session.frames.count - 1].end = start
            }
            session.frames.append(Frame(buffer: buffer, start: start))
            if session.frames.count > historyCount { session.frames.removeFirst() }
            if start == requested { return buffer }
            if start > requested { return previous?.buffer ?? buffer }
        }
        if session.reader?.status == .completed, let last = session.frames.last {
            session.frames[session.frames.count - 1].end = range.end
            return last.buffer
        }
        throw session.reader?.error ?? MetalRenderingError.sourceFrameUnavailable
    }

    private func startReader(at start: CMTime, in session: ReaderSession) throws {
        session.reader?.cancelReading()
        session.frames.removeAll(keepingCapacity: true)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: start, end: range.end)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MetalRenderingError.sourceFrameUnavailable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MetalRenderingError.sourceFrameUnavailable }
        session.reader = reader
        session.output = output
    }
}
