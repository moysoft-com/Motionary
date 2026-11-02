import Foundation
import Testing
@testable import Motionary

struct BeatTimingRefinerTests {
    @Test func sharpAttackIsRefinedWithoutChangingTheGrid() {
        let rate = 22_050.0
        var samples = [Float](repeating: 0, count: Int(rate * 2))
        let attack = Int(rate)
        for i in 0..<700 { samples[attack + i] = Float(sin(Double(i) * 0.25) * exp(-Double(i) / 200)) }
        let grid = attack + 441
        let result = BeatTimingRefiner.refine(gridSample: grid, samples: samples, sampleRate: rate)
        #expect(result.gridSample == grid)
        #expect(result.onsetSample != nil)
        #expect(abs((result.onsetSample ?? 0) - attack) < 45)
    }

    @Test func silenceDoesNotMoveTheMetricBeat() {
        let result = BeatTimingRefiner.refine(gridSample: 1000, samples: [Float](repeating: 0, count: 3000), sampleRate: 22_050)
        #expect(result.onsetSample == nil)
        #expect(result.selectedSample == 1000)
    }
}
