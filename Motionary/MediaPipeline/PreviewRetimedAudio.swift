@preconcurrency import AVFoundation
import CryptoKit

/// AVPlayer schedules a separate rate change for each edit in a speed curve.
/// Render those edits once, with their authored pitch, so playback and seeking
/// only have to start a single PCM stream. Gain automation stays on the item.
enum PreviewRetimedAudio {
    private static let root: URL = {
        let folder = URL.cachesDirectory.appendingPathComponent("MotionaryRetimedAudio-v2", isDirectory: true)
        // Sweep once before this process hands out any cache URLs.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) {
            let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
            for case let url as URL in files {
                if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                    let modified = values.contentModificationDate, modified < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        return folder
    }()
    private static let warmups = Warmups()
    private static let foregroundWriter = Writer()

    static func directory(for source: URL) -> URL {
        root.appendingPathComponent(digest(source.standardizedFileURL.path), isDirectory: true)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(track: AVMutableCompositionTrack, clipID: UUID, source: URL, pitch: AVAudioTimePitchAlgorithm,
                        coldSecondsRemaining: inout Double) async throws {
        let populated = track.segments.filter { !$0.isEmpty }
        guard let first = populated.first, let last = populated.last,
            populated.contains(where: { $0.timeMapping.source.duration != $0.timeMapping.target.duration })
        else { return }
        let range = CMTimeRange(start: first.timeMapping.target.start, end: last.timeMapping.target.end)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var key = "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(pitch.rawValue)"
        let local = AVMutableComposition()
        guard let audio = local.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        // insertTimeRange(of:) may flatten nested composition edits differently.
        // Preserve each original mapping, including reverse assets and silent gaps.
        var segments: [AVCompositionTrackSegment] = []
        var cursor = CMTime.zero
        for segment in populated {
            guard let url = segment.sourceURL else { throw CocoaError(.fileReadCorruptFile) }
            let mapping = segment.timeMapping
            let target = CMTimeRange(start: mapping.target.start - range.start, duration: mapping.target.duration)
            key += "|\(url.path)|\(segment.sourceTrackID)|\(mapping.source.start.seconds)|\(mapping.source.duration.seconds)|\(target.start.seconds)|\(target.duration.seconds)"
            if target.start > cursor {
                segments.append(AVCompositionTrackSegment(timeRange: CMTimeRange(start: cursor, end: target.start)))
            }
            segments.append(AVCompositionTrackSegment(url: url, trackID: segment.sourceTrackID,
                sourceTimeRange: mapping.source, targetTimeRange: target))
            cursor = target.end
        }
        let folder = directory(for: source)
        let file = folder.appendingPathComponent(digest(key)).appendingPathExtension("caf")
        if !FileManager.default.fileExists(atPath: file.path) {
            try audio.validateSegments(segments)
            audio.segments = segments
            // A composition track can advertise a default mono format even
            // for a stereo source. Read the actual asset's channel layout.
            guard let sourceURL = first.sourceURL else { throw CocoaError(.fileReadCorruptFile) }
            let asset = AVURLAsset(url: sourceURL)
            guard let original = try await asset.loadTrack(withTrackID: first.sourceTrackID),
                let description = try await original.load(.formatDescriptions).first
            else { throw CocoaError(.fileReadCorruptFile) }
            let encoded = AVAudioFormat(cmAudioFormatDescription: description)
            // A mono AAC core may carry parametric stereo. Asking the decoder
            // for stereo preserves both channels even when Core Media exposes
            // only the core format in the track description.
            let isAAC = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2]
                .contains(encoded.streamDescription.pointee.mFormatID)
            let format = isAAC && encoded.channelCount == 1
                ? AVAudioFormat(standardFormatWithSampleRate: max(48_000, encoded.sampleRate), channels: 2) ?? encoded
                : encoded
            guard format.sampleRate > 0, format.channelCount > 0
            else { throw CocoaError(.fileReadCorruptFile) }
            guard let snapshot = local.copy() as? AVComposition,
                let input = snapshot.track(withTrackID: audio.trackID)
            else { throw CocoaError(.fileReadCorruptFile) }
            let job = RenderJob(composition: snapshot, track: input, pitch: pitch, format: format,
                                duration: range.duration, file: file)
            // Never put an entire long project on the cold-open critical path.
            // The native edits remain available while a serial worker warms
            // the disk cache for the next graph.
            guard range.duration.seconds <= coldSecondsRemaining else {
                await warmups.enqueue(job, for: clipID)
                return
            }
            coldSecondsRemaining -= range.duration.seconds
            try await foregroundWriter.materialize(job)
        }
        let asset = AVURLAsset(url: file)
        guard let pcm = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let pcmRange = try await pcm.load(.timeRange)
        guard pcmRange.duration.isNumeric, abs((pcmRange.duration - range.duration).seconds) < 0.001 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var replacement: [AVCompositionTrackSegment] = []
        if range.start > .zero {
            replacement.append(AVCompositionTrackSegment(timeRange: CMTimeRange(start: .zero, duration: range.start)))
        }
        replacement.append(AVCompositionTrackSegment(url: file, trackID: pcm.trackID,
            sourceTimeRange: CMTimeRange(start: pcmRange.start, duration: min(range.duration, pcmRange.duration)),
            targetTimeRange: range))
        try track.validateSegments(replacement)
        try Task.checkCancellation()
        track.segments = replacement
    }

    /// Only immutable AVFoundation objects from the private snapshot cross executors.
    private struct RenderJob: @unchecked Sendable {
        let composition: AVComposition
        let track: AVCompositionTrack
        let pitch: AVAudioTimePitchAlgorithm
        let format: AVAudioFormat
        let duration: CMTime
        let file: URL
    }

    /// Repeated edits to a long clip should warm only its latest mapping.
    private actor Warmups {
        private let writer = Writer()
        private var pending: [UUID: (url: URL, task: Task<Void, Never>)] = [:]

        func enqueue(_ job: RenderJob, for clipID: UUID) {
            guard pending[clipID]?.url != job.file else { return }
            pending[clipID]?.task.cancel()
            let task = Task(priority: .utility) {
                try? await writer.materialize(job)
                if pending[clipID]?.url == job.file, !Task.isCancelled { pending[clipID] = nil }
            }
            pending[clipID] = (job.file, task)
        }
    }

    private actor Writer {
        func materialize(_ job: RenderJob) throws {
            try Task.checkCancellation()
            let file = job.file
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let estimatedBytes = job.duration.seconds * max(48_000, job.format.sampleRate)
                * Double(job.format.channelCount) * 4
            if let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
                estimatedBytes > Double(capacity) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let temporary = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try write(composition: job.composition, track: job.track, pitch: job.pitch, format: job.format,
                      duration: job.duration, to: temporary)
            do { try FileManager.default.moveItem(at: temporary, to: file) }
            catch where FileManager.default.fileExists(atPath: file.path) { /* Already published by the other queue. */ }
        }
    }

    private static func write(composition: AVComposition, track: AVCompositionTrack,
                              pitch: AVAudioTimePitchAlgorithm, format: AVAudioFormat,
                              duration: CMTime, to url: URL) throws {
        let reader = try AVAssetReader(asset: composition)
        let sampleRate = max(48_000, format.sampleRate)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: format.channelCount,
            AVSampleRateKey: sampleRate, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        if let layout = format.settings[AVChannelLayoutKey] { settings[AVChannelLayoutKey] = layout }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = pitch
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let total = Int64(ceil(duration.seconds * sampleRate))
        func pad(to target: Int64) throws {
            while file.framePosition < target {
                try Task.checkCancellation()
                buffer.frameLength = AVAudioFrameCount(min(Int64(buffer.frameCapacity), target - file.framePosition))
                let bytes = buffer.mutableAudioBufferList.pointee.mBuffers
                if let data = bytes.mData { memset(data, 0, Int(bytes.mDataByteSize)) }
                try file.write(from: buffer)
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard sample.presentationTimeStamp.isNumeric else { throw CocoaError(.fileReadCorruptFile) }
            let start = Int64((sample.presentationTimeStamp.seconds * sampleRate).rounded())
            try pad(to: min(total, start))
            var offset = Int(max(0, file.framePosition - start))
            while offset < sample.numSamples, file.framePosition < total {
                let count = min(Int(buffer.frameCapacity), sample.numSamples - offset, Int(total - file.framePosition))
                buffer.frameLength = AVAudioFrameCount(count)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset),
                    frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
                try file.write(from: buffer)
                offset += count
            }
        }
        guard reader.status == .completed, file.framePosition > 0 else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        try pad(to: total)
    }
}
