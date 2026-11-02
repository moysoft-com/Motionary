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
    }
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

    func frame(at time: Double, sessionID: UUID, revision: UInt64) -> CVPixelBuffer? {
        guard let key = key(at: time, sessionID: sessionID, revision: revision) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = frames[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.frame
    }

    func store(_ frame: CVPixelBuffer, at time: Double, sessionID: UUID, revision: UInt64) {
        guard let key = key(at: time, sessionID: sessionID, revision: revision) else { return }
        let cost = CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame)
        guard cost > 0, cost <= byteLimit else { return }
        lock.lock()
        defer { lock.unlock() }
        if let previous = frames.removeValue(forKey: key) { bytes -= previous.bytes }
        recency.removeAll { $0 == key }
        while bytes + cost > byteLimit || frames.count >= countLimit, let oldest = recency.first {
            recency.removeFirst()
            if let removed = frames.removeValue(forKey: oldest) { bytes -= removed.bytes }
        }
        frames[key] = Entry(frame: frame, bytes: cost)
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

    private func key(at time: Double, sessionID: UUID, revision: UInt64) -> Key? {
        guard time.isFinite, time >= 0, time < Double(Int64.max) / 600 else { return nil }
        return Key(sessionID: sessionID, revision: revision, time: Int64((time * 600).rounded()))
    }
}
