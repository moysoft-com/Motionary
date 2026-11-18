import Foundation

/// The rendered haptic track contains playback data only, in video time.
struct HapticTrack: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var time: Double
        var intensity: Float
        var sharpness: Float
    }

    struct Event: Codable, Equatable, Sendable {
        var time: Double
        var duration: Double
        var samples: [Sample]
        var end: Double { time + duration }

        func sample(at offset: Double) -> Sample {
            guard let first = samples.first else { return Sample(time: offset, intensity: 0, sharpness: 0) }
            guard let index = samples.firstIndex(where: { $0.time > offset }) else {
                return samples.last ?? first
            }
            guard index > 0 else { return first }
            let start = samples[index - 1]
            let end = samples[index]
            let fraction = Float((offset - start.time) / (end.time - start.time))
            return Sample(
                time: offset,
                intensity: start.intensity + (end.intensity - start.intensity) * fraction,
                sharpness: start.sharpness + (end.sharpness - start.sharpness) * fraction
            )
        }
    }

    var events: [Event]
}
