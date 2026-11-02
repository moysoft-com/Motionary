import Foundation

/// Offline decoder for the framewise Beat This activations. It works in frame
/// indices throughout; it does not equate an acoustic onset with a beat.
struct MetricBeatDecoder {
    struct Beat: Equatable {
        let frame: Int
        let probability: Double
        let downbeatProbability: Double
    }
    struct Result {
        let beats: [Beat]
        let bpm: Double
        let periodicity: Double
    }
    private struct Candidate {
        let frame: Int
        let probability: Double
    }
    private static func sigmoid(_ value: Float) -> Double {
        1 / (1 + exp(-Double(value)))
    }

    /// Beat This's published direct peak rule, used only when structured
    /// decoding cannot produce a path. It makes no meter or calibration claim.
    static func decodeDirect(_ activations: RhythmActivations) throws -> Result {
        let beat = activations.beatLogits.map(sigmoid)
        let downbeat = activations.downbeatLogits.map(sigmoid)
        guard beat.count >= 3, beat.count == downbeat.count,
              beat.allSatisfy(\.isFinite), downbeat.allSatisfy(\.isFinite),
              activations.hopSamples > 0, activations.sampleRate.isFinite,
              activations.sampleRate > 0 else { throw AudioBeatAnalysisError.noReliableBeat }
        let peakFrames = beat.indices.filter { index in
            guard beat[index] > 0.5 else { return false }
            let lower = max(0, index - 3), upper = min(beat.count - 1, index + 3)
            return (lower...upper).allSatisfy { beat[index] >= beat[$0] }
        }
        // Quantized plateaus may contain adjacent equal maxima. Preserve one
        // representative frame near their center, matching the upstream rule.
        var peaks: [Int] = []
        var group: [Int] = []
        for frame in peakFrames {
            if let previous = group.last, frame - previous > 1 {
                peaks.append(Int((Double(group.reduce(0, +)) / Double(group.count)).rounded()))
                group.removeAll(keepingCapacity: true)
            }
            group.append(frame)
        }
        if !group.isEmpty { peaks.append(Int((Double(group.reduce(0, +)) / Double(group.count)).rounded())) }
        guard peaks.count >= 3 else { throw AudioBeatAnalysisError.noReliableBeat }
        let gaps = zip(peaks.dropFirst(), peaks).map(-).sorted()
        let median = gaps[gaps.count / 2]
        guard median > 0 else { throw AudioBeatAnalysisError.noReliableBeat }
        let fps = activations.sampleRate / Double(activations.hopSamples)
        let events = peaks.map { frame in
            let lower = max(frame - 2, 0), upper = min(frame + 2, downbeat.count - 1)
            return Beat(frame: frame, probability: beat[frame],
                        downbeatProbability: downbeat[lower...upper].max() ?? 0)
        }
        return Result(beats: events, bpm: 60 * fps / Double(median), periodicity: 0)
    }

    static func decode(_ activations: RhythmActivations) throws -> Result {
        let beat = activations.beatLogits.map(sigmoid)
        let downbeat = activations.downbeatLogits.map(sigmoid)
        guard beat.count == downbeat.count, beat.count >= 100,
              beat.allSatisfy(\.isFinite), downbeat.allSatisfy(\.isFinite) else {
            throw AudioBeatAnalysisError.noReliableBeat
        }
        let fps = activations.sampleRate / Double(activations.hopSamples)
        let minLag = max(2, Int((fps * 60 / 240).rounded()))
        let maxLag = min(beat.count / 3, Int((fps * 60 / 45).rounded()))
        guard maxLag > minLag else { throw AudioBeatAnalysisError.noReliableBeat }

        // Correlation removes the activation floor, which otherwise makes
        // unstructured low-level model output appear strongly periodic.
        let mean = beat.reduce(0, +) / Double(beat.count)
        let novelty = beat.map { max($0 - mean, 0) }
        let localRadius = Int(fps * 8)
        var correlations = [Int: [Double]]()
        let candidates = (1..<(beat.count - 1)).compactMap { index -> Candidate? in
            guard beat[index] >= 0.18, beat[index] >= beat[index - 1], beat[index] > beat[index + 1] else { return nil }
            return Candidate(frame: index, probability: beat[index])
        }
        guard candidates.count >= 3 else { throw AudioBeatAnalysisError.noReliableBeat }

        // Local, normalized autocorrelation supplies a distinct tempo prior for
        // each time region; all lags remain available to the path search.
        func localCorrelation(frame: Int) -> [Double] {
            let key = frame / max(Int(fps * 2), 1)
            if let cached = correlations[key] { return cached }
            let center = key * max(Int(fps * 2), 1)
            let lo = max(0, center - localRadius)
            let hi = min(novelty.count, center + localRadius)
            var values = [Double](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag where hi - lo > lag {
                var cross = 0.0, lhs = 0.0, rhs = 0.0
                for i in (lo + lag)..<hi {
                    let a = novelty[i], b = novelty[i - lag]
                    cross += a * b; lhs += a * a; rhs += b * b
                }
                values[lag] = cross / max(sqrt(lhs * rhs), 1e-12)
            }
            correlations[key] = values
            return values
        }

        var score = [Double](repeating: 0, count: candidates.count)
        var previous = [Int](repeating: -1, count: candidates.count)
        var count = [Int](repeating: 1, count: candidates.count)
        for i in candidates.indices {
            if i & 255 == 0 { try Task.checkCancellation() }
            let candidate = candidates[i]
            let emission = max(0.05, candidate.probability - 0.12)
            score[i] = emission
            let corr = localCorrelation(frame: candidate.frame)
            var j = i - 1
            while j >= 0 {
                let lag = candidate.frame - candidates[j].frame
                if lag > maxLag { break }
                if lag >= minLag {
                    let correlation = corr[lag]
                    // Encourage coherent local periodicity without forcing a
                    // single global tempo or preselecting an octave.
                    var smoothness = 0.0
                    if previous[j] >= 0 {
                        let prior = candidates[j].frame - candidates[previous[j]].frame
                        smoothness = min(pow(log(Double(lag) / Double(prior)), 2), 1) * 0.7
                    }
                    let value = score[j] + emission + 0.35 * correlation - 0.18 - smoothness
                    if value > score[i] {
                        score[i] = value
                        previous[i] = j
                        count[i] = count[j] + 1
                    }
                }
                j -= 1
            }
        }
        guard let end = candidates.indices.max(by: { score[$0] < score[$1] }), count[end] >= 3 else {
            throw AudioBeatAnalysisError.noReliableBeat
        }
        var indices: [Int] = []
        var cursor = end
        while cursor >= 0 {
            indices.append(cursor)
            cursor = previous[cursor]
        }
        indices.reverse()
        let path = indices.map { candidates[$0] }
        let intervals = zip(path.dropFirst(), path).map { $0.frame - $1.frame }.sorted()
        guard let median = intervals.dropFirst(intervals.count / 2).first, median > 0 else {
            throw AudioBeatAnalysisError.noReliableBeat
        }
        let averageProbability = path.reduce(0) { $0 + $1.probability } / Double(path.count)
        let periodicity = path.reduce(0.0) { sum, candidate in
            sum + localCorrelation(frame: candidate.frame)[median]
        } / Double(path.count)
        guard averageProbability >= 0.3, periodicity >= 0.08 else { throw AudioBeatAnalysisError.noReliableBeat }
        let decoded = path.map { candidate in
            let lo = max(0, candidate.frame - 2), hi = min(downbeat.count - 1, candidate.frame + 2)
            return Beat(frame: candidate.frame, probability: candidate.probability,
                        downbeatProbability: downbeat[lo...hi].max() ?? 0)
        }
        return Result(beats: decoded, bpm: 60 * fps / Double(median), periodicity: periodicity)
    }
}
