// Data-driven text animation definitions and clip-local sampling.

import Foundation

enum TextAnimationPhase: String, Codable, CaseIterable, Sendable {
    case entrance
    case loop
    case exit
}

struct TextEntranceAnimationConfiguration: Codable, Equatable, Sendable {
    var presetID: String
    var endTime: Double
    var timing: KeyframeCurvePreset
    var customInterpolation: KeyframeInterpolation?

    var interpolation: KeyframeInterpolation {
        customInterpolation ?? timing.interpolation
    }

    init(
        presetID: String,
        endTime: Double = 0.6,
        timing: KeyframeCurvePreset = .easeOut,
        customInterpolation: KeyframeInterpolation? = nil
    ) {
        self.presetID = presetID
        self.endTime = max(endTime, 0)
        self.timing = timing
        self.customInterpolation = customInterpolation
    }

    private enum CodingKeys: String, CodingKey {
        case presetID
        case endTime
        case timing
        case customInterpolation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            presetID: try container.decodeIfPresent(String.self, forKey: .presetID) ?? "",
            endTime: try container.decodeIfPresent(Double.self, forKey: .endTime) ?? 0.6,
            timing: try container.decodeIfPresent(KeyframeCurvePreset.self, forKey: .timing) ?? .easeOut,
            customInterpolation: try container.decodeIfPresent(
                KeyframeInterpolation.self,
                forKey: .customInterpolation
            )
        )
    }
}

struct TextExitAnimationConfiguration: Codable, Equatable, Sendable {
    var presetID: String
    var startTime: Double
    var timing: KeyframeCurvePreset
    var customInterpolation: KeyframeInterpolation?

    var interpolation: KeyframeInterpolation {
        customInterpolation ?? timing.interpolation
    }

    init(
        presetID: String,
        startTime: Double = 4.4,
        timing: KeyframeCurvePreset = .easeIn,
        customInterpolation: KeyframeInterpolation? = nil
    ) {
        self.presetID = presetID
        self.startTime = max(startTime, 0)
        self.timing = timing
        self.customInterpolation = customInterpolation
    }

    private enum CodingKeys: String, CodingKey {
        case presetID
        case startTime
        case timing
        case customInterpolation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            presetID: try container.decodeIfPresent(String.self, forKey: .presetID) ?? "",
            startTime: try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0,
            timing: try container.decodeIfPresent(KeyframeCurvePreset.self, forKey: .timing) ?? .easeIn,
            customInterpolation: try container.decodeIfPresent(
                KeyframeInterpolation.self,
                forKey: .customInterpolation
            )
        )
    }
}

struct TextLoopAnimationConfiguration: Codable, Equatable, Sendable {
    var presetID: String
    var startTime: Double
    var endTime: Double
    var cycleDuration: Double
    var timing: KeyframeCurvePreset
    var customInterpolation: KeyframeInterpolation?

    var interpolation: KeyframeInterpolation {
        customInterpolation ?? timing.interpolation
    }

    init(
        presetID: String,
        startTime: Double = 0,
        endTime: Double = 5,
        cycleDuration: Double = 1,
        timing: KeyframeCurvePreset = .easeInOut,
        customInterpolation: KeyframeInterpolation? = nil
    ) {
        self.presetID = presetID
        self.startTime = max(startTime, 0)
        self.endTime = max(endTime, 0)
        self.cycleDuration = max(cycleDuration, 0.05)
        self.timing = timing
        self.customInterpolation = customInterpolation
    }

    private enum CodingKeys: String, CodingKey {
        case presetID
        case startTime
        case endTime
        case cycleDuration
        case timing
        case customInterpolation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            presetID: try container.decodeIfPresent(String.self, forKey: .presetID) ?? "",
            startTime: try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0,
            endTime: try container.decodeIfPresent(Double.self, forKey: .endTime) ?? 0,
            cycleDuration: try container.decodeIfPresent(Double.self, forKey: .cycleDuration) ?? 1,
            timing: try container.decodeIfPresent(KeyframeCurvePreset.self, forKey: .timing) ?? .easeInOut,
            customInterpolation: try container.decodeIfPresent(
                KeyframeInterpolation.self,
                forKey: .customInterpolation
            )
        )
    }
}

struct TextAnimationSet: Codable, Equatable, Sendable {
    var entrance: TextEntranceAnimationConfiguration?
    var loop: TextLoopAnimationConfiguration?
    var exit: TextExitAnimationConfiguration?

    init(
        entrance: TextEntranceAnimationConfiguration? = nil,
        loop: TextLoopAnimationConfiguration? = nil,
        exit: TextExitAnimationConfiguration? = nil
    ) {
        self.entrance = entrance
        self.loop = loop
        self.exit = exit
    }

    func normalized(for clipDuration: Double) -> TextAnimationSet {
        let duration = max(clipDuration, 0)
        var result = self

        if var entrance = result.entrance {
            entrance.endTime = min(max(entrance.endTime, 0), duration)
            result.entrance = entrance
        }
        if var exit = result.exit {
            exit.startTime = min(max(exit.startTime, 0), duration)
            result.exit = exit
        }
        if let exitStart = result.exit?.startTime,
            var entrance = result.entrance,
            entrance.endTime > exitStart
        {
            entrance.endTime = exitStart
            result.entrance = entrance
        }
        if var loop = result.loop {
            loop.startTime = min(max(loop.startTime, 0), duration)
            loop.endTime = min(max(loop.endTime, loop.startTime), duration)
            loop.cycleDuration = max(loop.cycleDuration, 0.05)
            result.loop = loop
        }
        return result
    }

    func splitting(at time: Double, duration: Double) -> (
        left: TextAnimationSet,
        right: TextAnimationSet
    ) {
        let splitTime = min(max(time, 0), max(duration, 0))
        return (
            left: trimmingEnd(newDuration: splitTime),
            right: trimmingStart(by: splitTime, oldDuration: duration)
        )
    }

    func trimmingStart(by delta: Double, oldDuration: Double) -> TextAnimationSet {
        let oldDuration = max(oldDuration, 0)
        let newDuration = max(oldDuration - delta, 0)
        var result = self

        if var entrance = result.entrance {
            entrance.endTime -= delta
            result.entrance = entrance.endTime > 0 ? entrance : nil
        }
        if var exit = result.exit {
            exit.startTime -= delta
            result.exit = exit.startTime < newDuration ? exit : nil
        }
        if var loop = result.loop {
            if delta >= 0 {
                let intersectionStart = max(loop.startTime, delta)
                let intersectionEnd = min(loop.endTime, oldDuration)
                if intersectionEnd > intersectionStart {
                    loop.startTime = intersectionStart - delta
                    loop.endTime = intersectionEnd - delta
                    result.loop = loop
                } else {
                    result.loop = nil
                }
            } else {
                loop.startTime -= delta
                loop.endTime -= delta
                result.loop = loop
            }
        }
        return result.normalized(for: newDuration)
    }

    func trimmingEnd(newDuration: Double) -> TextAnimationSet {
        let duration = max(newDuration, 0)
        var result = normalized(for: duration)
        if result.exit?.startTime == duration {
            result.exit = nil
        }
        if result.loop?.startTime == duration || result.loop?.endTime == result.loop?.startTime {
            result.loop = nil
        }
        return result
    }
}

enum TextAnimationChannel: String, Codable, CaseIterable, Sendable {
    case opacity
    case translationX
    case translationY
    case scale
    case rotationRadians
    case glyphReveal
    case clipReveal
}

struct TextAnimationValueKeyframe: Codable, Equatable, Sendable {
    var progress: Double
    var value: Double
    var interpolation: KeyframeInterpolation

    init(
        progress: Double,
        value: Double,
        interpolation: KeyframeInterpolation = .linear
    ) {
        self.progress = min(max(progress, 0), 1)
        self.value = value
        self.interpolation = interpolation
    }
}

struct TextAnimationChannelDefinition: Codable, Equatable, Sendable {
    var channel: TextAnimationChannel
    var keyframes: [TextAnimationValueKeyframe]

    init(channel: TextAnimationChannel, keyframes: [TextAnimationValueKeyframe]) {
        self.channel = channel
        self.keyframes = keyframes.sorted { $0.progress < $1.progress }
    }

    func value(at progress: Double) -> Double? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        let progress = min(max(progress, 0), 1)
        if progress <= first.progress { return first.value }
        if progress >= last.progress { return last.value }

        var lower = 0
        var upper = keyframes.count - 1
        while lower + 1 < upper {
            let midpoint = (lower + upper) / 2
            if keyframes[midpoint].progress <= progress {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        let left = keyframes[lower]
        let right = keyframes[upper]
        let span = max(right.progress - left.progress, 0.000_001)
        let curvedProgress = left.interpolation.progress(at: (progress - left.progress) / span)
        return left.value + ((right.value - left.value) * curvedProgress)
    }
}

struct TextAnimationPresetDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var phase: TextAnimationPhase
    var channels: [TextAnimationChannelDefinition]
}

struct TextAnimationSample: Codable, Equatable, Sendable {
    var opacity: Double
    var translationX: Double
    var translationY: Double
    var scale: Double
    var rotationRadians: Double
    var glyphReveal: Double
    var clipReveal: Double

    init(
        opacity: Double = 1,
        translationX: Double = 0,
        translationY: Double = 0,
        scale: Double = 1,
        rotationRadians: Double = 0,
        glyphReveal: Double = 1,
        clipReveal: Double = 1
    ) {
        self.opacity = opacity
        self.translationX = translationX
        self.translationY = translationY
        self.scale = scale
        self.rotationRadians = rotationRadians
        self.glyphReveal = glyphReveal
        self.clipReveal = clipReveal
    }

    mutating func compose(with other: TextAnimationSample) {
        opacity *= other.opacity
        translationX += other.translationX
        translationY += other.translationY
        scale *= other.scale
        rotationRadians += other.rotationRadians
        glyphReveal = min(glyphReveal, other.glyphReveal)
        clipReveal = min(clipReveal, other.clipReveal)
    }
}

enum TextAnimationPresetID {
    enum Entrance {
        static let fade = "entrance.fade"
        static let slideUp = "entrance.slideUp"
        static let slideDown = "entrance.slideDown"
        static let slideLeft = "entrance.slideLeft"
        static let slideRight = "entrance.slideRight"
        static let scale = "entrance.scale"
        static let pop = "entrance.pop"
        static let typewriter = "entrance.typewriter"
    }

    enum Exit {
        static let fade = "exit.fade"
        static let slideUp = "exit.slideUp"
        static let slideDown = "exit.slideDown"
        static let slideLeft = "exit.slideLeft"
        static let slideRight = "exit.slideRight"
        static let scale = "exit.scale"
        static let spin = "exit.spin"
        static let wipe = "exit.wipe"
    }

    enum Loop {
        static let pulse = "loop.pulse"
        static let breathe = "loop.breathe"
        static let float = "loop.float"
        static let bounce = "loop.bounce"
        static let wobble = "loop.wobble"
        static let shake = "loop.shake"
        static let swing = "loop.swing"
        static let flicker = "loop.flicker"
    }
}

enum TextAnimationPresetCatalog {
    static let all: [TextAnimationPresetDefinition] = entrance + exit + loop

    static func definitions(for phase: TextAnimationPhase) -> [TextAnimationPresetDefinition] {
        all.filter { $0.phase == phase }
    }

    static func definition(
        id: String,
        phase: TextAnimationPhase
    ) -> TextAnimationPresetDefinition? {
        all.first { $0.id == id && $0.phase == phase }
    }

    private static let entrance: [TextAnimationPresetDefinition] = [
        preset(TextAnimationPresetID.Entrance.fade, "Fade In", .entrance, [
            channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.slideUp, "Slide Up", .entrance, [
            channel(.translationY, 0.65, 0), channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.slideDown, "Slide Down", .entrance, [
            channel(.translationY, -0.65, 0), channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.slideLeft, "Slide Left", .entrance, [
            channel(.translationX, 0.65, 0), channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.slideRight, "Slide Right", .entrance, [
            channel(.translationX, -0.65, 0), channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.scale, "Scale In", .entrance, [
            channel(.scale, 0.65, 1), channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.pop, "Pop In", .entrance, [
            channel(.scale, [(0, 0.55), (0.72, 1.1), (1, 1)]),
            channel(.opacity, 0, 1)
        ]),
        preset(TextAnimationPresetID.Entrance.typewriter, "Typewriter", .entrance, [
            channel(.glyphReveal, 0, 1)
        ])
    ]

    private static let exit: [TextAnimationPresetDefinition] = [
        preset(TextAnimationPresetID.Exit.fade, "Fade Out", .exit, [
            channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.slideUp, "Slide Out Up", .exit, [
            channel(.translationY, 0, -0.65), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.slideDown, "Slide Out Down", .exit, [
            channel(.translationY, 0, 0.65), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.slideLeft, "Slide Out Left", .exit, [
            channel(.translationX, 0, -0.65), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.slideRight, "Slide Out Right", .exit, [
            channel(.translationX, 0, 0.65), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.scale, "Scale Out", .exit, [
            channel(.scale, 1, 0.65), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.spin, "Spin Out", .exit, [
            channel(.rotationRadians, 0, .pi), channel(.opacity, 1, 0)
        ]),
        preset(TextAnimationPresetID.Exit.wipe, "Wipe Out", .exit, [
            channel(.clipReveal, 1, 0)
        ])
    ]

    private static let loop: [TextAnimationPresetDefinition] = [
        preset(TextAnimationPresetID.Loop.pulse, "Pulse", .loop, [
            channel(.scale, [(0, 1), (0.5, 1.08), (1, 1)])
        ]),
        preset(TextAnimationPresetID.Loop.breathe, "Breathe", .loop, [
            channel(.scale, [(0, 1), (0.5, 1.035), (1, 1)]),
            channel(.opacity, [(0, 1), (0.5, 0.88), (1, 1)])
        ]),
        preset(TextAnimationPresetID.Loop.float, "Float", .loop, [
            channel(.translationY, [(0, 0), (0.5, -0.12), (1, 0)])
        ]),
        preset(TextAnimationPresetID.Loop.bounce, "Bounce", .loop, [
            channel(.translationY, [(0, 0), (0.42, -0.28), (0.7, 0.04), (1, 0)])
        ]),
        preset(TextAnimationPresetID.Loop.wobble, "Wobble", .loop, [
            channel(.rotationRadians, [(0, 0), (0.25, -0.08), (0.75, 0.08), (1, 0)])
        ]),
        preset(TextAnimationPresetID.Loop.shake, "Shake", .loop, [
            channel(.translationX, [
                (0, 0), (0.18, -0.05), (0.36, 0.05), (0.54, -0.035),
                (0.72, 0.035), (1, 0)
            ])
        ]),
        preset(TextAnimationPresetID.Loop.swing, "Swing", .loop, [
            channel(.rotationRadians, [(0, 0), (0.25, -0.12), (0.75, 0.12), (1, 0)])
        ]),
        preset(TextAnimationPresetID.Loop.flicker, "Flicker", .loop, [
            channel(.opacity, [(0, 1), (0.2, 0.45), (0.38, 1), (0.62, 0.7), (1, 1)])
        ])
    ]

    private static func preset(
        _ id: String,
        _ title: String,
        _ phase: TextAnimationPhase,
        _ channels: [TextAnimationChannelDefinition]
    ) -> TextAnimationPresetDefinition {
        TextAnimationPresetDefinition(id: id, title: title, phase: phase, channels: channels)
    }

    private static func channel(
        _ channel: TextAnimationChannel,
        _ start: Double,
        _ end: Double
    ) -> TextAnimationChannelDefinition {
        self.channel(channel, [(0, start), (1, end)])
    }

    private static func channel(
        _ channel: TextAnimationChannel,
        _ values: [(Double, Double)]
    ) -> TextAnimationChannelDefinition {
        TextAnimationChannelDefinition(
            channel: channel,
            keyframes: values.map {
                TextAnimationValueKeyframe(progress: $0.0, value: $0.1)
            }
        )
    }
}

enum TextAnimationEvaluator {
    static func sample(
        animations: TextAnimationSet,
        at localTime: Double,
        clipDuration: Double
    ) -> TextAnimationSample {
        let duration = max(clipDuration, 0)
        let time = min(max(localTime, 0), duration)
        let animations = animations.normalized(for: duration)
        var result = TextAnimationSample()

        if let entrance = animations.entrance,
            entrance.endTime > 0,
            time <= entrance.endTime,
            let definition = TextAnimationPresetCatalog.definition(
                id: entrance.presetID,
                phase: .entrance
            )
        {
            let progress = entrance.interpolation.progress(at: time / entrance.endTime)
            result.compose(with: sample(definition: definition, progress: progress))
        }

        if let loop = animations.loop,
            loop.endTime > loop.startTime,
            time >= loop.startTime,
            time <= loop.endTime,
            let definition = TextAnimationPresetCatalog.definition(id: loop.presetID, phase: .loop)
        {
            let elapsed = max(time - loop.startTime, 0)
            let cycleProgress = (elapsed.truncatingRemainder(dividingBy: loop.cycleDuration))
                / loop.cycleDuration
            let progress = loop.interpolation.progress(at: cycleProgress)
            result.compose(with: sample(definition: definition, progress: progress))
        }

        if let exit = animations.exit,
            duration > exit.startTime,
            time >= exit.startTime,
            let definition = TextAnimationPresetCatalog.definition(id: exit.presetID, phase: .exit)
        {
            let progress = (time - exit.startTime) / (duration - exit.startTime)
            let curvedProgress = exit.interpolation.progress(at: progress)
            result.compose(with: sample(definition: definition, progress: curvedProgress))
        }

        result.opacity = min(max(result.opacity, 0), 1)
        result.scale = max(result.scale, 0)
        result.glyphReveal = min(max(result.glyphReveal, 0), 1)
        result.clipReveal = min(max(result.clipReveal, 0), 1)
        return result
    }

    private static func sample(
        definition: TextAnimationPresetDefinition,
        progress: Double
    ) -> TextAnimationSample {
        var result = TextAnimationSample()
        for channel in definition.channels {
            guard let value = channel.value(at: progress) else { continue }
            switch channel.channel {
            case .opacity:
                result.opacity = value
            case .translationX:
                result.translationX = value
            case .translationY:
                result.translationY = value
            case .scale:
                result.scale = value
            case .rotationRadians:
                result.rotationRadians = value
            case .glyphReveal:
                result.glyphReveal = value
            case .clipReveal:
                result.clipReveal = value
            }
        }
        return result
    }
}
