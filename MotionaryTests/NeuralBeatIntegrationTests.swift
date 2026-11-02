import AVFoundation
import Foundation
import Testing
@testable import Motionary

private final class NeuralBeatFixtureBundleToken {}

struct NeuralBeatIntegrationTests {
    @Test func compressedAudioWithNonzeroPresentationTimeKeepsAssetTiming() async throws {
        let url = try #require(Bundle(for: NeuralBeatFixtureBundleToken.self).url(forResource: "delayed-beats", withExtension: "m4a"))
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let trackRange = try await track.load(.timeRange)
        let analysis = try await AudioBeatAnalysisService().analyze(url: url, fingerprint: "delayed")
        let candidates = analysis.markers.map(\.sourceTime)
        #expect(!candidates.isEmpty)
        let noEarlyMarkers = candidates.allSatisfy { $0 >= 1.8 }
        #expect(noEarlyMarkers, "track start: \(trackRange.start.seconds), method: \(String(describing: analysis.method)), markers: \(candidates)")
        let nearest = candidates.map { abs($0 - 3.0) }.min() ?? .infinity
        #expect(nearest < 0.08)
    }

    @Test func decodedAudioFlowsThroughModelAndTimelineMapping() async throws {
        let rate = 22_050.0
        let count = Int(rate * 8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<count { channel[i] = 0 }
        for beat in 0..<16 {
            let start = beat * Int(rate) / 2
            for i in 0..<1000 {
                channel[start + i] = Float(exp(-Double(i) / 220.5) * sin(2 * .pi * 1000 * Double(i) / rate))
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let result = try await AudioBeatAnalysisService().analyze(url: url, fingerprint: "synthetic")
        let highPrecision = try await AudioBeatAnalysisService().analyze(url: url, fingerprint: "synthetic", precision: .fp32)
        #expect(highPrecision.modelPrecision == .fp32)
        #expect(highPrecision.method == .neuralStructured)
        #expect(abs(highPrecision.bpm - 120) < 4)
        #expect(result.algorithmVersion == 5)
        #expect(result.method == .neuralStructured)
        #expect(abs(result.bpm - 120) < 4)
        #expect(result.markers.count >= 14)
        let allHaveGridTimes = result.markers.allSatisfy { $0.gridTime != nil }
        #expect(allHaveGridTimes)
        let hasRanking = result.markers.allSatisfy { $0.editScore != nil && $0.boundaryScore != nil && $0.accentScore != nil }
        #expect(hasRanking)
        #expect(!result.subbeats.isEmpty)
        let encoded = try JSONEncoder().encode(result)
        let restored = try JSONDecoder().decode(AudioBeatAnalysis.self, from: encoded)
        #expect(restored == result)
        let item = MediaTimelineItem(name: "beat", mediaID: MediaID(), mediaType: .audio,
                                     timelineStart: 3, sourceRange: TimeRangeValue(start: 0, duration: 8),
                                     speedMap: .constant(speed: 2), beatAnalysis: result)
        #expect(!item.visibleBeatMarkers.isEmpty)
        let marker = try #require(item.visibleBeatMarkers.first)
        #expect(abs(marker.localTimelineTime - marker.sourceTime / 2) < 0.00001)
    }
}
