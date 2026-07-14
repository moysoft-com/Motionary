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

struct TextStrokeStyle: Codable, Equatable, Sendable {
    var color: RGBAColor
    var width: Double

    init(color: RGBAColor = .black, width: Double = 2) {
        self.color = color
        self.width = max(width, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case width
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .black,
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 2
        )
    }
}

struct TextShadowStyle: Codable, Equatable, Sendable {
    var color: RGBAColor
    var offsetX: Double
    var offsetY: Double
    var blur: Double

    init(
        color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65),
        offsetX: Double = 3,
        offsetY: Double = 3,
        blur: Double = 6
    ) {
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blur = max(blur, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case offsetX
        case offsetY
        case blur
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try container.decodeIfPresent(RGBAColor.self, forKey: .color)
                ?? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65),
            offsetX: try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 3,
            offsetY: try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 3,
            blur: try container.decodeIfPresent(Double.self, forKey: .blur) ?? 6
        )
    }
}

struct TextBackgroundStyle: Codable, Equatable, Sendable {
    var color: RGBAColor
    var padding: Double
    var cornerRadius: Double

    init(
        color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65),
        padding: Double = 12,
        cornerRadius: Double = 8
    ) {
        self.color = color
        self.padding = max(padding, 0)
        self.cornerRadius = max(cornerRadius, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case padding
        case cornerRadius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            color: try container.decodeIfPresent(RGBAColor.self, forKey: .color)
                ?? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65),
            padding: try container.decodeIfPresent(Double.self, forKey: .padding) ?? 12,
            cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 8
        )
    }
}

struct TextStyle: Codable, Equatable, Sendable {
    var fontName: String
    var fontSize: Double
    var color: RGBAColor
    var alignment: TextAlignment
    var letterSpacing: Double
    var lineSpacing: Double
    var stroke: TextStrokeStyle?
    var shadow: TextShadowStyle?
    var background: TextBackgroundStyle?

    enum TextAlignment: String, Codable, Sendable {
        case leading
        case center
        case trailing
    }

    init(
        fontName: String = ".AppleSystemUIFont",
        fontSize: Double = 48,
        color: RGBAColor = .white,
        alignment: TextAlignment = .center,
        letterSpacing: Double = 0,
        lineSpacing: Double = 0,
        stroke: TextStrokeStyle? = nil,
        shadow: TextShadowStyle? = nil,
        background: TextBackgroundStyle? = nil
    ) {
        self.fontName = fontName
        self.fontSize = max(fontSize, 8)
        self.color = color
        self.alignment = alignment
        self.letterSpacing = letterSpacing
        self.lineSpacing = lineSpacing
        self.stroke = stroke
        self.shadow = shadow
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case fontName
        case fontSize
        case color
        case alignment
        case letterSpacing
        case lineSpacing
        case stroke
        case shadow
        case background
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontName: try container.decodeIfPresent(String.self, forKey: .fontName)
                ?? ".AppleSystemUIFont",
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48,
            color: try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white,
            alignment: try container.decodeIfPresent(TextAlignment.self, forKey: .alignment)
                ?? .center,
            letterSpacing: try container.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0,
            lineSpacing: try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0,
            stroke: try container.decodeIfPresent(TextStrokeStyle.self, forKey: .stroke),
            shadow: try container.decodeIfPresent(TextShadowStyle.self, forKey: .shadow),
            background: try container.decodeIfPresent(TextBackgroundStyle.self, forKey: .background)
        )
    }
}

struct TextLayout: Codable, Equatable, Sendable {
    var widthFraction: Double

    init(widthFraction: Double = 0.8) {
        self.widthFraction = min(max(widthFraction, 0.1), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case widthFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            widthFraction: try container.decodeIfPresent(Double.self, forKey: .widthFraction) ?? 0.8
        )
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

extension TimelineItemVisuals {
    func splittingAnimations(at time: Double) -> (left: TimelineItemVisuals, right: TimelineItemVisuals) {
        let split = animationCarrier.splittingAnimations(at: time)
        return (
            left: applyingAnimations(from: split.left),
            right: applyingAnimations(from: split.right)
        )
    }

    mutating func trimAnimationsAtStart(by delta: Double, oldDuration: Double) {
        var carrier = animationCarrier
        carrier.trimAnimationsAtStart(by: delta, oldDuration: oldDuration)
        self = applyingAnimations(from: carrier)
    }

    mutating func trimAnimationsAtEnd(newDuration: Double, oldDuration: Double) {
        var carrier = animationCarrier
        carrier.trimAnimationsAtEnd(newDuration: newDuration, oldDuration: oldDuration)
        self = applyingAnimations(from: carrier)
    }

    private var animationCarrier: TimelineClip {
        TimelineClip(
            name: "Timeline item",
            mediaID: MediaID(),
            mediaType: .video,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1),
            transform: transform,
            adjustments: adjustments,
            effectStack: effectStack,
            volume: volume
        )
    }

    private func applyingAnimations(from clip: TimelineClip) -> TimelineItemVisuals {
        var result = self
        result.transform = clip.transform
        result.adjustments = clip.adjustments
        result.effectStack = clip.effectStack
        result.volume = clip.volume
        return result
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
