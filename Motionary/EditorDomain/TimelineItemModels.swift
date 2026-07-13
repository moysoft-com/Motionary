// Transitions, speed maps, masks, text styles, and compound sequence metadata.

import Foundation

enum TimelineItemKind: String, Codable, CaseIterable, Sendable {
    case media
    case shape
    case text
    case caption
    case adjustment
    case compound
}

enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight
}

enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case crossDissolve
    case fadeToBlack
    case wipeLeft
}

struct TimelineTransition: Codable, Equatable, Sendable {
    var kind: TransitionKind
    var duration: Double

    init(kind: TransitionKind = .crossDissolve, duration: Double = 0.5) {
        self.kind = kind
        self.duration = max(0, duration)
    }
}

struct SpeedKeyframe: Codable, Equatable, Sendable {
    var time: Double
    var speed: Double
}

struct SpeedMap: Codable, Equatable, Sendable {
    var keyframes: [SpeedKeyframe]

    init(keyframes: [SpeedKeyframe] = []) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    static let constant = SpeedMap(keyframes: [SpeedKeyframe(time: 0, speed: 1)])

    func speed(at sourceTime: Double) -> Double {
        guard !keyframes.isEmpty else { return 1 }
        guard let first = keyframes.first, let last = keyframes.last else { return 1 }
        if sourceTime <= first.time { return max(first.speed, 0.01) }
        if sourceTime >= last.time { return max(last.speed, 0.01) }

        var lower = 0
        var upper = keyframes.count - 1
        while lower + 1 < upper {
            let midpoint = (lower + upper) / 2
            if keyframes[midpoint].time <= sourceTime {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        let left = keyframes[lower]
        let right = keyframes[upper]
        let span = max(right.time - left.time, 0.000_001)
        let progress = (sourceTime - left.time) / span
        return max(left.speed + (right.speed - left.speed) * progress, 0.01)
    }

    func timelineDuration(sourceDuration: Double) -> Double {
        let safeDuration = max(sourceDuration, 0)
        guard safeDuration > 0 else { return 0 }
        if keyframes.isEmpty || (keyframes.count == 1 && abs(keyframes[0].speed - 1) < 0.0001) {
            return safeDuration
        }
        let sampleCount = min(max(Int(safeDuration * 12), 1), 96)
        let step = safeDuration / Double(sampleCount)
        var timelineTime = 0.0
        for index in 0..<sampleCount {
            let sourceTime = min(Double(index) * step, safeDuration)
            timelineTime += step / speed(at: sourceTime)
        }
        return timelineTime
    }

    var topologySignature: UInt64 {
        var hasher = Hasher()
        hasher.combine(keyframes.count)
        for keyframe in keyframes {
            hasher.combine(keyframe.time)
            hasher.combine(keyframe.speed)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func sourceTime(at timelineTime: Double, sourceDuration: Double) -> Double {
        let safeDuration = max(sourceDuration, 0)
        guard safeDuration > 0, timelineTime > 0 else { return 0 }
        let target = min(max(timelineTime, 0), timelineDuration(sourceDuration: safeDuration))
        var elapsed = 0.0
        let sampleCount = max(Int(safeDuration * 60), 1)
        let step = safeDuration / Double(sampleCount)
        var sourceCursor = 0.0
        while sourceCursor < safeDuration {
            let localSpeed = speed(at: sourceCursor)
            let timelineStep = step / localSpeed
            if elapsed + timelineStep >= target {
                let remaining = target - elapsed
                return min(sourceCursor + remaining * localSpeed, safeDuration)
            }
            elapsed += timelineStep
            sourceCursor += step
        }
        return safeDuration
    }
}

struct ItemMask: Codable, Equatable, Sendable {
    enum Shape: String, Codable, Sendable {
        case rectangle
        case ellipse
    }

    var shape: Shape
    var insetX: Double
    var insetY: Double
    var feather: Double

    init(
        shape: Shape = .rectangle,
        insetX: Double = 0,
        insetY: Double = 0,
        feather: Double = 0
    ) {
        self.shape = shape
        self.insetX = max(0, insetX)
        self.insetY = max(0, insetY)
        self.feather = max(0, feather)
    }
}

struct TextStyle: Codable, Equatable, Sendable {
    var fontName: String
    var fontSize: Double
    var color: RGBAColor
    var alignment: TextAlignment

    enum TextAlignment: String, Codable, Sendable {
        case leading
        case center
        case trailing
    }

    init(
        fontName: String = ".AppleSystemUIFont",
        fontSize: Double = 48,
        color: RGBAColor = .white,
        alignment: TextAlignment = .center
    ) {
        self.fontName = fontName
        self.fontSize = max(fontSize, 8)
        self.color = color
        self.alignment = alignment
    }
}

struct TimelineItemVisuals: Codable, Equatable, Sendable {
    var transform: ClipTransform
    var adjustments: AdjustmentSettings
    var effectStack: EffectStack
    var volume: AnimatableProperty<Double>
    var blendMode: BlendMode
    var mask: ItemMask?

    init(
        transform: ClipTransform = ClipTransform(),
        adjustments: AdjustmentSettings = AdjustmentSettings(),
        effectStack: EffectStack = EffectStack(),
        volume: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        blendMode: BlendMode = .normal,
        mask: ItemMask? = nil
    ) {
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.volume = volume.clamped(to: 0...2)
        self.blendMode = blendMode
        self.mask = mask
    }
}

struct CompoundSequence: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var tracks: [TimelineTrack]

    init(id: UUID = UUID(), name: String, tracks: [TimelineTrack] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }
}

struct ItemLink: Codable, Equatable, Sendable {
    var id: UUID
    var itemIDs: [UUID]

    init(id: UUID = UUID(), itemIDs: [UUID]) {
        self.id = id
        self.itemIDs = itemIDs
    }
}
