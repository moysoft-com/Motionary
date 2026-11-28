@preconcurrency import AVFoundation
import CryptoKit

/// Audio proxies are optional during preview setup. Unstructured waiters
/// let the editor move on even if AVFoundation is blocked inside a reader.
struct PreviewAudioPreparation: Sendable {
    let deadline: ContinuousClock.Instant
    let onReady: (@Sendable () -> Void)?

    func wait<Value: Sendable>(for work: Task<Value, Error>) async throws -> Value? {
        let (results, continuation) = AsyncStream<Result<Value?, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        Task {
            let result = await work.result.map(Optional.some)
            if case .success = result {
                switch continuation.yield(result) {
                case .dropped, .terminated: onReady?()
                case .enqueued: break
                @unknown default: break
                }
            } else {
                continuation.yield(result)
            }
            continuation.finish()
        }
        let timeout = Task {
            do {
                try await ContinuousClock().sleep(until: deadline)
                continuation.yield(.success(nil))
                continuation.finish()
            } catch is CancellationError {
                return
            } catch {
                continuation.finish()
            }
        }
        defer {
            timeout.cancel()
            continuation.finish()
        }
        var iterator = results.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return try result.get()
    }
}

/// AVPlayer schedules a separate rate change for each edit in a speed curve.
/// Render those edits once, with their authored pitch, so playback and seeking
/// only have to start a single PCM stream. The same representation lets
/// extracted movie audio seek by sample without relying on container edit lists.
/// Gain automation stays on the item.
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

    static func directory(for source: URL) -> URL {
        root.appendingPathComponent(digest(source.standardizedFileURL.path), isDirectory: true)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(track: AVMutableCompositionTrack, clipID: UUID, source: URL, pitch: AVAudioTimePitchAlgorithm,
                        preparation: PreviewAudioPreparation) async throws -> Bool {
        let populated = track.segments.filter { !$0.isEmpty }
        guard let first = populated.first, let last = populated.last else { return true }
        let range = CMTimeRange(start: first.timeMapping.target.start, end: last.timeMapping.target.end)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var key = "complete-tail|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(pitch.rawValue)"
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
            guard let sourceURL = first.sourceURL, let snapshot = local.copy() as? AVComposition,
                let input = snapshot.track(withTrackID: audio.trackID)
            else { throw CocoaError(.fileReadCorruptFile) }
            let job = RenderJob(composition: snapshot, track: input, pitch: pitch,
                sourceURL: sourceURL, sourceTrackID: first.sourceTrackID, duration: range.duration, file: file)
            let work = await warmups.enqueue(job, for: clipID)
            guard try await preparation.wait(for: work) != nil else { return false }
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
        return true
    }

    /// Only immutable AVFoundation objects from the private snapshot cross executors.
    private struct RenderJob: @unchecked Sendable {
        let composition: AVComposition
        let track: AVCompositionTrack
        let pitch: AVAudioTimePitchAlgorithm
        let sourceURL: URL
        let sourceTrackID: CMPersistentTrackID
        let duration: CMTime
        let file: URL
    }

    /// Repeated edits to a long clip should warm only its latest mapping.
    private actor Warmups {
        private var pending: [UUID: (id: UUID, url: URL, task: Task<URL, Error>)] = [:]
        private var tail: (id: UUID, task: Task<URL, Error>)?

        func enqueue(_ job: RenderJob, for clipID: UUID) -> Task<URL, Error> {
            if let pending = pending[clipID], pending.url == job.file { return pending.task }
            pending[clipID]?.task.cancel()
            let id = UUID()
            let previous = tail?.task
            let task = Task.detached(priority: .utility) {
                _ = await previous?.result
                try Task.checkCancellation()
                try await materialize(job)
                return job.file
            }
            tail = (id, task)
            pending[clipID] = (id, job.file, task)
            Task {
                _ = await task.result
                if pending[clipID]?.id == id { pending[clipID] = nil }
                if tail?.id == id { tail = nil }
            }
            return task
        }
    }

    private static func materialize(_ job: RenderJob) async throws {
        try Task.checkCancellation()
        let file = job.file
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let format = try await sourceFormat(for: job)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let estimatedBytes = job.duration.seconds * max(48_000, format.sampleRate)
            * Double(format.channelCount) * 4
        if let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
            estimatedBytes > Double(capacity) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let temporary = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let edits = job.track.segments.filter { !$0.isEmpty }
        let hasExtremeRate = edits.contains {
            let pace = $0.timeMapping.source.duration.seconds / $0.timeMapping.target.duration.seconds
            return pace < 0.25 || pace > 4
        }
        let requiresDirectMapping = edits.count > 32
            || (hasExtremeRate && (edits.count > 1 || job.pitch == .varispeed))
        var usedNativePitch = false
        if !requiresDirectMapping {
            let candidate = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
            defer { try? FileManager.default.removeItem(at: candidate) }
            let budget = min(max(job.duration.seconds * 0.1, 3), 20)
            let work = Task.detached(priority: .utility) {
                defer { if Task.isCancelled { try? FileManager.default.removeItem(at: candidate) } }
                try write(composition: job.composition, track: job.track, pitch: job.pitch, format: format,
                    duration: job.duration, to: candidate)
                return candidate
            }
            defer { work.cancel() }
            let wait = PreviewAudioPreparation(deadline: .now + .seconds(budget), onReady: nil)
            if (try? await wait.wait(for: work)) != nil {
                try FileManager.default.moveItem(at: candidate, to: temporary)
                usedNativePitch = true
            }
        }
        try Task.checkCancellation()
        if !usedNativePitch {
            try await PreviewMappedAudio.write(edits: edits, format: format, duration: job.duration, to: temporary)
        }
        try Task.checkCancellation()
        do { try FileManager.default.moveItem(at: temporary, to: file) }
        catch where FileManager.default.fileExists(atPath: file.path) { /* Another build published the cache. */ }
    }

    private static func sourceFormat(for job: RenderJob) async throws -> AVAudioFormat {
        // Read the original layout. A composition track can report mono
        // even when the AAC decoder produces parametric stereo.
        let asset = AVURLAsset(url: job.sourceURL)
        guard let original = try await asset.loadTrack(withTrackID: job.sourceTrackID),
            let description = try await original.load(.formatDescriptions).first
        else { throw CocoaError(.fileReadCorruptFile) }
        let encoded = AVAudioFormat(cmAudioFormatDescription: description)
        guard encoded.sampleRate > 0, encoded.channelCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let isAAC = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2]
            .contains(encoded.streamDescription.pointee.mFormatID)
        if isAAC, encoded.channelCount == 1,
            let stereo = AVAudioFormat(standardFormatWithSampleRate: max(48_000, encoded.sampleRate), channels: 2)
        {
            return stereo
        }
        return encoded
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
        guard reader.status == .completed, file.framePosition > 0 else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        // The requested range ends at the last populated edit. Permit small
        // decoder rounding, but never publish a cache with a missing tail.
        let tailTolerance = Int64(ceil(sampleRate * 0.05))
        guard total - file.framePosition <= tailTolerance else { throw CocoaError(.fileReadCorruptFile) }
        try pad(to: total)
    }
}
