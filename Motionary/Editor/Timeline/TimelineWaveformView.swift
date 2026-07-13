// Timeline waveform drawing, audio decoding, and actor-isolated sample caching.

import AVFoundation
import SwiftUI

private final class TimelineWaveformBox {
    let samples: [CGFloat]

    init(_ samples: [CGFloat]) {
        self.samples = samples
    }
}

struct TimelineWaveformView: View {
    let samples: [CGFloat]

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1, !samples.isEmpty else { return }

            let midY = size.height * 0.5
            let maxAmplitude = max(size.height * 0.47, 1)
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            var upper: [CGPoint] = []
            var lower: [CGPoint] = []
            upper.reserveCapacity(samples.count)
            lower.reserveCapacity(samples.count)

            for index in samples.indices {
                let x = CGFloat(index) * step
                let amplitude = min(max(samples[index], 0), 1) * maxAmplitude
                upper.append(CGPoint(x: x, y: midY - amplitude))
                lower.append(CGPoint(x: x, y: midY + amplitude))
            }

            var fillPath = Path()
            fillPath.move(to: lower[0])
            for point in lower.dropFirst() {
                fillPath.addLine(to: point)
            }
            for point in upper.reversed() {
                fillPath.addLine(to: point)
            }
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .color(Color(red: 0.16, green: 0.03, blue: 0.32))
            )
        }
    }
}

actor TimelineAudioWaveformCache {
    static let shared = TimelineAudioWaveformCache()
    private let cache = NSCache<NSString, TimelineWaveformBox>()
    private var inFlight: [String: Task<[CGFloat], Never>] = [:]

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func samples(for clip: TimelineClip, media: ClipMediaDescriptor, targetCount: Int) async -> [CGFloat] {
        let quantizedCount = max(32, Int((Double(targetCount) / 32).rounded(.up)) * 32)
        let key = [
            media.mediaID.rawValue.uuidString,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration),
            "\(quantizedCount)"
        ].joined(separator: "|")

        if let cached = cache.object(forKey: key as NSString) {
            return cached.samples
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task {
            await TimelineAudioWaveformLoader.generateSamples(for: clip, media: media, targetCount: quantizedCount)
        }
        inFlight[key] = task
        let samples = await task.value
        inFlight[key] = nil
        cache.setObject(
            TimelineWaveformBox(samples),
            forKey: key as NSString,
            cost: max(samples.count * MemoryLayout<CGFloat>.stride, 1)
        )
        return samples
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
    }

    func trimForMemoryPressure() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
    }
}

enum TimelineAudioWaveformLoader {
    static func samples(for clip: TimelineClip, media: ClipMediaDescriptor, targetCount: Int) async -> [CGFloat] {
        await TimelineAudioWaveformCache.shared.samples(for: clip, media: media, targetCount: targetCount)
    }

    fileprivate static func generateSamples(
        for clip: TimelineClip,
        media: ClipMediaDescriptor,
        targetCount: Int
    ) async -> [CGFloat] {
        let url = media.url
        let sourceStart = clip.sourceRange.start
        let sourceDuration = clip.sourceRange.duration

        return await Task<[CGFloat], Never>.detached(priority: .utility) {
            let count = max(targetCount, 1)
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

            var buckets = Array(repeating: Float(0), count: count)
            let totalSamples = max(Int(max(sourceDuration, 0.05) * sampleRate), 1)
            var sampleIndex = 0
            var readSamples = 0

            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
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
                        let amplitude = min(Float(abs(Int32(sample))) / 32_767, 1)
                        buckets[bucketIndex] = max(buckets[bucketIndex], amplitude)
                        sampleIndex += 1
                        readSamples += 1
                    }
                }
            }

            guard reader.status == .completed || reader.status == .reading else { return fallback }
            guard readSamples > 0 else { return fallback }

            let peak = max(buckets.max() ?? 0, 0)
            guard peak > 0.0001 else {
                return Array(repeating: 0.015, count: count)
            }
            let gain = min(1 / peak, 3.2)
            let normalized = buckets.map { value in
                let boosted = CGFloat(value * gain)
                return min(max(sqrt(boosted), 0.015), 1)
            }
            return normalized
        }.value
    }

    private static func fallbackSamples(count: Int) -> [CGFloat] {
        Array(repeating: 0.015, count: count)
    }
}
