import Foundation
import Testing
@testable import Motionary

struct MetricBeatDecoderTests {
    @Test func periodicActivationsDecodeWithoutRequiringAudioOnsets() throws {
        var beat = [Float](repeating: -6, count: 500)
        var downbeat = beat
        for index in stride(from: 25, to: 500, by: 25) {
            beat[index] = 5
            if (index / 25) % 4 == 1 { downbeat[index] = 5 }
        }
        let result = try MetricBeatDecoder.decode(RhythmActivations(beatLogits: beat, downbeatLogits: downbeat, sampleRate: 22050, hopSamples: 441))
        #expect(abs(result.bpm - 120) < 0.01)
        #expect(result.beats.map(\.frame) == Array(stride(from: 25, to: 500, by: 25)))
        #expect(result.beats.filter { $0.downbeatProbability > 0.9 }.count == 5)
    }

    @Test func weakerOffbeatsDoNotDoubleTheTempo() throws {
        var beat = [Float](repeating: -6, count: 500)
        for index in stride(from: 25, to: 500, by: 25) { beat[index] = 4 }
        for index in stride(from: 37, to: 500, by: 25) { beat[index] = -0.6 }
        let result = try MetricBeatDecoder.decode(RhythmActivations(beatLogits: beat, downbeatLogits: [Float](repeating: -6, count: 500), sampleRate: 22050, hopSamples: 441))
        #expect(abs(result.bpm - 120) < 3)
        let allOnBeats = result.beats.allSatisfy { $0.frame % 25 == 0 }
        #expect(allOnBeats)
    }

    @Test func directFallbackHandlesShortIrregularActivationSequences() throws {
        var beat = [Float](repeating: -8, count: 90)
        for frame in [10, 29, 62, 82] { beat[frame] = 3 }
        let activations = RhythmActivations(beatLogits: beat, downbeatLogits: beat,
                                            sampleRate: 22_050, hopSamples: 441)
        #expect(throws: AudioBeatAnalysisError.self) { try MetricBeatDecoder.decode(activations) }
        let result = try MetricBeatDecoder.decodeDirect(activations)
        #expect(result.beats.map(\.frame) == [10, 29, 62, 82])
        #expect(result.periodicity == 0)
    }

    @Test func directFallbackUsesSevenFramePeakWindow() throws {
        var beat = [Float](repeating: -8, count: 100)
        for frame in [10, 30, 50, 70] { beat[frame] = 4 }
        beat[12] = 2
        let activations = RhythmActivations(beatLogits: beat, downbeatLogits: beat,
                                            sampleRate: 22_050, hopSamples: 441)
        let result = try MetricBeatDecoder.decodeDirect(activations)
        #expect(result.beats.map(\.frame) == [10, 30, 50, 70])
    }

    @Test func directFallbackRejectsNonFiniteLogits() {
        var beat = [Float](repeating: -8, count: 90)
        beat[12] = .nan
        let activations = RhythmActivations(beatLogits: beat, downbeatLogits: beat,
                                            sampleRate: 22_050, hopSamples: 441)
        #expect(throws: AudioBeatAnalysisError.self) { try MetricBeatDecoder.decodeDirect(activations) }
    }

    @Test func unstructuredLowActivationsAreRejected() {
        let empty = RhythmActivations(beatLogits: [Float](repeating: -10, count: 500), downbeatLogits: [Float](repeating: -10, count: 500), sampleRate: 22050, hopSamples: 441)
        #expect(throws: AudioBeatAnalysisError.self) { try MetricBeatDecoder.decode(empty) }
    }
}
