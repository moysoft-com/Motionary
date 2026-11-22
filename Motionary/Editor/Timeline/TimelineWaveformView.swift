// Timeline waveform drawing, audio decoding, and actor-isolated sample caching.

import AVFoundation
import SwiftUI

private final class TimelineWaveformBox {
    let samples: [CGFloat]

    init(_ samples: [CGFloat]) {
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
        let inset = min(5, sampleWidth / 2)
        let sampleStart = sampleOffsetX + inset
        let sampleEnd = sampleOffsetX + sampleWidth - inset
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
    private let sourceCache = NSCache<NSString, TimelineWaveformBox>()
    private let retimedCache = NSCache<NSString, TimelineWaveformBox>()
    private var inFlight: [String: Task<[CGFloat], Never>] = [:]
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
        let sourceKey = [
            media.mediaID.rawValue.uuidString,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
        let retimedKey = "\(sourceKey)|count:\(quantizedCount)|speed:\(speedMap.topologySignature)"

        if let cached = retimedCache.object(forKey: retimedKey as NSString) {
            return cached.samples
        }

        let requestGeneration = generation
        let sourceSamples = await sourceSamples(for: clip, media: media, key: sourceKey)
        guard generation == requestGeneration, !Task.isCancelled else { return [] }
        if let cached = retimedCache.object(forKey: retimedKey as NSString) {
            return cached.samples
        }

        let samples = TimelineAudioWaveformLoader.retimedSamples(
            TimelineAudioWaveformLoader.resampledEnvelope(sourceSamples, count: quantizedCount),
            speedMap: speedMap,
            sourceDuration: clip.sourceRange.duration
        )
        retimedCache.setObject(
            TimelineWaveformBox(samples),
            forKey: retimedKey as NSString,
            cost: max(samples.count * MemoryLayout<CGFloat>.stride, 1)
        )
        return samples
    }

    private func sourceSamples(for clip: TimelineClip, media: ClipMediaDescriptor, key: String) async -> [CGFloat] {
        if let cached = sourceCache.object(forKey: key as NSString) {
            return cached.samples
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let requestGeneration = generation
        let task = TimelineAudioWaveformLoader.sourceSampleTask(for: clip, media: media)
        inFlight[key] = task
        let samples = await task.value
        guard generation == requestGeneration else { return [] }
        inFlight[key] = nil
        sourceCache.setObject(
            TimelineWaveformBox(samples),
            forKey: key as NSString,
            cost: max(samples.count * MemoryLayout<CGFloat>.stride, 1)
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

    fileprivate static func sourceSampleTask(
        for clip: TimelineClip,
        media: ClipMediaDescriptor
    ) -> Task<[CGFloat], Never> {
        let url = media.url
        let sourceStart = clip.sourceRange.start
        let sourceDuration = clip.sourceRange.duration

        return Task.detached(priority: .utility) {
            // Decode the short-window RMS envelope above the timeline drawing resolution.
            let count = min(4_096, max(1, Int(max(sourceDuration, 0.05) * 22_050)))
            let fallback = fallbackSamples(count: count)
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                let reader = try? AVAssetReader(asset: asset)
            else { return fallback }

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

            guard reader.canAdd(output) else { return fallback }
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: max(sourceDuration, 0.05), preferredTimescale: 600)
            )
            reader.add(output)
            guard reader.startReading() else { return fallback }

            var energy = Array(repeating: Float(0), count: count)
            var frames = Array(repeating: 0, count: count)
            let totalSamples = max(Int(max(sourceDuration, 0.05) * sampleRate), 1)
            var sampleIndex = 0
            var readSamples = 0

            while !Task.isCancelled, reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
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
                    for sample in samples {
                        let progress = min(Double(sampleIndex) / Double(totalSamples), 0.999)
                        let bucketIndex = min(Int(progress * Double(count)), count - 1)
                        let amplitude = Float(sample) / 32_768
                        energy[bucketIndex] += amplitude * amplitude
                        frames[bucketIndex] += 1
                        sampleIndex += 1
                        readSamples += 1
                    }
                }
            }

            if Task.isCancelled {
                reader.cancelReading()
                return []
            }
            guard reader.status == .completed || reader.status == .reading else { return fallback }
            guard readSamples > 0 else { return fallback }

            let envelope = energy.indices.map { index in
                CGFloat(sqrt(energy[index] / Float(max(frames[index], 1))))
            }
            return scaledEnvelope(envelope)
        }
    }

    static func scaledEnvelope(_ samples: [CGFloat]) -> [CGFloat] {
        let nonSilent = samples.filter { $0 > 0.0001 }.sorted()
        guard let peak = nonSilent.last else { return samples.map { _ in 0.015 } }

        // Scale each clip around its typical loud sections, retaining headroom for transients.
        let reference = max(nonSilent[Int(Double(nonSilent.count - 1) * 0.95)], 0.003)
        return samples.map { level in
            if level <= reference { return max(0.015, 0.76 * level / reference) }
            return 0.76 + 0.19 * (level - reference) / (peak - reference)
        }
    }

    fileprivate static func resampledEnvelope(_ sourceSamples: [CGFloat], count: Int) -> [CGFloat] {
        guard !sourceSamples.isEmpty else { return [] }
        return (0..<count).map { index in
            let start = index * sourceSamples.count / count
            let end = max(start + 1, (index + 1) * sourceSamples.count / count)
            let window = sourceSamples[start..<end]
            return sqrt(window.reduce(0) { $0 + $1 * $1 } / CGFloat(window.count))
        }
    }

    fileprivate static func retimedSamples(
        _ sourceSamples: [CGFloat],
        speedMap: SpeedMap,
        sourceDuration: Double
    ) -> [CGFloat] {
        guard sourceSamples.count > 1, sourceDuration > 0 else { return sourceSamples }
        let timelineDuration = speedMap.timelineDuration(sourceDuration: sourceDuration)
        guard timelineDuration > 0 else { return sourceSamples }

        return sourceSamples.indices.map { index in
            let progress = Double(index) / Double(sourceSamples.count - 1)
            let time = progress * timelineDuration
            if speedMap.timeRemap?.holdsSource(at: time) == true { return 0.015 }
            let sourceTime = speedMap.sourceTime(
                at: time,
                sourceDuration: sourceDuration
            )
            let sourcePosition = min(
                max(sourceTime / sourceDuration * Double(sourceSamples.count - 1), 0),
                Double(sourceSamples.count - 1)
            )
            let lowerIndex = Int(sourcePosition.rounded(.down))
            let upperIndex = min(lowerIndex + 1, sourceSamples.count - 1)
            let fraction = CGFloat(sourcePosition - Double(lowerIndex))
            return sourceSamples[lowerIndex]
                + (sourceSamples[upperIndex] - sourceSamples[lowerIndex]) * fraction
        }
    }

    private static func fallbackSamples(count: Int) -> [CGFloat] {
        Array(repeating: 0.015, count: count)
    }
}
