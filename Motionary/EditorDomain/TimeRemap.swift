import Foundation

/// Maps clip-local timeline seconds to seconds within the trimmed source.
struct TimeRemap: Codable, Equatable, Sendable {
    private(set) var keyframes: [Keyframe<Double>]
    let sourceDuration: Double
    private(set) var duration: Double
    private(set) var baseValue: Double

    init?(sourceDuration: Double, timelineDuration: Double) {
        guard sourceDuration.isFinite, sourceDuration > 0,
            timelineDuration.isFinite, timelineDuration > 0
        else { return nil }
        self.sourceDuration = sourceDuration
        self.duration = timelineDuration
        self.baseValue = 0
        keyframes = [
            Keyframe(time: 0, value: 0),
            Keyframe(time: timelineDuration, value: sourceDuration)
        ]
    }

    private init(keyframes: [Keyframe<Double>], sourceDuration: Double, duration: Double, baseValue: Double) {
        self.keyframes = keyframes
        self.sourceDuration = sourceDuration
        self.duration = duration
        self.baseValue = baseValue
    }

    private enum CodingKeys: String, CodingKey { case keyframes, sourceDuration, duration, baseValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try container.decode([Keyframe<Double>].self, forKey: .keyframes)
        let sourceDuration =
            try container.decodeIfPresent(Double.self, forKey: .sourceDuration)
            ?? frames.last?.value ?? 0
        let duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? frames.last?.time ?? 0
        let baseValue = try container.decodeIfPresent(Double.self, forKey: .baseValue) ?? frames.first?.value ?? 0
        guard sourceDuration.isFinite, sourceDuration > 0, duration.isFinite, duration > 0,
            baseValue.isFinite, (0...sourceDuration).contains(baseValue),
            frames.allSatisfy({ $0.time.isFinite && (0...duration).contains($0.time) && (0...sourceDuration).contains($0.value) }),
            zip(frames, frames.dropFirst()).allSatisfy({ $0.time < $1.time })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyframes, in: container, debugDescription: "Invalid time remap keyframes."
            )
        }
        self.sourceDuration = sourceDuration
        self.duration = duration
        self.baseValue = baseValue
        keyframes = frames.map { frame in
            var frame = frame
            frame.interpolation = Self.supportedInterpolation(frame.interpolation)
            return frame
        }
    }

    var averageSpeed: Double { sourceDuration / duration }

    var hasReverse: Bool {
        zip(keyframes, keyframes.dropFirst()).contains {
            $0.value > $1.value && $0.interpolation != .hold
        }
    }

    var hasVariableSpeed: Bool {
        guard keyframes.first?.value == 0, keyframes.last?.value == sourceDuration else { return true }
        let speed = averageSpeed
        return zip(keyframes, keyframes.dropFirst()).contains { left, right in
            left.interpolation != .linear
                || abs((right.value - left.value) - (right.time - left.time) * speed) > 0.000_001
        }
    }

    func sourceTime(at time: Double) -> Double {
        guard let first = keyframes.first, let last = keyframes.last else { return baseValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        let index = segmentIndex(at: time)
        let left = keyframes[index]
        let right = keyframes[index + 1]
        let progress = (time - left.time) / (right.time - left.time)
        return left.value + (right.value - left.value) * left.interpolation.progress(at: progress)
    }

    /// One source instant can occur more than once on the timeline.
    func timelineTimes(at sourceTime: Double) -> [Double] {
        var times: [Double] = []
        for (left, right) in zip(keyframes, keyframes.dropFirst()) {
            let lower = min(left.value, right.value)
            let upper = max(left.value, right.value)
            guard (lower...upper).contains(sourceTime) else { continue }
            let time: Double
            if left.value == sourceTime {
                time = left.time
            } else if right.value == sourceTime {
                time = right.time
            } else {
                guard left.interpolation != .hold else { continue }
                let progress = (sourceTime - left.value) / (right.value - left.value)
                let inverse: KeyframeInterpolation
                if case .cubicBezier(let a, let b) = left.interpolation {
                    inverse = .cubicBezier(
                        control1: KeyframeControlPoint(x: a.y, y: a.x),
                        control2: KeyframeControlPoint(x: b.y, y: b.x)
                    )
                } else {
                    inverse = .linear
                }
                time = left.time + (right.time - left.time) * inverse.progress(at: progress)
            }
            if times.last != time { times.append(time) }
        }
        return times
    }

    func timelineTime(at sourceTime: Double) -> Double {
        timelineTimes(at: sourceTime).first ?? 0
    }

    func keyframeIndex(at time: Double, tolerance: Double) -> Int? {
        guard !keyframes.isEmpty else { return nil }
        if keyframes.count == 1 {
            return abs(keyframes[0].time - time) <= tolerance ? 0 : nil
        }
        let left = segmentIndex(at: time)
        let right = left + 1
        let nearest = abs(keyframes[left].time - time) <= abs(keyframes[right].time - time) ? left : right
        return abs(keyframes[nearest].time - time) <= tolerance ? nearest : nil
    }

    func graphIndex(at time: Double, tolerance: Double) -> Int {
        min(
            keyframeIndex(at: time, tolerance: tolerance) ?? segmentIndex(at: time),
            keyframes.count - 2)
    }

    mutating func toggleKeyframe(at time: Double, tolerance: Double) {
        if let index = keyframeIndex(at: time, tolerance: tolerance) {
            let value = sourceTime(at: time)
            keyframes.remove(at: index)
            if keyframes.isEmpty { baseValue = value }
        } else {
            insertKeyframe(at: time)
        }
    }

    mutating func setSourceTime(_ sourceTime: Double, at time: Double, tolerance: Double) {
        guard sourceTime.isFinite, (0...duration).contains(time) else { return }
        let value = min(max(sourceTime, 0), sourceDuration)
        if keyframes.isEmpty {
            baseValue = value
        } else if let index = keyframeIndex(at: time, tolerance: tolerance) {
            keyframes[index].value = value
        } else {
            insertKeyframe(at: time, sourceValue: value)
        }
    }

    mutating func setInterpolation(_ interpolation: KeyframeInterpolation, at time: Double) {
        guard let index = keyframeIndex(at: time, tolerance: 0.000_001),
            index < keyframes.count - 1
        else { return }
        keyframes[index].interpolation = Self.supportedInterpolation(interpolation)
    }

    func rebased(from sourceOffset: Double, sourceDuration: Double) -> TimeRemap? {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return nil }
        if sourceOffset == 0, sourceDuration == self.sourceDuration { return self }
        return TimeRemap(
            keyframes: keyframes.map { frame in
                var frame = frame
                frame.value = min(max(frame.value - sourceOffset, 0), sourceDuration)
                return frame
            }, sourceDuration: sourceDuration, duration: duration,
            baseValue: min(max(baseValue - sourceOffset, 0), sourceDuration))
    }

    func sliced(fromTimelineTime start: Double, duration sliceDuration: Double) -> TimeRemap {
        guard start.isFinite, sliceDuration.isFinite, sliceDuration > 0 else { return self }
        if start == 0, sliceDuration == duration { return self }
        let end = start + sliceDuration
        var copy = self
        if let first = copy.keyframes.first, let last = copy.keyframes.last, copy.keyframes.count >= 2 {
            if start > first.time && start < last.time { copy.insertKeyframe(at: start) }
            if end > first.time && end < last.time { copy.insertKeyframe(at: end) }
        }
        let frames = copy.keyframes.compactMap { frame -> Keyframe<Double>? in
            guard frame.time >= start, frame.time <= end else { return nil }
            var frame = frame
            frame.time -= start
            return frame
        }
        return TimeRemap(keyframes: frames, sourceDuration: sourceDuration,
                         duration: sliceDuration, baseValue: sourceTime(at: start))
    }

    func holdsSource(at time: Double) -> Bool {
        guard keyframes.count >= 2, let first = keyframes.first, let last = keyframes.last,
            time >= first.time, time < last.time else { return true }
        let index = segmentIndex(at: time)
        let left = keyframes[index]
        return left.interpolation == .hold || left.value == keyframes[index + 1].value
    }

    /// Samples curved segments into contiguous linear edits for AVFoundation.
    /// The domain curve is still used for the playhead, thumbnails and snapping.
    func renderSegments() -> [SpeedMapSegment] {
        var segments: [SpeedMapSegment] = []
        if let first = keyframes.first, first.time > 0 {
            segments.append(SpeedMapSegment(sourceStart: first.value, sourceDuration: 0, timelineDuration: first.time))
        }
        for (left, right) in zip(keyframes, keyframes.dropFirst()) {
            let sourceSpan = right.value - left.value
            let timelineSpan = right.time - left.time
            if left.interpolation == .hold {
                segments.append(
                    SpeedMapSegment(
                        sourceStart: left.value, sourceDuration: 0, timelineDuration: timelineSpan))
                continue
            }
            func append(_ start: Double, _ end: Double, _ a: Double, _ b: Double, depth: Int) {
                if left.interpolation != .linear, depth < 8,
                    (end - start) * timelineSpan > 1.0 / 30,
                    (b - a) * abs(sourceSpan) > 0.002
                {
                    let step = (end - start) * 0.25
                    let q1 = left.interpolation.progress(at: start + step)
                    let mid = left.interpolation.progress(at: start + step * 2)
                    let q3 = left.interpolation.progress(at: start + step * 3)
                    let span = b - a
                    let error = max(
                        abs(q1 - (a + span * 0.25)),
                        abs(mid - (a + span * 0.5)),
                        abs(q3 - (a + span * 0.75))
                    )
                    if error * abs(sourceSpan) > 1.0 / 480,
                        min(mid - a, b - mid) * abs(sourceSpan) > 2.0 / 60_000
                    {
                        let middle = (start + end) * 0.5
                        append(start, middle, a, mid, depth: depth + 1)
                        append(middle, end, mid, b, depth: depth + 1)
                        return
                    }
                }
                segments.append(
                    SpeedMapSegment(
                        sourceStart: left.value + a * sourceSpan,
                        sourceDuration: (b - a) * sourceSpan,
                        timelineDuration: (end - start) * timelineSpan
                    ))
            }
            append(0, 1, 0, 1, depth: 0)
        }
        let trailingStart = keyframes.last?.time ?? 0
        if trailingStart < duration {
            segments.append(SpeedMapSegment(sourceStart: keyframes.last?.value ?? baseValue,
                                            sourceDuration: 0, timelineDuration: duration - trailingStart))
        }
        return segments
    }

    static func supportedInterpolation(_ interpolation: KeyframeInterpolation) -> KeyframeInterpolation {
        if interpolation == .hold { return .hold }
        guard case .cubicBezier(let a, let b) = interpolation else { return .linear }
        return .cubicBezier(
            control1: KeyframeControlPoint(x: a.x, y: min(max(a.y, 0), 1)),
            control2: KeyframeControlPoint(x: b.x, y: min(max(b.y, 0), 1))
        )
    }

    private func segmentIndex(at value: Double) -> Int {
        var lower = 0
        var upper = keyframes.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if keyframes[middle].time <= value {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower
    }

    private mutating func insertKeyframe(at time: Double, sourceValue: Double? = nil) {
        guard (0...duration).contains(time) else { return }
        let value = sourceValue ?? sourceTime(at: time)
        guard let first = keyframes.first, let last = keyframes.last else {
            keyframes = [Keyframe(time: time, value: value)]
            return
        }
        if time < first.time {
            keyframes.insert(Keyframe(time: time, value: value), at: 0)
            return
        }
        if time > last.time {
            keyframes.append(Keyframe(time: time, value: value))
            return
        }
        guard time > first.time, time < last.time else { return }
        let index = segmentIndex(at: time)
        let left = keyframes[index]
        let right = keyframes[index + 1]
        guard left.time < time else { return }
        let progress = (time - left.time) / (right.time - left.time)
        let split = left.interpolation.split(at: progress)
        keyframes[index].interpolation = split.left
        keyframes.insert(Keyframe(time: time, value: value, interpolation: split.right), at: index + 1)
    }
}
