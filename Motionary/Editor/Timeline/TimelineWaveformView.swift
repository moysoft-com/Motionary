// Timeline waveform drawing, audio decoding, and actor-isolated sample caching.

import AVFoundation
import SwiftUI

private final class TimelineWaveformBox<Value> {
    let samples: Value

    init(_ samples: Value) {
        self.samples = samples
    }
}

struct TimelineAudioWaveformLayout {
    let drawingRange: Range<CGFloat>
    let sampleRange: ClosedRange<CGFloat>

    init?(
        clipWidth: CGFloat,
        sampleWidth: CGFloat,
        sampleOffsetX: CGFloat,
        viewport: ClosedRange<CGFloat>
    ) {
        let sampleStart = sampleOffsetX
        let sampleEnd = sampleOffsetX + sampleWidth
        let lower = max(0, sampleStart, viewport.lowerBound)
        let upper = min(clipWidth, sampleEnd, viewport.upperBound)
        guard upper > lower else { return nil }

        drawingRange = lower..<upper
        sampleRange = (sampleStart - lower)...(sampleEnd - lower)
    }
}

struct TimelineWaveformView: View {
    let samples: [CGFloat]
    let sampleRange: ClosedRange<CGFloat>

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 1, !samples.isEmpty else { return }

            let fillPath = TimelineWaveformShape.path(samples: samples, xRange: sampleRange, height: size.height)
            context.fill(
                fillPath,
                with: .color(Color(red: 0.16, green: 0.03, blue: 0.32))
            )
        }
    }
}

private enum TimelineWaveformShape {
    static func path(samples: [CGFloat], xRange: ClosedRange<CGFloat>, height: CGFloat) -> Path {
        let midY = height / 2
        let step = (xRange.upperBound - xRange.lowerBound) / CGFloat(max(samples.count - 1, 1))
        let amplitudes = samples.map { min(max($0, 0), 1) * height * 0.47 }
        var path = Path()
        guard let first = amplitudes.first else { return path }
        if amplitudes.count == 1 {
            path.addRect(CGRect(x: xRange.lowerBound, y: midY - first, width: step, height: first * 2))
            return path
        }

        func point(_ index: Int, sign: CGFloat) -> CGPoint {
            CGPoint(x: xRange.lowerBound + CGFloat(index) * step, y: midY + sign * amplitudes[index])
        }

        func connect(from start: CGPoint, to end: CGPoint) {
            let tangent = (end.x - start.x) / 3
            path.addCurve(to: end, control1: CGPoint(x: start.x + tangent, y: start.y),
                          control2: CGPoint(x: end.x - tangent, y: end.y))
        }

        let last = amplitudes.count - 1
        path.move(to: point(0, sign: -1))
        for index in 1...last { connect(from: point(index - 1, sign: -1), to: point(index, sign: -1)) }
        path.addLine(to: point(last, sign: 1))
        for index in (0..<last).reversed() { connect(from: point(index + 1, sign: 1), to: point(index, sign: 1)) }
        path.closeSubpath()
        return path
    }
}

struct TimelineHapticWaveformView: View {
    let item: HapticTimelineItem
    let pixelsPerSecond: CGFloat
    let visibleTimelineRange: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            guard size.height > 1, pixelsPerSecond > 0 else { return }
            let start = max(0, (visibleTimelineRange?.lowerBound ?? item.timelineStart) - item.timelineStart)
            let end = min(item.duration, (visibleTimelineRange?.upperBound ?? item.timelineEnd) - item.timelineStart)
            let inset = min(5, size.width * 0.15)
            let scale = (size.width - inset * 2) / max(size.width, 1)
            let waveformScale = pixelsPerSecond * scale
            let lowerX = inset + CGFloat(start) * waveformScale
            let upperX = min(inset + CGFloat(end) * waveformScale, size.width - inset)
            let span = upperX - lowerX
            guard span > 0 else { return }

            let count = max(2, Int(ceil(span / 0.75)) + 1)
            let sampleStart = Double((lowerX - inset) / waveformScale)
            let sampleStep = Double(span / CGFloat(count - 1) / waveformScale)
            let samples = waveformSamples(start: sampleStart, step: sampleStep, count: count)
            let path = TimelineWaveformShape.path(
                samples: samples,
                xRange: lowerX...upperX,
                height: size.height
            )
            context.fill(path, with: .color(MotionaryTheme.hapticsWaveform))
        }
    }

    private func waveformSamples(start: Double, step: Double, count: Int) -> [CGFloat] {
        guard item.isPatternEnabled else {
            return (0..<count).map { CGFloat(item.playbackSample(at: start + Double($0) * step).intensity) }
        }

        let start = max(0, start - step / 2)
        let end = min(item.duration, start + Double(count) * step)
        guard start < end else { return Array(repeating: 0, count: count) }
        var peaks = [CGFloat](repeating: 0, count: count)
        item.forEachPulse(in: start..<end) { pulse in
            let pulseEnd = pulse.time + pulse.duration
            if pulse.duration == 0 {
                guard pulse.time >= start, pulse.time < end else { return }
            } else {
                guard pulseEnd > start, pulse.time < end else { return }
            }
            let first = max(0, min(count - 1, Int(floor((pulse.time - start) / step))))
            let last = min(count - 1, Int(floor((min(pulseEnd, end) - start) / step)))
            for index in first...max(first, last) {
                let left = max(pulse.time, start + Double(index) * step)
                let right = min(pulseEnd, start + Double(index + 1) * step)
                guard right > left || pulse.duration == 0 else { continue }
                let sample = item.playbackSample(at: (left + right) / 2, step: pulse.step)
                peaks[index] = max(peaks[index], CGFloat(sample.intensity))
            }
        }
        return peaks
    }

}

actor TimelineAudioWaveformCache {
    static let shared = TimelineAudioWaveformCache()
    private let sourceCache = NSCache<NSString, TimelineWaveformBox<TimelineAudioEnvelope>>()
    private let retimedCache = NSCache<NSString, TimelineWaveformBox<[CGFloat]>>()
    private var inFlight: [String: Task<TimelineAudioEnvelope?, Never>] = [:]
    private var generation = 0

    init() {
        sourceCache.countLimit = 120
        sourceCache.totalCostLimit = 12 * 1_024 * 1_024
        retimedCache.countLimit = 160
        retimedCache.totalCostLimit = 20 * 1_024 * 1_024
    }

    func samples(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        speedMap: SpeedMap,
        targetCount: Int
    ) async -> [CGFloat] {
        guard !Task.isCancelled else { return [] }
        let quantizedCount = max(32, Int((Double(targetCount) / 32).rounded(.up)) * 32)
        let sourceKey = media.url.standardizedFileURL.path
        let retimedKey = "\(media.mediaID.rawValue)|\(sourceKey)|\(clip.sourceRange.start)|\(clip.sourceRange.duration)|\(quantizedCount)|\(speedMap.topologySignature)"

        if let cached = retimedCache.object(forKey: retimedKey as NSString) {
            return cached.samples
        }

        let requestGeneration = generation
        guard let envelope = await sourceEnvelope(for: media, key: sourceKey),
            generation == requestGeneration, !Task.isCancelled
        else { return [] }
        if let cached = retimedCache.object(forKey: retimedKey as NSString) {
            return cached.samples
        }

        let samples = envelope.samples(in: clip.sourceRange, speedMap: speedMap, count: quantizedCount)
        retimedCache.setObject(
            TimelineWaveformBox(samples),
            forKey: retimedKey as NSString,
            cost: max(samples.count * MemoryLayout<CGFloat>.stride, 1)
        )
        return samples
    }

    private func sourceEnvelope(for media: ClipMediaDescriptor, key: String) async -> TimelineAudioEnvelope? {
        if let cached = sourceCache.object(forKey: key as NSString) {
            return cached.samples
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let requestGeneration = generation
        let task = TimelineAudioWaveformLoader.sourceSampleTask(url: media.url)
        inFlight[key] = task
        let samples = await task.value
        guard generation == requestGeneration else { return nil }
        inFlight[key] = nil
        guard let samples else { return nil }
        sourceCache.setObject(
            TimelineWaveformBox(samples),
            forKey: key as NSString,
            cost: samples.levels.count * MemoryLayout<CGFloat>.stride
        )
        return samples
    }

    func removeAll() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        sourceCache.removeAllObjects()
        retimedCache.removeAllObjects()
    }

    func trimForMemoryPressure() {
        removeAll()
    }
}

enum TimelineAudioWaveformLoader {
    static func samples(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        speedMap: SpeedMap,
        targetCount: Int
    ) async -> [CGFloat] {
        await TimelineAudioWaveformCache.shared.samples(
            for: clip,
            media: media,
            speedMap: speedMap,
            targetCount: targetCount
        )
    }

    fileprivate static func sourceSampleTask(url: URL) -> Task<TimelineAudioEnvelope?, Never> {
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                let range = try? await track.load(.timeRange),
                range.start.isNumeric, range.duration.isNumeric, range.duration > .zero,
                let reader = try? AVAssetReader(asset: asset)
            else { return nil }

            let sourceStart = range.start.seconds
            let sourceDuration = range.duration.seconds
            let count = Int(min(16_384, max(2, ceil(sourceDuration * 240))))
            let sampleRate = 22_050.0
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return nil }
            reader.timeRange = range
            reader.add(output)
            guard reader.startReading() else { return nil }
            defer { if reader.status == .reading { reader.cancelReading() } }

            var energy = Array(repeating: Float(0), count: count)
            var frames = Array(repeating: 0, count: count)
            let bucketsPerSecond = Double(count) / sourceDuration

            while !Task.isCancelled, reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                let offset = (sampleBuffer.presentationTimeStamp - range.start).seconds
                guard offset.isFinite, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }

                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: bytes.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else { continue }

                data.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Int16.self)
                    for (index, sample) in samples.enumerated() {
                        let time = offset + Double(index) / sampleRate
                        guard time >= 0, time < sourceDuration else { continue }
                        let bucketIndex = min(Int(time * bucketsPerSecond), count - 1)
                        let amplitude = Float(sample) / 32_768
                        energy[bucketIndex] += amplitude * amplitude
                        frames[bucketIndex] += 1
                    }
                }
            }

            guard !Task.isCancelled, reader.status == .completed else { return nil }
            let envelope = energy.indices.map { index in
                CGFloat(sqrt(energy[index] / Float(max(frames[index], 1))))
            }
            return TimelineAudioEnvelope(
                sourceStart: sourceStart,
                sourceDuration: sourceDuration,
                levels: scaledEnvelope(envelope)
            )
        }
    }

    static func scaledEnvelope(_ samples: [CGFloat]) -> [CGFloat] {
        let nonSilent = samples.filter { $0 > 0.0001 }.sorted()
        guard let peak = nonSilent.last else { return samples.map { _ in 0.015 } }

        // Scale the audio track around its typical loud sections, retaining headroom for transients.
        let reference = max(nonSilent[Int(Double(nonSilent.count - 1) * 0.95)], 0.003)
        return samples.map { level in
            if level <= reference { return max(0.015, 0.76 * level / reference) }
            return 0.76 + 0.19 * (level - reference) / (peak - reference)
        }
    }

}

struct TimelineAudioEnvelope: Sendable {
    let sourceStart: Double
    let sourceDuration: Double
    let levels: [CGFloat]

    func samples(in range: TimeRangeValue, speedMap: SpeedMap, count: Int) -> [CGFloat] {
        let duration = speedMap.timelineDuration(sourceDuration: range.duration)
        return (0..<count).map { index in
            let time = Double(index) / Double(max(count - 1, 1)) * duration
            if speedMap.timeRemap?.holdsSource(at: time) == true { return 0.015 }
            let sourceTime = range.start + speedMap.sourceTime(at: time, sourceDuration: range.duration)
            let offset = sourceTime - sourceStart
            guard offset >= 0, offset <= sourceDuration else { return 0.015 }
            let position = min(max(offset / sourceDuration * Double(levels.count) - 0.5, 0), Double(levels.count - 1))
            let lower = Int(position)
            let upper = min(lower + 1, levels.count - 1)
            return levels[lower] + (levels[upper] - levels[lower]) * CGFloat(position - Double(lower))
        }
    }
}
