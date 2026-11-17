@preconcurrency import AVFoundation
import Darwin
import Foundation
import Synchronization

/// Materialize the audio mix sequentially so jumping across the timeline only
/// needs a bounded PCM copy once the cache reaches that position.
final class ScratchTimelineCache: @unchecked Sendable {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-mix-\(UUID()).pcm")
    private let cancelled = Atomic<Bool>(false)
    private let readyFrames = Atomic<Int64>(0)
    private let totalFrames: Int64

    init(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?, duration: Double,
         queue: DispatchQueue = DispatchQueue(label: "com.moysoft.motionary.scratch-pcm-cache", qos: .utility),
         onReady: @escaping @Sendable () -> Void = {}) {
        totalFrames = duration.isFinite ? Int64(max(duration, 0) * ScratchSampleBank.sampleRate) : 0
        queue.async { [self] in
            do {
                guard !cancelled.load(ordering: .acquiring), totalFrames > 1 else { return }
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                let stride = ScratchWindowDecoder.bytesPerFrame
                let notificationInterval = Int64(ScratchSampleBank.sampleRate / 4)
                var lastNotifiedFrame: Int64 = 0
                // Timeline gaps and the tail after the last source are silent.
                try file.truncate(atOffset: UInt64(totalFrames) * UInt64(stride))
                let complete = try ScratchWindowDecoder.readPCM(
                    asset: asset, tracks: tracks, audioMix: audioMix, start: 0, end: totalFrames,
                    shouldContinue: { !cancelled.load(ordering: .acquiring) }
                ) { block, skip, position, frames in
                    var samples = Data(count: frames * stride)
                    try samples.withUnsafeMutableBytes { bytes in
                        try ScratchWindowDecoder.copy(block, skip: skip, frames: frames, to: bytes.baseAddress!)
                    }
                    try file.seek(toOffset: UInt64(position) * UInt64(stride))
                    try file.write(contentsOf: samples)
                    let available = position + Int64(frames)
                    readyFrames.store(available, ordering: .releasing)
                    if available - lastNotifiedFrame >= notificationInterval {
                        lastNotifiedFrame = available
                        onReady()
                    }
                }
                guard complete, !cancelled.load(ordering: .acquiring) else { return }
                readyFrames.store(totalFrames, ordering: .releasing)
                onReady()
            } catch {
                // A demand read can still serve this position if warming fails.
                AppLogger.media.debug("Scratch PCM cache unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func cancel() { cancelled.store(true, ordering: .releasing) }

    func contains(_ time: Double) -> Bool {
        !cancelled.load(ordering: .acquiring)
            && time * ScratchSampleBank.sampleRate < Double(readyFrames.load(ordering: .acquiring) - 1)
    }

    func fill(bank: ScratchSampleBank, slot: Int, around time: Double, rate: Double = 0, generation: Int = 0,
              shouldPublish: (Int64, Int) -> Bool = { _, _ in true }) -> Bool {
        guard time.isFinite, !cancelled.load(ordering: .acquiring) else { return false }
        let target = Int64(time * ScratchSampleBank.sampleRate)
        let first = max(0, target - Int64(ScratchSampleBank.capacity / 2))
        let ready = readyFrames.load(ordering: .acquiring)
        let end = min(first + Int64(ScratchSampleBank.capacity), ready)
        guard target >= first, target < end - 1 else { return false }
        // Close to a moving cache frontier, the short demand read has more
        // forward coverage than a copy of the currently prepared prefix.
        let forwardHeadroom = Int64(0.25 * ScratchSampleBank.sampleRate)
        guard rate <= 0 || ready == totalFrames || target + forwardHeadroom < end else { return false }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let stride = ScratchWindowDecoder.bytesPerFrame
            let frames = Int(end - first)
            let byteCount = frames * stride
            let destination = UnsafeMutableRawPointer(bank.slots[slot].samples)
            var copied = 0
            while copied < byteCount {
                let count = pread(file.fileDescriptor, destination.advanced(by: copied), byteCount - copied,
                                  off_t(first) * off_t(stride) + off_t(copied))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                copied += count
            }
            guard !cancelled.load(ordering: .acquiring), shouldPublish(first, frames) else { return false }
            bank.publish(slot: slot, start: first, count: frames, generation: generation)
            return true
        } catch {
            return false
        }
    }
}
