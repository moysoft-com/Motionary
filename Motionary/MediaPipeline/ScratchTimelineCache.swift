@preconcurrency import AVFoundation
import Foundation
import Darwin
import Synchronization

/// Prepared PCM on disk keeps arbitrary scratch jumps independent of AAC/GOP
/// decoding. Only a bounded float window is copied into realtime memory.
final class ScratchTimelineCache: @unchecked Sendable {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-mix-\(UUID()).pcm")
    private let cancelled = Atomic<Bool>(false)
    private let readyFrames = Atomic<Int64>(0)
    private let totalFrames: Int64
    private let queue = DispatchQueue(label: "com.moysoft.motionary.scratch-pcm-cache", qos: .utility)

    init(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?, duration: Double,
         onReady: @escaping @Sendable () -> Void = {}) {
        totalFrames = Int64(max(duration, 0) * ScratchSampleBank.sampleRate)
        queue.async { [self] in
            do {
                guard !cancelled.load(ordering: .acquiring), totalFrames > 0 else { return }
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.truncate(atOffset: UInt64(totalFrames) * 8)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: ScratchSampleBank.sampleRate,
                    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
                ])
                output.audioMix = audioMix
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return }
                reader.add(output)
                guard reader.startReading() else { return }
                defer { reader.cancelReading() }
                while !cancelled.load(ordering: .acquiring), let sample = output.copyNextSampleBuffer() {
                    try autoreleasepool {
                        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        guard time.isFinite else { return }
                        let first = max(0, Int64((time * ScratchSampleBank.sampleRate).rounded()))
                        let frames = min(Int64(CMSampleBufferGetNumSamples(sample)), totalFrames - first)
                        guard frames > 0 else { return }
                        var data = Data(count: Int(frames) * 8)
                        let status = data.withUnsafeMutableBytes {
                            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                        }
                        guard status == kCMBlockBufferNoErr else { return }
                        try file.seek(toOffset: UInt64(first) * 8)
                        try file.write(contentsOf: data)
                        readyFrames.store(first + frames, ordering: .releasing)
                    }
                }
                if reader.status == .completed, !cancelled.load(ordering: .acquiring) {
                    readyFrames.store(totalFrames, ordering: .releasing)
                    onReady()
                }
            } catch {
                // The small foreground decoder remains available if storage
                // is unavailable. Never block timeline interaction on caching.
                AppLogger.media.debug("Scratch PCM cache unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }
    func cancel() { cancelled.store(true, ordering: .releasing) }

    func fill(bank: ScratchSampleBank, slot: Int, around time: Double) -> Bool {
        guard time.isFinite, !cancelled.load(ordering: .acquiring) else { return false }
        let target = Int64(time * ScratchSampleBank.sampleRate)
        let first = max(0, target - Int64(ScratchSampleBank.capacity / 2))
        let end = min(totalFrames, min(first + Int64(ScratchSampleBank.capacity), readyFrames.load(ordering: .acquiring)))
        guard target >= first, target < end - 1 else { return false }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let frames = Int(end - first)
            let byteCount = frames * 8
            let destination = UnsafeMutableRawPointer(bank.slots[slot].samples)
            var copied = 0
            while copied < byteCount {
                let count = pread(file.fileDescriptor, destination.advanced(by: copied), byteCount - copied,
                                  off_t(first * 8) + off_t(copied))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                copied += count
            }
            bank.publish(slot: slot, start: first, count: frames)
            return true
        } catch { return false }
    }
}
