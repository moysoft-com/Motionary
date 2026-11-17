import CoreVideo
import Foundation
import UIKit

/// Completed GPU output only: reverse scrubs reuse the exact effect result,
/// without decoding, CPU readback, rescaling or running the stack again.
final class PreviewFrameCache: @unchecked Sendable {
    private struct Key: Hashable {
        let sessionID: UUID
        let revision: UInt64
        let time: Int64
    }
    private struct Entry {
        let frame: CVPixelBuffer
        let bytes: Int
        let isScrubFrame: Bool
    }
    private static let timeScale = 600_000.0
    private let lock = NSLock()
    private var frames: [Key: Entry] = [:]
    private var recency: [Key] = []
    private var bytes = 0
    let byteLimit: Int
    private let countLimit: Int
    private var memoryWarning: NSObjectProtocol?

    init(byteLimit: Int = Int(min(max(ProcessInfo.processInfo.physicalMemory / 48,
                                    32 * 1_024 * 1_024), 128 * 1_024 * 1_024)), countLimit: Int = 120) {
        self.byteLimit = max(byteLimit, 0)
        self.countLimit = max(countLimit, 1)
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.removeAll() }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    func frame(at time: Double, sessionID: UUID, revision: UInt64, allowsScrubFrames: Bool = false) -> CVPixelBuffer? {
        guard let key = key(at: time, sessionID: sessionID, revision: revision) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = frames[key], allowsScrubFrames || !entry.isScrubFrame else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.frame
    }

    /// The composed frame closest to `time` within `window` seconds in
    /// the requested revision. This is a display fallback for scrubbing, not an exact-time
    /// substitute: callers must still seek to the requested time afterwards.
    /// Exact-time evaluation keeps using `frame(at:...)`.
    func frameNear(at time: Double, sessionID: UUID, window: Double, revision: UInt64, allowsScrubFrames: Bool = false)
        -> (frame: CVPixelBuffer, time: Double)?
    {
        guard time.isFinite, time >= 0, window >= 0, window < Double(Int64.max / 2) / Self.timeScale else { return nil }
        guard time < Double(Int64.max) / Self.timeScale else { return nil }
        let queryTime = Int64((time * Self.timeScale).rounded())
        let windowTicks = Int64((window * Self.timeScale).rounded()) + 1
        lock.lock()
        defer { lock.unlock() }
        var bestKey: Key?
        var bestDistance = Int64.max
        for (key, entry) in frames where key.sessionID == sessionID && key.revision == revision
            && (allowsScrubFrames || !entry.isScrubFrame)
        {
            let distance = abs(key.time - queryTime)
            guard distance <= windowTicks else { continue }
            if distance < bestDistance || (distance == bestDistance && key.time < (bestKey?.time ?? Int64.max))
            {
                bestKey = key
                bestDistance = distance
            }
        }
        guard let key = bestKey, let entry = frames[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return (entry.frame, Double(key.time) / Self.timeScale)
    }

    func store(_ frame: CVPixelBuffer, at time: Double, sessionID: UUID, revision: UInt64, isScrubFrame: Bool = false) {
        guard let key = key(at: time, sessionID: sessionID, revision: revision) else { return }
        let cost = CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame)
        guard cost > 0, cost <= byteLimit else { return }
        lock.lock()
        defer { lock.unlock() }
        // A late scrub render must not replace the full-quality result for this time.
        if isScrubFrame, frames[key]?.isScrubFrame == false { return }
        if let previous = frames.removeValue(forKey: key) { bytes -= previous.bytes }
        recency.removeAll { $0 == key }
        // Under thermal pressure the same composed frames only evict sooner;
        // nothing about which pixels are produced changes.
        let effective = effectiveLimits()
        while bytes + cost > effective.byteLimit || frames.count >= effective.countLimit, let oldest = recency.first {
            recency.removeFirst()
            if let removed = frames.removeValue(forKey: oldest) { bytes -= removed.bytes }
        }
        frames[key] = Entry(frame: frame, bytes: cost, isScrubFrame: isScrubFrame)
        recency.append(key)
        bytes += cost
    }

    func removeAll() {
        lock.lock()
        frames.removeAll()
        recency.removeAll()
        bytes = 0
        lock.unlock()
    }

    /// Preserve the LRU order and memory accounting when an edit only
    /// changes pixels in one timeline interval.
    func advanceRevision(from oldRevision: UInt64, to newRevision: UInt64,
                         invalidating affectedTimeRange: ClosedRange<Double>) {
        lock.lock()
        defer { lock.unlock() }
        recency = recency.compactMap { oldKey in
            guard let entry = frames.removeValue(forKey: oldKey) else { return nil }
            let time = Double(oldKey.time) / Self.timeScale
            guard oldKey.revision == oldRevision, !affectedTimeRange.contains(time) else {
                bytes -= entry.bytes
                return nil
            }
            let key = Key(sessionID: oldKey.sessionID, revision: newRevision, time: oldKey.time)
            frames[key] = entry
            return key
        }
    }

    private func effectiveLimits() -> (byteLimit: Int, countLimit: Int) {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return (min(byteLimit, 64 * 1_024 * 1_024), min(countLimit, 60))
        case .fair:
            return (min(byteLimit, 96 * 1_024 * 1_024), min(countLimit, 90))
        default:
            return (byteLimit, countLimit)
        }
    }

    private func key(at time: Double, sessionID: UUID, revision: UInt64) -> Key? {
        guard time.isFinite, time >= 0, time < Double(Int64.max) / Self.timeScale else { return nil }
        return Key(sessionID: sessionID, revision: revision, time: Int64((time * Self.timeScale).rounded()))
    }
}
