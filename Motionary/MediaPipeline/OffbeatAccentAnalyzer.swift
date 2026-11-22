import Accelerate
import Foundation

enum OffbeatAccentAnalyzer {
    private struct Frame {
        let bodyRise: Double
        let airRise: Double
        let bodyLevel: Double
    }

    private struct Candidate {
        let time: Double
        let attack: Double
        let phase: Double
        let isSubdivision: Bool
    }

    static func analyze(
        markers: inout [AudioBeatMarker], samples: UnsafeBufferPointer<Float>, sampleRate: Double
    ) throws -> [AudioOffbeatAccent] {
        guard markers.count >= 3, sampleRate.isFinite, sampleRate >= 8_000 else { return [] }
        let hop = Int((sampleRate * 0.01).rounded())
        let frameDuration = Double(hop) / sampleRate
        let frames = try attackFrames(samples: samples, sampleRate: sampleRate, hop: hop)
        guard !frames.isEmpty else { return [] }

        func framesBetween(_ start: Double, _ end: Double) -> Range<Int> {
            let lower = Int(min(max(ceil(start / frameDuration), 0), Double(frames.count)))
            let upper = Int(min(max(floor(end / frameDuration) + 1, Double(lower)), Double(frames.count)))
            return lower..<upper
        }

        let beatAttacks = markers.map { marker in
            let onset = marker.audibleOnset ?? marker.sourceTime
            return framesBetween(onset - 0.025, onset + 0.045).map {
                frames[$0].bodyRise + 0.25 * frames[$0].airRise
            }.max() ?? 0
        }
        for index in markers.indices {
            let context = beatAttacks[max(0, index - 4)...min(index + 4, markers.count - 1)].sorted()
            let reference = max(context[context.count / 2], 0.003)
            let attack = beatAttacks[index]
            markers[index].hapticAttack = attack >= max(0.001, reference * 0.16)
                ? attack / (attack + reference * 0.6) : 0
        }
        let intervals = zip(markers, markers.dropFirst()).map { $1.sourceTime - $0.sourceTime }
        let plausibleIntervals = intervals.filter { (0.23...1.5).contains($0) }.sorted()
        guard !plausibleIntervals.isEmpty else { return [] }
        let typicalInterval = plausibleIntervals[plausibleIntervals.count / 2]
        let subdivisions = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75]
        let candidates = zip(markers, markers.dropFirst()).map { left, right -> [Candidate] in
            let period = right.sourceTime - left.sourceTime
            // A gap roughly two beats long may contain a missed main beat.
            guard (0.23...1.5).contains(period), period < typicalInterval * 1.75 else { return [] }
            let margin = max(0.085, period * 0.12)
            let earliest = max(left.sourceTime, left.audibleOnset ?? left.sourceTime) + margin
            let latest = min(right.sourceTime, right.audibleOnset ?? right.sourceTime) - margin
            return framesBetween(earliest + frameDuration, latest + frameDuration).compactMap { index -> Candidate? in
                let frame = frames[index]
                // A bright tick alone or a very short burst of noise has little
                // weight. A bass or melodic attack retains energy after the peak.
                guard index > 0, index + 3 < frames.count,
                      frame.bodyRise > frames[index - 1].bodyRise, frame.bodyRise >= frames[index + 1].bodyRise,
                      frame.bodyRise > 0.001, frame.bodyRise > frame.airRise * 0.85,
                      frames[index + 3].bodyLevel > frame.bodyRise * 0.55
                else { return nil }
                let time = Double(index - 1) * frameDuration
                let phase = (time - left.sourceTime) / period
                let isSubdivision = subdivisions.contains { abs(phase - $0) <= 0.055 }
                return Candidate(time: time, attack: frame.bodyRise, phase: phase, isSubdivision: isSubdivision)
            }
        }

        return candidates.indices.flatMap { index -> [AudioOffbeatAccent] in
            let lower = max(index - 4, 0)
            let upper = min(index + 4, candidates.count - 1)
            let nearby = (lower...upper).filter { $0 != index }
                .map { candidates[$0].map(\.attack).max() ?? 0 }.sorted()
            let offbeatBed = nearby[(nearby.count - 1) / 2]
            let beatContext = beatAttacks[lower...(upper + 1)].sorted()
            let beatLevel = max(beatContext[beatContext.count / 2], 0.003)
            let grooveContext = max(0, index - 8)...min(index + 8, candidates.count - 1)
            // A pulse in nearly every interval is usually accompaniment.
            // Count across phases so alternating subdivisions count as one bed.
            let busyIntervals = grooveContext.count { neighbor in
                candidates[neighbor].contains { $0.attack >= beatLevel * 0.50 }
            }
            let hasDenseBed = grooveContext.count >= 6 && busyIntervals * 4 >= grooveContext.count * 3
            func matchingAttack(at neighbor: Int, phase: Double) -> Double {
                guard candidates.indices.contains(neighbor) else { return 0 }
                return candidates[neighbor].filter { abs($0.phase - phase) <= 0.09 }.map(\.attack).max() ?? 0
            }
            var accepted: [AudioOffbeatAccent] = []
            for candidate in candidates[index].sorted(by: { $0.attack > $1.attack }) {
                // Require repeated acoustic attacks at the same phase and beat interval.
                let groove = (1...4).map { lag in
                    let before = matchingAttack(at: index - lag, phase: candidate.phase)
                    let after = matchingAttack(at: index + lag, phase: candidate.phase)
                    return max(min(before, after),
                               min(before, matchingAttack(at: index - 2 * lag, phase: candidate.phase)),
                               min(after, matchingAttack(at: index + 2 * lag, phase: candidate.phase)))
                }.max() ?? 0
                let followsGroove = !hasDenseBed && groove >= beatLevel * 0.55
                    && candidate.attack >= max(beatLevel * 0.39, groove * 0.56)
                let standsOut = candidate.attack >= max(
                    offbeatBed * (candidate.isSubdivision ? 1.60 : 1.80),
                    beatLevel * (candidate.isSubdivision ? 0.48 : 0.62)
                )
                guard followsGroove || standsOut,
                      accepted.allSatisfy({ abs($0.sourceTime - candidate.time) >= 0.105 })
                else { continue }
                let strength = candidate.attack / (candidate.attack + beatLevel * 0.55)
                accepted.append(AudioOffbeatAccent(sourceTime: candidate.time, strength: strength))
            }
            return accepted.sorted { $0.sourceTime < $1.sourceTime }
        }
    }

    private static func attackFrames(
        samples: UnsafeBufferPointer<Float>, sampleRate: Double, hop: Int
    ) throws -> [Frame] {
        let size = 1024
        guard samples.count >= size else { return [] }
        let transform = try vDSP.DiscreteFourierTransform<Float>(
            count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self
        )
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: size)
        let firstBin = max(1, Int(ceil(45 * Double(size) / sampleRate)))
        let airBin = min(size / 2, Int(ceil(2_200 * Double(size) / sampleRate)))
        let lastBin = min(size / 2, Int(ceil(8_000 * Double(size) / sampleRate)))
        guard firstBin < airBin else { return [] }
        var history = Array(repeating: [Float](repeating: 0, count: lastBin), count: 2)
        var input = zeros, real = zeros, imaginary = zeros
        var frames: [Frame] = []
        frames.reserveCapacity(samples.count / hop + 1)
        for center in stride(from: 0, to: samples.count, by: hop) {
            if frames.count.isMultiple(of: 128) { try Task.checkCancellation() }
            let start = center - size / 2
            for offset in 0..<size {
                let index = start + offset
                input[offset] = samples.indices.contains(index) ? samples[index] * window[offset] : 0
            }
            transform.transform(inputReal: input, inputImaginary: zeros, outputReal: &real, outputImaginary: &imaginary)
            let slot = frames.count % history.count
            var bodyRise = 0.0, airRise = 0.0, bodyLevel = 0.0
            for bin in firstBin..<lastBin {
                let magnitude = hypot(real[bin], imaginary[bin])
                let rise = Double(max(magnitude - history[slot][bin], 0))
                history[slot][bin] = magnitude
                if bin < airBin {
                    bodyRise += rise * rise
                    bodyLevel += Double(magnitude) * Double(magnitude)
                } else {
                    airRise += rise * rise
                }
            }
            frames.append(Frame(bodyRise: sqrt(bodyRise) / Double(size), airRise: sqrt(airRise) / Double(size),
                                bodyLevel: sqrt(bodyLevel) / Double(size)))
        }
        return frames
    }
}
