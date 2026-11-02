import Testing
@testable import Motionary

struct MeterDecoderTests {
    @Test func downbeatsFollowEvidenceAcrossMeterChanges() {
        let starts: Set<Int> = [0, 4, 8, 11, 14]
        let beats = (0..<16).map { index in
            MetricBeatDecoder.Beat(frame: index * 25, probability: 0.9,
                                   downbeatProbability: starts.contains(index) ? 0.95 : 0.05)
        }
        let bars = MeterDecoder.decode(beats)
        #expect(bars.map(\.beatIndex) == [0, 4, 8, 11, 14])
        #expect(bars.compactMap(\.beatsUntilNext) == [4, 4, 3, 3])
    }

    @Test func weakDownbeatEvidenceDoesNotInventBars() {
        let beats = (0..<16).map { MetricBeatDecoder.Beat(frame: $0 * 25, probability: 0.9, downbeatProbability: 0.1) }
        #expect(MeterDecoder.decode(beats).isEmpty)
    }
}
