import Foundation
import Testing
@testable import Motionary

struct MusicStructureAnalyzerTests {
    @Test func beatFeaturesIncludeSoundAwayFromTheMidpoint() throws {
        let rate = 22_050.0
        let beatSamples = 11_025
        var samples = [Float](repeating: 0, count: beatSamples * 16)
        for beat in 0..<16 {
            let amplitude = beat < 8 ? 0.02 : 0.8
            for i in 0..<Int(rate * 0.09) {
                samples[beat * beatSamples + i] = Float(amplitude * sin(2 * .pi * 110 * Double(i) / rate))
            }
        }
        let markers = (0..<16).map { AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.8) }
        let evidence = try samples.withUnsafeBufferPointer {
            try MusicStructureAnalyzer.analyze(markers: markers, samples: $0, sampleRate: rate)
        }
        #expect(evidence[8].boundary > 0.2)
        #expect(evidence[8].accent > evidence[2].accent)
    }

    @Test func contrastBasedDropAndEditRankingUseSeparateEvidence() throws {
        let sampleRate = 22_050.0
        let beatSamples = 11_025
        var samples = [Float](repeating: 0, count: beatSamples * 24)
        for beat in 0..<24 {
            let amplitude = beat < 12 ? 0.2 : (beat < 16 ? 0.01 : 0.8)
            for i in 0..<beatSamples {
                samples[beat * beatSamples + i] = Float(amplitude * sin(2 * .pi * 110 * Double(i) / sampleRate))
            }
        }
        var markers: [AudioBeatMarker] = []
        for index in 0..<24 {
            let time = Double(index) * 0.5
            let onset: Double? = index == 16 ? time : nil
            let marker = AudioBeatMarker(sourceTime: time, strength: 0.8, gridTime: time,
                                         audibleOnset: onset, isDownbeat: index == 16)
            markers.append(marker)
        }
        let evidence = try samples.withUnsafeBufferPointer {
            try MusicStructureAnalyzer.analyze(markers: markers, samples: $0, sampleRate: sampleRate)
        }
        #expect(evidence.count == markers.count)
        #expect(evidence[16].drop)
        #expect(evidence.filter(\.drop).count == 1)
        #expect(evidence[16].boundary > evidence[8].boundary)
        #expect(evidence[16].editScore > evidence[8].editScore)
        let finite = evidence.allSatisfy { $0.editScore.isFinite && (0...1).contains($0.editScore) }
        #expect(finite)
    }

    @Test func silenceDoesNotCreateDropsOrBoundaries() throws {
        let markers = (0..<12).map { AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.5) }
        let samples = [Float](repeating: 0, count: 22_050 * 7)
        let result = try samples.withUnsafeBufferPointer {
            try MusicStructureAnalyzer.analyze(markers: markers, samples: $0, sampleRate: 22_050)
        }
        let noInventedEvents = result.allSatisfy { !$0.drop && !$0.breakStart && $0.boundary == 0 }
        #expect(noInventedEvents)
    }
}
