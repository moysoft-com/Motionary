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
        markers: [AudioBeatMarker], samples: UnsafeBufferPointer<Float>, sampleRate: Double
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
            return framesBetween(onset - 0.025, onset + 0.045).map { frames[$0].bodyRise }.max() ?? 0
        }
        let intervals = zip(markers, markers.dropFirst()).map { $1.sourceTime - $0.sourceTime }
        let plausibleIntervals = intervals.filter { (0.23...1.5).contains($0) }.sorted()
        guard !plausibleIntervals.isEmpty else { return [] }
        let typicalInterval = plausibleIntervals[plausibleIntervals.count / 2]
        let subdivisions = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75]
        let candidates = zip(markers, markers.dropFirst()).map { left, right -> Candidate? in
            let period = right.sourceTime - left.sourceTime
            // A gap roughly two beats long may contain a missed main beat.
            guard (0.23...1.5).contains(period), period < typicalInterval * 1.75 else { return nil }
            let margin = max(0.085, period * 0.16)
            let earliest = max(left.sourceTime, left.audibleOnset ?? left.sourceTime) + margin
            let latest = min(right.sourceTime, right.audibleOnset ?? right.sourceTime) - margin
            return framesBetween(earliest + frameDuration, latest + frameDuration).compactMap { index -> Candidate? in
                let frame = frames[index]
                // A bright tick alone or a very short burst of noise has little
                // weight. A bass or melodic attack retains energy after the peak.
                guard frame.bodyRise > 0.001, frame.bodyRise > frame.airRise * 0.85,
                      index + 3 < frames.count, frames[index + 3].bodyLevel > frame.bodyRise * 0.55
                else { return nil }
                let time = Double(index - 1) * frameDuration
                let phase = (time - left.sourceTime) / period
                let isSubdivision = subdivisions.contains { abs(phase - $0) <= 0.055 }
                return Candidate(time: time, attack: frame.bodyRise, phase: phase, isSubdivision: isSubdivision)
            }.max { $0.attack < $1.attack }
        }

        return candidates.indices.compactMap { index in
            guard let candidate = candidates[index] else { return nil }
            let lower = max(index - 4, 0)
            let upper = min(index + 4, candidates.count - 1)
            let neighbors = (lower...upper).filter { $0 != index }.map { candidates[$0] }
            let nearby = neighbors.map { $0?.attack ?? 0 }.sorted()
            let offbeatBed = nearby[(nearby.count - 1) / 2]
            let recurring = neighbors.compactMap { $0 }
                .filter { abs($0.phase - candidate.phase) <= 0.08 }.map(\.attack).sorted()
            let grooveLevel = recurring.count >= 2 ? recurring[recurring.count / 2] : 0
            let beatContext = beatAttacks[lower...(upper + 1)].sorted()
            let beatLevel = beatContext[beatContext.count / 2]
            // An ordinary subdivision must stand out against other offbeats.
            // A more freely timed phrase needs stronger evidence.
            let threshold = max(
                0.001,
                offbeatBed * (candidate.isSubdivision ? 1.65 : 1.85),
                grooveLevel * 1.45,
                beatLevel * (candidate.isSubdivision ? 0.32 : 0.55)
            )
            guard candidate.attack > threshold else { return nil }
            let reference = max(beatLevel, threshold)
            let strength = candidate.attack / (candidate.attack + reference * 0.45)
            return AudioOffbeatAccent(sourceTime: candidate.time, strength: strength)
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
