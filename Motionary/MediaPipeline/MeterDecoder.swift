import Foundation

/// Finds supported bar starts on the beat grid. Meter changes are represented by
/// successive intervals rather than requiring a single meter for the full song.
struct MeterDecoder {
    struct Bar: Equatable {
        let beatIndex: Int
        let beatsUntilNext: Int?
    }

    static func decode(_ beats: [MetricBeatDecoder.Beat]) -> [Bar] {
        guard beats.count >= 4 else { return [] }
        let candidates = beats.indices.filter { beats[$0].downbeatProbability >= 0.5 }
        guard candidates.count >= 2 else { return [] }
        var scores = [Double](repeating: 0, count: candidates.count)
        var previous = [Int](repeating: -1, count: candidates.count)
        for i in candidates.indices {
            let p = min(max(beats[candidates[i]].downbeatProbability, 0.001), 0.999)
            let emission = log(p / (1 - p))
            scores[i] = emission
            for j in (0..<i).reversed() {
                let distance = candidates[i] - candidates[j]
                if distance > 7 { break }
                guard distance >= 2 else { continue }
                var penalty = 0.15
                if previous[j] >= 0 {
                    let previousDistance = candidates[j] - candidates[previous[j]]
                    if previousDistance != distance { penalty += 0.5 }
                }
                let proposed = scores[j] + emission - penalty
                if proposed > scores[i] { scores[i] = proposed; previous[i] = j }
            }
        }
        guard let end = candidates.indices.max(by: { scores[$0] < scores[$1] }), previous[end] >= 0 else { return [] }
        var path: [Int] = []
        var cursor = end
        while cursor >= 0 { path.append(candidates[cursor]); cursor = previous[cursor] }
        path.reverse()
        return path.indices.map { index in
            Bar(beatIndex: path[index], beatsUntilNext: index + 1 < path.count ? path[index + 1] - path[index] : nil)
        }
    }
}
