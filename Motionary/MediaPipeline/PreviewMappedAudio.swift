@preconcurrency import AVFoundation
import Foundation

/// AVFoundation can stop delivering audio when rapid rate changes are sent
/// through one composition reader. Decode each source at its original rate,
/// then evaluate the authored edit mappings into bounded PCM windows.
enum PreviewMappedAudio {
    private struct Source: Hashable {
        let url: URL
        let trackID: CMPersistentTrackID
    }

    private struct PCM {
        let file: AVAudioFile
        let start: CMTime
    }

    static func write(
        edits: [AVCompositionTrackSegment], format: AVAudioFormat, duration: CMTime, to url: URL
    ) async throws {
        let rate = max(48_000, format.sampleRate)
        let channels = Int(format.channelCount)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels,
            AVSampleRateKey: rate, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ]
        if let layout = format.settings[AVChannelLayoutKey] { settings[AVChannelLayoutKey] = layout }
        var ranges: [Source: CMTimeRange] = [:]
        for edit in edits {
            guard let url = edit.sourceURL else { throw CocoaError(.fileReadCorruptFile) }
            let source = Source(url: url, trackID: edit.sourceTrackID)
            let range = edit.timeMapping.source
            ranges[source] = ranges[source].map { $0.union(range) } ?? range
        }
        var temporaryFiles: [URL] = []
        defer { for file in temporaryFiles { try? FileManager.default.removeItem(at: file) } }
        var sources: [Source: PCM] = [:]
        for (source, range) in ranges {
            try Task.checkCancellation()
            let file = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
            temporaryFiles.append(file)
            try await decode(source, range: range, settings: settings, to: file)
            sources[source] = PCM(file: try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32,
                interleaved: true), start: range.start)
        }

        let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: true)
        guard let input = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 16_384),
            let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 2048)
        else { throw CocoaError(.fileWriteUnknown) }

        let total = Int64(ceil(duration.seconds * rate))
        for edit in edits {
            try Task.checkCancellation()
            guard let url = edit.sourceURL,
                let source = sources[Source(url: url, trackID: edit.sourceTrackID)]
            else { throw CocoaError(.fileReadCorruptFile) }
            let mapping = edit.timeMapping
            let start = frames(mapping.target.start, at: rate)
            let end = min(frames(mapping.target.end, at: rate), total)
            guard end > max(start, output.framePosition), source.file.length > 0 else { continue }
            try pad(output, to: start, buffer: buffer)
            let first = (mapping.source.start - source.start).seconds * rate
            let step = mapping.source.duration.seconds * rate / Double(end - start)
            while output.framePosition < end {
                try Task.checkCancellation()
                let available = Int(end - output.framePosition)
                let limit = min(Double(buffer.frameCapacity), Double(input.frameCapacity - 2) / max(step, 1))
                let count = min(available, max(1, Int(limit)))
                let position = first + Double(output.framePosition - start) * step
                let inputStart = min(max(Int64(floor(position)), 0), source.file.length - 1)
                let inputEnd = min(Int64(floor(position + Double(count - 1) * step)) + 2, source.file.length)
                source.file.framePosition = inputStart
                try source.file.read(into: input, frameCount: AVAudioFrameCount(max(inputEnd - inputStart, 1)))
                guard input.frameLength > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                guard let samples = floatSamples(input), let destination = floatSamples(buffer)
                else { throw CocoaError(.fileWriteUnknown) }
                let last = Int(input.frameLength) - 1
                for index in 0..<count {
                    let offset = min(max(position - Double(inputStart) + Double(index) * step, 0), Double(last))
                    let a = Int(offset)
                    let b = min(a + 1, last)
                    let weight = Float(offset - Double(a))
                    for channel in 0..<channels {
                        let x = samples[a * channels + channel]
                        destination[index * channels + channel] = x + (samples[b * channels + channel] - x) * weight
                    }
                }
                try output.write(from: buffer)
            }
        }
        try pad(output, to: total, buffer: buffer)
    }

    private static func decode(_ source: Source, range: CMTimeRange, settings: [String: Any], to url: URL) async throws {
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTrack(withTrackID: source.trackID)
        else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        else { throw CocoaError(.fileWriteUnknown) }
        let rate = file.processingFormat.sampleRate
        let total = Int64(ceil(range.duration.seconds * rate))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard sample.presentationTimeStamp.isNumeric else { continue }
            let start = frames(sample.presentationTimeStamp - range.start, at: rate)
            try pad(file, to: min(total, start), buffer: buffer)
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
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        try pad(file, to: total, buffer: buffer)
    }

    private static func frames(_ time: CMTime, at rate: Double) -> Int64 {
        Int64((time.seconds * rate).rounded())
    }

    private static func floatSamples(_ buffer: AVAudioPCMBuffer) -> UnsafeMutablePointer<Float>? {
        buffer.mutableAudioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
    }

    private static func pad(_ file: AVAudioFile, to position: Int64, buffer: AVAudioPCMBuffer) throws {
        while file.framePosition < position {
            try Task.checkCancellation()
            buffer.frameLength = AVAudioFrameCount(min(Int64(buffer.frameCapacity), position - file.framePosition))
            let contents = buffer.mutableAudioBufferList.pointee.mBuffers
            guard let data = contents.mData else { throw CocoaError(.fileWriteUnknown) }
            memset(data, 0, Int(contents.mDataByteSize))
            try file.write(from: buffer)
        }
    }
}
