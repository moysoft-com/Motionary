import Foundation

enum HapticStyle: String, Codable, Sendable {
    case impact, rumble, pulse, heartbeat, pattern

    var repeats: Bool {
        self == .pulse || self == .heartbeat || self == .pattern
    }
}

struct HapticPatternStep: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var position = 0.0
    var length = 0.0
    var strength = 1.0
    var sharpnessOffset = 0.0
}

struct HapticTimelineItem: Identifiable, Codable, Equatable, Sendable {
    static let repeatRange = 0.03...4.0
    static let defaultPulseLength = 0.15

    var id = UUID()
    var timelineStart: Double
    var duration: Double
    var sourceStart = 0.0
    var style: HapticStyle
    var intensity = AnimatableProperty(baseValue: 0.65)
    var sharpness = AnimatableProperty(baseValue: 0.4)
    var period = 0.6
    var attack = 0.0
    var decay = 0.0
    var sustain = 1.0
    var release = 0.0
    var envelopeEnd: Double?
    var patternSteps = [HapticPatternStep()]
    var patternEnabled: Bool?
    var pulseLength: Double?
    var repeatKeyframes: [Keyframe<Double>] = []
    var lengthKeyframes: [Keyframe<Double>] = []

    var animatedPeriod: AnimatableProperty<Double> {
        get { .init(baseValue: period, keyframes: repeatKeyframes) }
        set {
            period = newValue.baseValue
            repeatKeyframes = newValue.keyframes
        }
    }

    var animatedLength: AnimatableProperty<Double> {
        get { .init(baseValue: displayedPulseLength, keyframes: lengthKeyframes) }
        set {
            if newValue.baseValue != displayedPulseLength { pulseLength = newValue.baseValue }
            lengthKeyframes = newValue.keyframes
        }
    }

    var isPatternEnabled: Bool { patternEnabled ?? style.repeats }

    var displayedPulseLength: Double {
        if let pulseLength { return pulseLength }
        if style == .pattern, let first = patternSteps.first { return pulseDuration(for: first) }
        return style.repeats ? 0 : min(Self.defaultPulseLength, period)
    }

    private var legacyPatternSteps: [HapticPatternStep] {
        switch style {
        case .pattern: return patternSteps
        case .pulse: return [.init(id: id)]
        case .heartbeat: return [.init(id: id), .init(id: id, position: 0.23, strength: 0.55)]
        case .rumble, .impact: return [.init(id: id, length: displayedPulseLength / period)]
        }
    }

    var timelineEnd: Double { timelineStart + (style == .impact ? 0 : duration) }

    var keyframeTimes: [Double] {
        guard style != .impact else { return [] }
        return KeyframeMergeSupport.mergedTimes(keyframeTargets.compactMap(\.hapticProperty).map { self[keyPath: $0].keyframes.map(\.time) })
            .map { $0 - sourceStart }
            .filter { 0...max(duration, 0) ~= $0 }
    }

    var sourceEnd: Double { sourceStart + duration }

    func pulseOffset(for step: HapticPatternStep) -> Double {
        min(max(step.position, 0), 0.99) * period
    }

    func pulseDuration(for step: HapticPatternStep) -> Double {
        min(max(step.length * period, 0), period - pulseOffset(for: step))
    }

    struct Pulse {
        let time: Double
        let duration: Double
        let step: HapticPatternStep
    }

    // Interval and length are sampled at the start of each cycle in source time.
    func forEachPulse(in offsets: Range<Double>, _ visit: (Pulse) throws -> Void) rethrows {
        guard Self.repeatRange.contains(period), !offsets.isEmpty else { return }
        let repeatControl = animatedPeriod
        let lengthControl = animatedLength
        let usesSinglePulse = pulseLength != nil || !style.repeats
            || lengthKeyframes.contains { $0.value != lengthControl.baseValue }
        let legacySteps = usesSinglePulse ? [] : legacyPatternSteps
        let start = sourceStart + offsets.lowerBound
        let end = sourceStart + offsets.upperBound
        let initialPeriod = min(max(repeatControl.value(at: 0), Self.repeatRange.lowerBound), Self.repeatRange.upperBound)
        let initialConstantEnd = repeatKeyframes.first?.time ?? end
        var cycle = min(start, initialConstantEnd) - min(start, initialConstantEnd).truncatingRemainder(dividingBy: initialPeriod)
        while cycle < end {
            let interval = min(max(repeatControl.value(at: cycle), Self.repeatRange.lowerBound), Self.repeatRange.upperBound)
            if let last = repeatKeyframes.last, cycle >= last.time, cycle + interval < start {
                cycle += floor((start - cycle) / interval) * interval
                continue
            }
            if usesSinglePulse {
                let duration = min(max(lengthControl.value(at: cycle), 0), interval)
                try visit(Pulse(time: cycle - sourceStart, duration: duration, step: .init(id: id)))
            } else {
                for step in legacySteps {
                    let position = min(max(step.position, 0), 0.99)
                    let duration = min(max(step.length, 0), 1 - position) * interval
                    try visit(Pulse(time: cycle - sourceStart + position * interval, duration: duration, step: step))
                }
            }
            let next = cycle + interval
            guard next > cycle else { break }
            cycle = next
        }
    }

    func playbackSample(at offset: Double, step: HapticPatternStep? = nil) -> HapticTrack.Sample {
        let time = sourceStart + offset
        let envelope = style == .impact ? 1 : level(at: time)
        return HapticTrack.Sample(
            time: offset,
            intensity: Float(min(max(intensity.value(at: time) * envelope * (step?.strength ?? 1), 0), 1)),
            sharpness: Float(min(max(sharpness.value(at: time) + (step?.sharpnessOffset ?? 0), 0), 1))
        )
    }

    func level(at time: Double) -> Double {
        let end = max(0, envelopeEnd ?? sourceEnd)
        let local = min(max(time, 0), end)
        let ramp = min(max(attack, 0), end)
        let drop = min(max(decay, 0), end - ramp)
        let tail = min(max(release, 0), end)
        let level: Double
        if ramp > 0, local < ramp {
            level = local / ramp
        } else if drop > 0, local < ramp + drop {
            level = 1 + (sustain - 1) * (local - ramp) / drop
        } else {
            level = sustain
        }
        let fade = tail > 0 ? min(1, (end - local) / tail) : 1
        return level * fade
    }
}

extension HapticTimelineItem {
    private enum CodingKeys: String, CodingKey {
        case id, timelineStart, duration, sourceStart, style, intensity, sharpness
        case period, attack, decay, sustain, release, envelopeEnd, patternSteps, patternEnabled, pulseLength, repeatKeyframes, lengthKeyframes
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try fields.decode(UUID.self, forKey: .id),
            timelineStart: try fields.decode(Double.self, forKey: .timelineStart),
            duration: try fields.decode(Double.self, forKey: .duration),
            sourceStart: try fields.decode(Double.self, forKey: .sourceStart),
            style: try fields.decode(HapticStyle.self, forKey: .style),
            intensity: try fields.decode(AnimatableProperty<Double>.self, forKey: .intensity),
            sharpness: try fields.decode(AnimatableProperty<Double>.self, forKey: .sharpness),
            period: try fields.decode(Double.self, forKey: .period),
            attack: try fields.decode(Double.self, forKey: .attack),
            decay: try fields.decode(Double.self, forKey: .decay),
            sustain: try fields.decode(Double.self, forKey: .sustain),
            release: try fields.decode(Double.self, forKey: .release),
            envelopeEnd: try fields.decodeIfPresent(Double.self, forKey: .envelopeEnd),
            patternSteps: try fields.decode([HapticPatternStep].self, forKey: .patternSteps),
            patternEnabled: try fields.decodeIfPresent(Bool.self, forKey: .patternEnabled),
            pulseLength: try fields.decodeIfPresent(Double.self, forKey: .pulseLength),
            repeatKeyframes: try fields.decodeIfPresent([Keyframe<Double>].self, forKey: .repeatKeyframes) ?? [],
            lengthKeyframes: try fields.decodeIfPresent([Keyframe<Double>].self, forKey: .lengthKeyframes) ?? []
        )
        guard duration > 0, timelineStart >= 0, sourceStart >= 0,
            timelineEnd.isFinite, sourceEnd.isFinite, Self.repeatRange.contains(period),
            (0...Self.repeatRange.upperBound).contains(pulseLength ?? 0),
            (0...1).contains(sustain), [attack, decay, release, envelopeEnd ?? 0].allSatisfy({ $0.isFinite && $0 >= 0 }),
            patternSteps.count <= 32, Set(patternSteps.map(\.id)).count == patternSteps.count
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid Motionary haptic clip."
            ))
        }
        intensity.keyframes.sort { $0.time < $1.time }
        sharpness.keyframes.sort { $0.time < $1.time }
        repeatKeyframes.sort { $0.time < $1.time }
        lengthKeyframes.sort { $0.time < $1.time }
    }
}

extension HapticTrack {
    static func render(_ items: [HapticTimelineItem], through end: Double) throws -> Self {
        var events: [Event] = []
        for item in items {
            try Task.checkCancellation()
            let horizon = min(item.duration, end - item.timelineStart)
            guard item.timelineStart >= 0, horizon > 0, horizon.isFinite,
                item.sourceStart >= 0, item.sourceStart.isFinite, item.sourceEnd.isFinite
            else { continue }
            let controls = [item.intensity, item.sharpness]
            let isAnimated = controls.contains { !$0.keyframes.isEmpty }
                || item.attack > 0 || item.decay > 0 || item.release > 0
            let keyTimes = controls.flatMap { property in
                property.keyframes.enumerated().flatMap { index, frame -> [Double] in
                    let time = frame.time - item.sourceStart
                    guard index > 0, property.keyframes[index - 1].interpolation == .hold else { return [time] }
                    return [max(time - 0.000_5, property.keyframes[index - 1].time - item.sourceStart), time]
                }
            }
            let envelopeTimes = [
                item.attack, item.attack + item.decay, (item.envelopeEnd ?? item.sourceEnd) - item.release,
            ].map { $0 - item.sourceStart }

            func sample(at offset: Double, relativeTo start: Double, step: HapticPatternStep?) -> Sample {
                var sample = item.playbackSample(at: offset, step: step)
                sample.time -= start
                return sample
            }

            func impact(at offset: Double, step: HapticPatternStep? = nil) {
                let epsilon = KeyframeMergeSupport.timeTolerance
                guard offset >= -epsilon, offset < horizon - epsilon else { return }
                let hit = max(0, offset)
                events.append(Event(time: item.timelineStart + hit, duration: 0, samples: [
                    sample(at: hit, relativeTo: hit, step: step)
                ]))
            }

            func continuous(from offset: Double, to end: Double, step: HapticPatternStep? = nil) throws {
                var start = max(0, offset)
                let limit = min(horizon, end)
                while start + 0.000_001 < limit {
                    try Task.checkCancellation()
                    let stop = min(limit, start + 30)
                    let samples: [Sample]
                    if isAnimated {
                        let steps = max(1, Int(ceil((stop - start) * 50)))
                        let grid = (0..<steps).map { start + (stop - start) * Double($0) / Double(steps) }
                        let boundaries = (keyTimes + envelopeTimes).filter { $0 > start && $0 < stop - 0.000_001 }
                        let offsets = KeyframeMergeSupport.mergedTimes([grid, boundaries]) + [stop]
                        samples = offsets.map { sample(at: $0, relativeTo: start, step: step) }
                    } else {
                        samples = [sample(at: start, relativeTo: start, step: step)]
                    }
                    events.append(Event(time: item.timelineStart + start, duration: stop - start, samples: samples))
                    start = stop
                }
            }

            if item.style == .impact {
                impact(at: 0)
            } else if !item.isPatternEnabled {
                try continuous(from: 0, to: horizon)
            } else {
                try item.forEachPulse(in: 0..<horizon) { pulse in
                    try Task.checkCancellation()
                    if pulse.duration > 0 {
                        try continuous(from: pulse.time, to: pulse.time + pulse.duration, step: pulse.step)
                    } else {
                        impact(at: pulse.time, step: pulse.step)
                    }
                }
            }
        }
        return Self(events: events.sorted { $0.time < $1.time })
    }
}

extension EditorProject {
    var containsHaptics: Bool {
        !hapticItems(in: tracks, includeMuted: true).isEmpty
    }

    var audibleHapticItems: [HapticTimelineItem] {
        hapticItems(in: tracks, includeMuted: false)
    }

    private func hapticItems(
        in tracks: [TimelineTrack],
        includeMuted: Bool,
        ancestors: Set<UUID> = []
    ) -> [HapticTimelineItem] {
        tracks.filter { includeMuted || !$0.isMuted }.flatMap { track in
            track.items.flatMap { item -> [HapticTimelineItem] in
                switch item {
                case .haptic(let haptic):
                    return [haptic]
                case .compound(let compound):
                    guard !ancestors.contains(compound.sequenceID),
                        let sequence = sequences[compound.sequenceID]
                    else { return [] }
                    return hapticItems(
                        in: sequence.tracks, includeMuted: includeMuted,
                        ancestors: ancestors.union([compound.sequenceID])
                    ).compactMap { nested in
                        guard nested.timelineStart < compound.duration else { return nil }
                        var placed = nested
                        placed.duration = min(nested.duration, compound.duration - nested.timelineStart)
                        placed.timelineStart += compound.timelineStart
                        return placed
                    }
                default:
                    return []
                }
            }
        }
    }
}
