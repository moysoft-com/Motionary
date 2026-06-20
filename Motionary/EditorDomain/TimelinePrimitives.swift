// Timeline media kinds, time ranges, keyframes, and animatable values.

import Foundation

/// Media categories supported by timeline clips.
enum ClipMediaType: String, Codable, CaseIterable {
    case video
    case image
    case audio
}

/// Compatibility category used to constrain clips to appropriate tracks.
enum TrackKind: String, Codable, CaseIterable {
    case undefined
    case visual
    case shape
    case audio
}

/// Legacy effect representation retained for persisted-project migration.
enum VideoEffect: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case sepia = "Sepia"
    case noir = "Noir"
    case chrome = "Chrome"
    case blur = "Blur"
    case vignette = "Vignette"

    var id: String { rawValue }

    var effectKind: ClipEffectKind? {
        switch self {
        case .none:
            nil
        case .sepia:
            .sepia
        case .noir:
            .noir
        case .chrome:
            .chrome
        case .blur:
            .blur
        case .vignette:
            .vignette
        }
    }
}

/// Codable time range expressed in seconds.
struct TimeRangeValue: Codable, Equatable {
    var start: Double
    var duration: Double

    var end: Double { start + duration }

    init(start: Double, duration: Double) {
        self.start = max(0, start)
        self.duration = max(0, duration)
    }
}

/// A value sampled at a clip-local time.
struct Keyframe<Value: Codable & Equatable>: Identifiable, Codable, Equatable {
    var id: UUID
    var time: Double
    var value: Value
    var interpolation: KeyframeInterpolation

    init(
        id: UUID = UUID(),
        time: Double,
        value: Value,
        interpolation: KeyframeInterpolation = .linear
    ) {
        self.id = id
        self.time = max(0, time)
        self.value = value
        self.interpolation = interpolation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case value
        case interpolation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = max(try container.decode(Double.self, forKey: .time), 0)
        value = try container.decode(Value.self, forKey: .value)
        interpolation =
            try container.decodeIfPresent(KeyframeInterpolation.self, forKey: .interpolation)
            ?? .linear
    }
}

/// Normalized control point used by a cubic Bézier keyframe segment.
struct KeyframeControlPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, -4), 4)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }
}

/// Interpolation used from one keyframe to the following keyframe.
enum KeyframeInterpolation: Codable, Equatable {
    case linear
    case hold
    case cubicBezier(control1: KeyframeControlPoint, control2: KeyframeControlPoint)

    private enum CodingKeys: String, CodingKey {
        case kind
        case control1
        case control2
    }

    private enum Kind: String, Codable {
        case linear
        case hold
        case cubicBezier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .linear {
        case .linear:
            self = .linear
        case .hold:
            self = .hold
        case .cubicBezier:
            self = .cubicBezier(
                control1: try container.decode(KeyframeControlPoint.self, forKey: .control1),
                control2: try container.decode(KeyframeControlPoint.self, forKey: .control2)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear:
            try container.encode(Kind.linear, forKey: .kind)
        case .hold:
            try container.encode(Kind.hold, forKey: .kind)
        case .cubicBezier(let control1, let control2):
            try container.encode(Kind.cubicBezier, forKey: .kind)
            try container.encode(control1, forKey: .control1)
            try container.encode(control2, forKey: .control2)
        }
    }

    func progress(at linearProgress: Double) -> Double {
        let progress = min(max(linearProgress, 0), 1)
        switch self {
        case .linear:
            return progress
        case .hold:
            return progress < 1 ? 0 : 1
        case .cubicBezier(let control1, let control2):
            let parameter = solveBezierParameter(
                x: progress,
                control1X: control1.x,
                control2X: control2.x
            )
            return cubicBezierValue(
                parameter,
                control1: control1.y,
                control2: control2.y
            )
        }
    }
}

/// Built-in easing choices shown by the graph editor.
enum KeyframeCurvePreset: String, CaseIterable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold
    case fast
    case slow
    case overshoot
    case anticipate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In-Out"
        case .hold: "Hold"
        case .fast: "Fast"
        case .slow: "Slow"
        case .overshoot: "Overshoot"
        case .anticipate: "Anticipate"
        }
    }

    var interpolation: KeyframeInterpolation {
        switch self {
        case .linear:
            .linear
        case .hold:
            .hold
        case .easeIn:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.42, y: 0),
                control2: KeyframeControlPoint(x: 1, y: 1)
            )
        case .easeOut:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0, y: 0),
                control2: KeyframeControlPoint(x: 0.58, y: 1)
            )
        case .easeInOut:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.42, y: 0),
                control2: KeyframeControlPoint(x: 0.58, y: 1)
            )
        case .fast:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.2, y: 0),
                control2: KeyframeControlPoint(x: 0.2, y: 1)
            )
        case .slow:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.6, y: 0),
                control2: KeyframeControlPoint(x: 0.4, y: 1)
            )
        case .overshoot:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.34, y: 0),
                control2: KeyframeControlPoint(x: 0.64, y: 1.18)
            )
        case .anticipate:
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.36, y: -0.18),
                control2: KeyframeControlPoint(x: 0.66, y: 1)
            )
        }
    }
}

/// A base value with optional keyframes sampled in clip-local time.
struct AnimatableProperty<Value: Codable & Equatable>: Codable, Equatable {
    var baseValue: Value
    var keyframes: [Keyframe<Value>]

    init(baseValue: Value, keyframes: [Keyframe<Value>] = []) {
        self.baseValue = baseValue
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }
}

extension AnimatableProperty where Value == Double {
    func value(at time: Double) -> Double {
        guard !keyframes.isEmpty else { return baseValue }
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return baseValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        for index in 0..<(sorted.count - 1) {
            let left = sorted[index]
            let right = sorted[index + 1]
            guard time >= left.time && time <= right.time else { continue }
            let span = max(right.time - left.time, 0.001)
            let progress = (time - left.time) / span
            let curvedProgress = left.interpolation.progress(at: progress)
            return left.value + ((right.value - left.value) * curvedProgress)
        }

        return baseValue
    }

    func keyframeIndex(at time: Double, tolerance: Double) -> Int? {
        keyframes.firstIndex { abs($0.time - time) <= tolerance }
    }

    mutating func setKeyframe(
        at time: Double,
        value: Double,
        tolerance: Double,
        interpolation: KeyframeInterpolation = .linear
    ) -> UUID {
        if let index = keyframeIndex(at: time, tolerance: tolerance) {
            let id = keyframes[index].id
            keyframes[index].time = max(time, 0)
            keyframes[index].value = value
            keyframes.sort { $0.time < $1.time }
            return id
        }

        let frame = Keyframe(time: time, value: value, interpolation: interpolation)
        keyframes.append(frame)
        keyframes.sort { $0.time < $1.time }
        return frame.id
    }

    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    mutating func offsetValues(by delta: Double, range: ClosedRange<Double>) {
        baseValue = min(max(baseValue + delta, range.lowerBound), range.upperBound)
        for index in keyframes.indices {
            keyframes[index].value = min(
                max(keyframes[index].value + delta, range.lowerBound),
                range.upperBound
            )
        }
    }

    func split(at time: Double) -> (left: AnimatableProperty<Double>, right: AnimatableProperty<Double>) {
        guard !keyframes.isEmpty else { return (self, self) }
        let splitTime = max(time, 0)
        let splitValue = value(at: splitTime)
        let tolerance = 0.000_001

        if let exactIndex = keyframes.firstIndex(where: { abs($0.time - splitTime) <= tolerance }) {
            var leftFrames = Array(keyframes[...exactIndex])
            leftFrames[leftFrames.count - 1].time = splitTime
            var rightFrames = Array(keyframes[exactIndex...])
            for index in rightFrames.indices {
                rightFrames[index].time = max(rightFrames[index].time - splitTime, 0)
            }
            return (
                AnimatableProperty(baseValue: baseValue, keyframes: leftFrames),
                AnimatableProperty(baseValue: splitValue, keyframes: rightFrames)
            )
        }

        var leftFrames = keyframes.filter { $0.time < splitTime }
        var rightFrames = keyframes.filter { $0.time > splitTime }
        var leftInterpolation: KeyframeInterpolation = .linear
        var rightInterpolation: KeyframeInterpolation = .linear

        if let leftIndex = keyframes.lastIndex(where: { $0.time < splitTime }),
            leftIndex + 1 < keyframes.count
        {
            let left = keyframes[leftIndex]
            let right = keyframes[leftIndex + 1]
            let span = max(right.time - left.time, 0.000_001)
            let progress = min(max((splitTime - left.time) / span, 0), 1)
            let split = left.interpolation.split(at: progress)
            leftInterpolation = split.left
            rightInterpolation = split.right
            if let localLeftIndex = leftFrames.indices.last {
                leftFrames[localLeftIndex].interpolation = leftInterpolation
            }
        }

        leftFrames.append(Keyframe(time: splitTime, value: splitValue))
        rightFrames.insert(
            Keyframe(time: 0, value: splitValue, interpolation: rightInterpolation),
            at: 0
        )
        for index in rightFrames.indices.dropFirst() {
            rightFrames[index].time = max(rightFrames[index].time - splitTime, 0)
        }

        return (
            AnimatableProperty(baseValue: baseValue, keyframes: leftFrames),
            AnimatableProperty(baseValue: splitValue, keyframes: rightFrames)
        )
    }

    func trimmedStart(by delta: Double, oldDuration: Double) -> AnimatableProperty<Double> {
        guard !keyframes.isEmpty else { return self }
        if delta >= 0 {
            return split(at: min(delta, oldDuration)).right
        }

        let extensionDuration = -delta
        let edgeValue = value(at: 0)
        var frames = keyframes
        for index in frames.indices {
            frames[index].time += extensionDuration
        }
        frames.insert(
            Keyframe(time: 0, value: edgeValue, interpolation: .hold),
            at: 0
        )
        return AnimatableProperty(baseValue: edgeValue, keyframes: frames)
    }

    func trimmedEnd(newDuration: Double, oldDuration: Double) -> AnimatableProperty<Double> {
        guard !keyframes.isEmpty else { return self }
        let duration = max(newDuration, 0)
        if duration <= oldDuration {
            return split(at: duration).left
        }

        var frames = keyframes
        let edgeValue = value(at: oldDuration)
        if frames.last?.time ?? 0 < oldDuration - 0.000_001 {
            frames.append(Keyframe(time: oldDuration, value: edgeValue, interpolation: .hold))
        } else if let lastIndex = frames.indices.last {
            frames[lastIndex].interpolation = .hold
        }
        frames.append(Keyframe(time: duration, value: edgeValue))
        return AnimatableProperty(baseValue: baseValue, keyframes: frames)
    }

    func clamped(to range: ClosedRange<Double>) -> AnimatableProperty<Double> {
        AnimatableProperty(
            baseValue: min(max(baseValue, range.lowerBound), range.upperBound),
            keyframes: keyframes.map { frame in
                Keyframe(
                    id: frame.id,
                    time: frame.time,
                    value: min(max(frame.value, range.lowerBound), range.upperBound),
                    interpolation: frame.interpolation
                )
            }
        )
    }

    var maximumValue: Double {
        max(baseValue, keyframes.map(\.value).max() ?? baseValue)
    }
}

private extension KeyframeInterpolation {
    func split(at linearProgress: Double) -> (
        left: KeyframeInterpolation,
        right: KeyframeInterpolation
    ) {
        let progress = min(max(linearProgress, 0), 1)
        switch self {
        case .linear:
            return (.linear, .linear)
        case .hold:
            return (.hold, .hold)
        case .cubicBezier(let control1, let control2):
            let parameter = solveBezierParameter(
                x: progress,
                control1X: control1.x,
                control2X: control2.x
            )
            let p0 = KeyframeControlPoint(x: 0, y: 0)
            let p1 = control1
            let p2 = control2
            let p3 = KeyframeControlPoint(x: 1, y: 1)
            let a = interpolate(p0, p1, parameter)
            let b = interpolate(p1, p2, parameter)
            let c = interpolate(p2, p3, parameter)
            let d = interpolate(a, b, parameter)
            let e = interpolate(b, c, parameter)
            let point = interpolate(d, e, parameter)

            guard point.x > 0.000_001, 1 - point.x > 0.000_001,
                abs(point.y) > 0.000_001, abs(1 - point.y) > 0.000_001
            else {
                return (.linear, .linear)
            }

            return (
                .cubicBezier(
                    control1: normalizedPoint(a, origin: p0, end: point),
                    control2: normalizedPoint(d, origin: p0, end: point)
                ),
                .cubicBezier(
                    control1: normalizedPoint(e, origin: point, end: p3),
                    control2: normalizedPoint(c, origin: point, end: p3)
                )
            )
        }
    }
}

private func cubicBezierValue(
    _ parameter: Double,
    control1: Double,
    control2: Double
) -> Double {
    let t = min(max(parameter, 0), 1)
    let inverse = 1 - t
    return 3 * inverse * inverse * t * control1
        + 3 * inverse * t * t * control2
        + t * t * t
}

private func solveBezierParameter(
    x: Double,
    control1X: Double,
    control2X: Double
) -> Double {
    var lower = 0.0
    var upper = 1.0
    var parameter = min(max(x, 0), 1)

    for _ in 0..<18 {
        let current = cubicBezierValue(
            parameter,
            control1: control1X,
            control2: control2X
        )
        if abs(current - x) < 0.000_001 {
            break
        }
        if current < x {
            lower = parameter
        } else {
            upper = parameter
        }
        parameter = (lower + upper) * 0.5
    }
    return parameter
}

private func interpolate(
    _ left: KeyframeControlPoint,
    _ right: KeyframeControlPoint,
    _ progress: Double
) -> KeyframeControlPoint {
    KeyframeControlPoint(
        x: left.x + (right.x - left.x) * progress,
        y: left.y + (right.y - left.y) * progress
    )
}

private func normalizedPoint(
    _ point: KeyframeControlPoint,
    origin: KeyframeControlPoint,
    end: KeyframeControlPoint
) -> KeyframeControlPoint {
    KeyframeControlPoint(
        x: (point.x - origin.x) / max(end.x - origin.x, 0.000_001),
        y: (point.y - origin.y)
            / (abs(end.y - origin.y) > 0.000_001
                ? end.y - origin.y
                : 1)
    )
}
