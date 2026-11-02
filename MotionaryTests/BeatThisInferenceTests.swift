import Foundation
import CoreML
import Testing
@testable import Motionary

struct BeatThisInferenceTests {
    @Test func bundledModelProducesFiniteActivationsForSilence() throws {
        let engine = try BeatThisInference(computeUnits: .cpuOnly)
        let activations = try engine.analyze(samples: [Float](repeating: 0, count: 22_050))
        #expect(activations.beatLogits.count == 51)
        #expect(activations.downbeatLogits.count == 51)
        let finiteBeat = activations.beatLogits.allSatisfy { $0.isFinite }
        let finiteDownbeat = activations.downbeatLogits.allSatisfy { $0.isFinite }
        #expect(finiteBeat)
        #expect(finiteDownbeat)
    }

    @Test func highPrecisionModelLoadsAndProducesFiniteOutput() throws {
        let url = try #require(Bundle.main.url(forResource: "BeatThisFP32", withExtension: "mlmodelc"))
        let engine = try BeatThisInference(modelURL: url, computeUnits: .cpuOnly)
        let result = try engine.analyze(samples: [Float](repeating: 0, count: 22_050))
        #expect(result.beatLogits.count == 51)
        let finite = result.beatLogits.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test func activationTimeUsesIntegerSampleMapping() {
        let activations = RhythmActivations(beatLogits: [], downbeatLogits: [], sampleRate: 22_050, hopSamples: 441)
        #expect(activations.time(forFrame: 1500) == 30)
    }

    @Test func chunkWindowsCoverFileEdgesWithoutGaps() {
        let border = BeatThisInference.borderFrames
        let length = BeatThisInference.frameCount
        for total in [1, 1488, 1489, 1500, 1501, 3000, 5000] {
            let starts = BeatThisInference.chunkStartFrames(totalFrames: total)
            var covered = [Bool](repeating: false, count: total)
            for start in starts {
                for local in border..<(length - border) {
                    let global = start + local
                    if global >= 0, global < total { covered[global] = true }
                }
            }
            let allCovered = covered.allSatisfy { $0 }
            #expect(allCovered)
        }
        #expect(BeatThisInference.chunkStartFrames(totalFrames: 1501) == [-6, 7])
    }
}
