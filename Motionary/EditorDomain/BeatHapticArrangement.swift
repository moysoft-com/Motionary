import Foundation

enum BeatHapticArrangement {
    private struct Strike {
        let time: Double
        let energy: Double
        let isDownbeat: Bool
        let isDrop: Bool
        var isOffbeat = false

        var priority: Double {
            if isOffbeat { return energy * 0.5 - 1 }
            return energy + (isDownbeat ? 0.3 : 0) + (isDrop ? 1 : 0)
        }
    }

    static func makeClips(for clip: MediaTimelineItem, around existing: [HapticTimelineItem]) -> [HapticTimelineItem] {
        guard let analysis = clip.beatAnalysis, !analysis.markers.isEmpty else { return [] }
        let markers = analysis.markers
        func timelineTimes(for sourceTime: Double) -> [Double] {
            guard sourceTime >= clip.sourceRange.start, sourceTime <= clip.sourceRange.end else { return [] }
            return clip.speedMap.timelineTimes(
                at: sourceTime - clip.sourceRange.start, sourceDuration: clip.sourceRange.duration
            ).filter { $0 >= 0 && $0 < clip.timelineDuration }.map { clip.timelineStart + $0 }
        }
        // Neural strength measures detection confidence. Use musical accent when
        // available, and use strength as a proxy for older and fallback analyses.
        let accents = markers.map { unit($0.accentScore ?? $0.strength) }
        let strikes = markers.indices.flatMap { index -> [Strike] in
            let marker = markers[index]
            let isDrop = marker.isDrop == true
            let isDownbeat = marker.isDownbeat == true
            guard marker.sourceTime >= clip.sourceRange.start, marker.sourceTime <= clip.sourceRange.end,
                marker.isBreakStart != true || isDrop
            else { return [] }

            let accent = accents[index]
            let neighbors = accents[max(0, index - 3)...min(accents.count - 1, index + 3)]
            let typical = neighbors.reduce(0, +) / Double(neighbors.count)
            if !isDrop {
                if marker.accentScore != nil {
                    let minimumAccent = isDownbeat ? 0.23 : max(0.22, typical * 0.65)
                    guard accent >= minimumAccent else { return [] }
                } else if !isDownbeat, accent < typical * 0.48 {
                    return []
                }
            }
            let contrast = unit(0.5 + 1.5 * (accent - typical))
            let energy = 0.75 * accent + 0.25 * contrast
            return timelineTimes(for: marker.sourceTime)
                .map { Strike(time: $0, energy: energy, isDownbeat: isDownbeat, isDrop: isDrop) }
        }
        let offbeats = analysis.offbeatAccents.flatMap { accent in
            timelineTimes(for: accent.sourceTime).map {
                Strike(time: $0, energy: unit(accent.strength), isDownbeat: false, isDrop: false, isOffbeat: true)
            }
        }

        // Very fast beats and repeated crossings in time remaps compete for a
        // single pulse so the stronger accent can still be perceived distinctly.
        var spaced: [Strike] = []
        for strike in (strikes + offbeats).sorted(by: { $0.time < $1.time }) {
            if let previous = spaced.last, strike.time - previous.time < 0.105 {
                if strike.priority > previous.priority { spaced[spaced.count - 1] = strike }
            } else {
                spaced.append(strike)
            }
        }

        let occupied = existing.sorted { $0.timelineStart < $1.timelineStart }
        let clearance = 0.035
        var occupiedIndex = 0
        var occupiedUntil = -Double.infinity
        return spaced.indices.compactMap { index in
            let strike = spaced[index]
            while occupiedIndex < occupied.count, occupied[occupiedIndex].timelineStart <= strike.time {
                occupiedUntil = max(occupiedUntil, occupied[occupiedIndex].timelineEnd + clearance)
                occupiedIndex += 1
            }
            // Existing clips keep their place in the arrangement, including
            // zero-duration impacts. A repeated invocation fills only gaps.
            guard strike.time >= occupiedUntil else { return nil }
            let nextOccupied = occupiedIndex < occupied.count
                ? occupied[occupiedIndex].timelineStart - clearance : .infinity
            let nextBeat = index + 1 < spaced.count ? spaced[index + 1].time : .infinity
            let energy = strike.energy
            let preferredLength = strike.isOffbeat ? 0.035 + 0.045 * energy
                : 0.035 + 0.10 * energy + (strike.isDownbeat ? 0.030 : 0) + (strike.isDrop ? 0.105 : 0)
            let length = min(preferredLength, (nextBeat - strike.time) * 0.55,
                             nextOccupied - strike.time, clip.timelineEnd - strike.time)
            guard length >= 0.024 else { return nil }

            // Drops have weight and a rounded onset. Regular accents get
            // sharper as their energy increases. Offbeats stay understated.
            let profile: (intensity: Double, sharpness: Double, attack: Double, release: Double)
            if strike.isOffbeat {
                profile = (0.23 + 0.34 * energy, 0.20 + 0.24 * energy, 0.004, 0.8)
            } else if strike.isDrop {
                profile = (0.78 + 0.20 * energy, 0.30 + 0.14 * energy, 0.012, 0.86)
            } else {
                let intensity = 0.24 + 0.57 * energy + (strike.isDownbeat ? 0.12 : 0)
                profile = (intensity, 0.17 + 0.65 * energy, 0, 0.72)
            }
            return HapticTimelineItem(
                timelineStart: strike.time, duration: length, style: .rumble,
                intensity: .init(baseValue: profile.intensity), sharpness: .init(baseValue: profile.sharpness),
                attack: min(profile.attack, length * 0.18), release: length * profile.release, patternEnabled: false
            )
        }
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
