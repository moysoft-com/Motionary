@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Caches one sample-reversed audio asset per source. Timing and pitch remain
/// ordinary AVFoundation composition edits, so adjusting a keyframe reuses it.
actor ReversedAudioStore {
    static let shared = ReversedAudioStore()

    private var pending: [URL: Task<Void, Error>] = [:]

    func reversedURL(for url: URL, track: AVAssetTrack, range: CMTimeRange) async throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity =
            "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(track.trackID)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = URL.cachesDirectory.appendingPathComponent("MotionaryReversedAudio-v1", isDirectory: true)
        let destination = directory.appendingPathComponent(digest).appendingPathExtension("caf")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let task = pending[destination] {
            try await task.value
            return destination
        }
        let trackID = track.trackID
        let task = Task.detached(priority: .userInitiated) {
            try await Self.writeReversedAudio(from: url, trackID: trackID, range: range, to: destination)
        }
        pending[destination] = task
        defer { pending[destination] = nil }
        try await task.value
        return destination
    }

    private static func writeReversedAudio(
        from url: URL, trackID: CMPersistentTrackID,
        range: CMTimeRange, to destination: URL
    ) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == trackID }),
            let description = try await track.load(.formatDescriptions).first,
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: stream.mChannelsPerFrame)
        else { throw CocoaError(.fileReadCorruptFile) }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent(UUID().uuidString)
        let temporary = raw.appendingPathExtension("caf")
        defer {
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.removeItem(at: temporary)
        }
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let spool = try FileHandle(forUpdating: raw)
        defer { try? spool.close() }
        let channels = Int(format.channelCount)
        let bytesPerFrame = MemoryLayout<Float>.stride * channels
        let frames = Int64((range.duration.seconds * format.sampleRate).rounded())
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try spool.truncate(atOffset: UInt64(frames) * UInt64(bytesPerFrame))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        while let sample = output.copyNextSampleBuffer() {
            let start = Int64(((sample.presentationTimeStamp - range.start).seconds * format.sampleRate).rounded())
            let first = max(start, 0)
            let count = min(frames - first, Int64(sample.numSamples) - (first - start))
            guard count > 0 else { continue }
            guard let block = sample.dataBuffer else { throw CocoaError(.fileReadCorruptFile) }
            var data = Data(count: Int(count) * bytesPerFrame)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: Int(first - start) * bytesPerFrame,
                    dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw CocoaError(.fileReadCorruptFile) }
            try spool.seek(toOffset: UInt64(first) * UInt64(bytesPerFrame))
            try spool.write(contentsOf: data)
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let capacity = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
                let destinationChannels = buffer.floatChannelData
            else { throw CocoaError(.fileWriteUnknown) }
            var end = frames
            while end > 0 {
                let count = min(Int(end), capacity)
                end -= Int64(count)
                try spool.seek(toOffset: UInt64(end) * UInt64(bytesPerFrame))
                guard let data = try spool.read(upToCount: count * bytesPerFrame),
                    data.count == count * bytesPerFrame
                else { throw CocoaError(.fileReadCorruptFile) }
                data.withUnsafeBytes { bytes in
                    let source = bytes.bindMemory(to: Float.self)
                    for channel in 0..<channels {
                        for frame in 0..<count {
                            destinationChannels[channel][frame] = source[(count - frame - 1) * channels + channel]
                        }
                    }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
