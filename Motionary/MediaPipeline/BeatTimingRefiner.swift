import Foundation

/// Conservative local attack refinement. The metrical position remains available
/// even when the surrounding signal does not support an audible onset.
struct BeatTimingRefiner {
    struct Timing: Equatable {
        let gridSample: Int
        let onsetSample: Int?
        let attackStrength: Double
        var selectedSample: Int { onsetSample ?? gridSample }
    }

    static func refine(gridSample: Int, samples: [Float], sampleRate: Double) -> Timing {
        samples.withUnsafeBufferPointer { refine(gridSample: gridSample, samples: $0, sampleRate: sampleRate) }
    }

    static func refine(gridSample: Int, samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Timing {
        let grid = min(max(gridSample, 0), max(samples.count - 1, 0))
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else {
            return Timing(gridSample: grid, onsetSample: nil, attackStrength: 0)
        }
        let radius = Int((sampleRate * 0.045).rounded())
        let width = max(Int((sampleRate * 0.002).rounded()), 1)
        let step = max(Int((sampleRate * 0.001).rounded()), 1)
        let lower = max(width, grid - radius)
        let upper = min(samples.count - width, grid + radius)
        guard lower < upper else { return Timing(gridSample: grid, onsetSample: nil, attackStrength: 0) }
        func energy(_ start: Int, _ end: Int) -> Double {
            var sum = 0.0
            for i in start..<end { let value = Double(samples[i]); sum += value * value }
            return sqrt(sum / Double(max(end - start, 1)))
        }
        var bestScore = 0.0
        var best = lower
        var bestAfter = 0.0
        for sample in stride(from: lower, through: upper, by: step) {
            let before = energy(sample - width, sample)
            let after = energy(sample, sample + width)
            let rise = max(after - before, 0)
            let proximity = 1 - 0.35 * Double(abs(sample - grid)) / Double(max(radius, 1))
            let score = rise * proximity
            if score > bestScore { bestScore = score; best = sample; bestAfter = after }
        }
        // Require an actual contrast rather than moving the beat to a nearby
        // sustained or weak signal; no calibrated confidence is claimed here.
        guard bestAfter > 0.002, bestScore / bestAfter > 0.2 else {
            return Timing(gridSample: grid, onsetSample: nil, attackStrength: 0)
        }
        let threshold = bestAfter * 0.08
        let searchStart = max(0, best - width)
        let searchEnd = min(samples.count, best + width)
        let onset = (searchStart..<searchEnd).first { abs(Double(samples[$0])) >= threshold } ?? best
        return Timing(gridSample: grid, onsetSample: onset,
                      attackStrength: min(max(bestScore / bestAfter, 0), 1))
    }
}
