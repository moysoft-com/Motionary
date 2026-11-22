import Foundation
import Testing
@testable import Motionary

struct OffbeatAccentAnalyzerTests {
    @Test func suppressesContinuousOffbeatsAcrossPhasesAndKeepsTheAccent() throws {
        let rate = 22_050.0
        var markers = (0..<24).map { AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.9) }
        var samples = [Float](repeating: 0, count: Int(rate * 12))
        let accentIndex = 10
        for (index, marker) in markers.enumerated() {
            let phaseOffset = index.isMultiple(of: 2) ? 0.125 : 0.375
            let offbeatLevel = index == accentIndex ? 0.95 : 0.44
            for (time, level) in [(marker.sourceTime, 0.60), (marker.sourceTime + phaseOffset, offbeatLevel)] {
                let start = Int((time * rate).rounded())
                for sample in 0..<1_650 {
                    let envelope = min(1, Double(sample) / 60, Double(1_650 - sample) / 230)
                    samples[start + sample] = Float(level * envelope * sin(2 * .pi * 150 * Double(sample) / rate))
                }
            }
        }
        let accents = try samples.withUnsafeBufferPointer {
            try OffbeatAccentAnalyzer.analyze(markers: &markers, samples: $0, sampleRate: rate)
        }
        #expect(accents.count == 1)
        let accent = try #require(accents.first)
        #expect(abs(accent.sourceTime - 5.125) < 0.025)
    }

    @Test func selectsUnusualBassAndTonalAttacksOverTheRecurringOffbeatBed() throws {
        let rate = 22_050.0
        var markers = (0..<16).map { AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.9) }
        var samples = [Float](repeating: 0, count: Int(rate * 8))
        func tone(at start: Double, frequency: Double, level: Double, duration: Double = 0.1) {
            let startSample = Int((start * rate).rounded())
            let length = Int(duration * rate)
            for index in 0..<length {
                let envelope = min(1, Double(index) / 60, Double(length - index) / 230)
                samples[startSample + index] += Float(level * envelope * sin(2 * .pi * frequency * Double(index) / rate))
            }
        }
        for index in markers.indices {
            let time = markers[index].sourceTime
            tone(at: time, frequency: 95, level: 0.65)
            tone(at: time + 0.125, frequency: 5_300, level: 0.85, duration: 0.035)
            if index != 5 && index != 10 {
                tone(at: time + 0.25, frequency: Double([330, 392, 440, 494][index % 4]), level: 0.22)
            }
        }
        let bassAccent = 2.75
        let swungMelodicAccent = 5.215
        tone(at: bassAccent, frequency: 130, level: 0.86)
        tone(at: swungMelodicAccent, frequency: 587, level: 0.83)

        let accents = try samples.withUnsafeBufferPointer {
            try OffbeatAccentAnalyzer.analyze(markers: &markers, samples: $0, sampleRate: rate)
        }
        #expect(accents.count == 2)
        let bass = try #require(accents.first)
        let melody = try #require(accents.last)
        #expect(abs(bass.sourceTime - bassAccent) < 0.025)
        #expect(abs(melody.sourceTime - swungMelodicAccent) < 0.025)
        #expect(accents.allSatisfy { (0.65..<1).contains($0.strength) })
    }

    @Test func retainsARecurringSyncopatedGrooveAndAnExtraAccent() throws {
        let rate = 22_050.0
        var markers = (0..<16).map { AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.9) }
        var samples = [Float](repeating: 0, count: Int(rate * 8))
        for (index, marker) in markers.enumerated() {
            if index == 7 { continue }
            let times = index.isMultiple(of: 2) ? [marker.sourceTime, marker.sourceTime + 0.25] : [marker.sourceTime]
            for time in times {
                let start = Int((time * rate).rounded())
                for sample in 0..<2_000 {
                    let envelope = min(1, Double(sample) / 60, Double(2_000 - sample) / 230)
                    samples[start + sample] = Float(envelope * sin(2 * .pi * 110 * Double(sample) / rate))
                }
            }
        }
        let extraTime = 4.39
        let extraStart = Int((extraTime * rate).rounded())
        for sample in 0..<1_450 {
            let envelope = min(1, Double(sample) / 60, Double(1_450 - sample) / 230)
            samples[extraStart + sample] = Float(1.95 * envelope * sin(2 * .pi * 440 * Double(sample) / rate))
        }
        let accents = try samples.withUnsafeBufferPointer {
            try OffbeatAccentAnalyzer.analyze(markers: &markers, samples: $0, sampleRate: rate)
        }
        #expect(accents.count == 9)
        for beat in 0..<8 {
            #expect(accents.contains { abs($0.sourceTime - (Double(beat) + 0.25)) < 0.025 })
        }
        #expect(accents.contains { abs($0.sourceTime - extraTime) < 0.025 })
        #expect(markers[7].hapticAttack == 0)
        #expect(markers[8].hapticAttack ?? 0 > 0)
    }
}
