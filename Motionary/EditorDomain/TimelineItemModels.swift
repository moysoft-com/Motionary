// Speed maps, masks, text styles, and compound sequence metadata.

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
    case darken
    case multiply
    case colorBurn
    case lighten
    case screen
    case colorDodge
    case overlay
    case softLight
    case hardLight
    case difference
    case exclusion
    case hue
    case saturation
    case color
    case luminosity
}

struct SpeedKeyframe: Codable, Equatable, Sendable {
    var time: Double
    var speed: Double
}

struct SpeedMapSegment: Equatable, Sendable {
    var sourceStart: Double
    var sourceDuration: Double
    var timelineDuration: Double
}

struct SpeedMap: Codable, Equatable, Sendable {
    var keyframes: [SpeedKeyframe]

    init(keyframes: [SpeedKeyframe] = []) {
        let initial = keyframes
            .map {
                SpeedKeyframe(
                    time: $0.time.isFinite ? max($0.time, 0) : 0,
                    speed: Self.boundedSpeed($0.speed)
                )
            }
            .sorted { $0.time < $1.time }
            .first
        self.keyframes = [
            SpeedKeyframe(time: 0, speed: initial?.speed ?? 1)
        ]
    }

    static let constant = constant(speed: 1)

    static func constant(speed: Double) -> SpeedMap {
        SpeedMap(
            keyframes: [SpeedKeyframe(time: 0, speed: boundedSpeed(speed))]
        )
    }

    var hasVariableSpeed: Bool {
        guard let firstSpeed = keyframes.first?.speed else { return false }
        return keyframes.dropFirst().contains {
            abs($0.speed - firstSpeed) > 0.000_001
        }
    }

    func speed(at sourceTime: Double) -> Double {
        guard let first = keyframes.first else { return 1 }
        let sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        return keyframes.last(where: { $0.time <= sourceTime + 0.000_001 })?.speed
            ?? first.speed
    }

    func timelineDuration(sourceDuration: Double) -> Double {
        let safeDuration = Self.safeDuration(sourceDuration)
        guard safeDuration > 0 else { return 0 }
        return renderSegments(sourceDuration: safeDuration)
            .reduce(0) { $0 + $1.timelineDuration }
    }

    func timelineTime(at sourceTime: Double, sourceDuration: Double) -> Double {
        let safeDuration = Self.safeDuration(sourceDuration)
        let safeSourceTime = sourceTime.isFinite ? sourceTime : 0
        let target = min(max(safeSourceTime, 0), safeDuration)
        var elapsed = 0.0
        for segment in renderSegments(sourceDuration: safeDuration) {
            let segmentSourceEnd = segment.sourceStart + segment.sourceDuration
            if target >= segmentSourceEnd {
                elapsed += segment.timelineDuration
                continue
            }
            if target > segment.sourceStart {
                elapsed += (target - segment.sourceStart)
                    / segment.sourceDuration
                    * segment.timelineDuration
            }
            break
        }
        return elapsed
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
        let safeDuration = Self.safeDuration(sourceDuration)
        let safeTimelineTime = timelineTime.isFinite ? timelineTime : 0
        guard safeDuration > 0, safeTimelineTime > 0 else { return 0 }
        let target = min(
            safeTimelineTime,
            self.timelineDuration(sourceDuration: safeDuration)
        )
        var elapsed = 0.0
        for segment in renderSegments(sourceDuration: safeDuration) {
            let segmentEnd = elapsed + segment.timelineDuration
            if target <= segmentEnd + 0.000_000_001 {
                let localTimelineTime = min(max(target - elapsed, 0), segment.timelineDuration)
                return min(
                    segment.sourceStart
                        + localTimelineTime
                        / segment.timelineDuration
                        * segment.sourceDuration,
                    segment.sourceStart + segment.sourceDuration
                )
            }
            elapsed = segmentEnd
        }
        return safeDuration
    }

    func renderSegments(sourceDuration: Double) -> [SpeedMapSegment] {
        let duration = Self.safeDuration(sourceDuration)
        guard duration > 0 else { return [] }
        var result: [SpeedMapSegment] = []
        var sourceStart = 0.0
        var currentSpeed = keyframes.first?.speed ?? 1

        for keyframe in keyframes.dropFirst() {
            guard keyframe.time < duration else { break }
            let segmentDuration = keyframe.time - sourceStart
            if segmentDuration > 0 {
                result.append(
                    SpeedMapSegment(
                        sourceStart: sourceStart,
                        sourceDuration: segmentDuration,
                        timelineDuration: segmentDuration / currentSpeed
                    )
                )
            }
            sourceStart = keyframe.time
            currentSpeed = keyframe.speed
        }
        let finalDuration = duration - sourceStart
        if finalDuration > 0 {
            result.append(
                SpeedMapSegment(
                    sourceStart: sourceStart,
                    sourceDuration: finalDuration,
                    timelineDuration: finalDuration / currentSpeed
                )
            )
        }
        return result
    }

    /// Removes speed points that cannot affect this source range. The zero-time
    /// anchor is retained because every speed map needs an initial segment value.
    func clamped(toSourceDuration sourceDuration: Double) -> SpeedMap {
        let duration = sourceDuration.isFinite ? max(sourceDuration, 0) : 0
        guard duration > 0 else {
            return .constant(speed: keyframes.first?.speed ?? 1)
        }
        let relevant = keyframes.filter {
            $0.time <= 0.000_001 || $0.time < duration - 0.000_001
        }
        return SpeedMap(keyframes: relevant)
    }

    func sliced(from sourceStart: Double, duration: Double) -> SpeedMap {
        let start = sourceStart.isFinite ? sourceStart : 0
        let sliceDuration = duration.isFinite ? max(duration, 0) : 0
        let sampledStart = max(start, 0)
        let sourceEnd = start + sliceDuration
        var slicedKeyframes = [SpeedKeyframe(time: 0, speed: speed(at: sampledStart))]
        slicedKeyframes.append(
            contentsOf: keyframes.compactMap { keyframe in
                guard keyframe.time > sampledStart + 0.000_001,
                    keyframe.time < sourceEnd - 0.000_001
                else { return nil }
                return SpeedKeyframe(
                    time: keyframe.time - start,
                    speed: keyframe.speed
                )
            }
        )
        return SpeedMap(keyframes: slicedKeyframes)
    }

    func hasKeyframe(at sourceTime: Double, tolerance: Double) -> Bool {
        keyframes.contains { abs($0.time - sourceTime) <= tolerance }
    }

    func addingKeyframe(at sourceTime: Double, tolerance: Double) -> SpeedMap {
        guard !hasKeyframe(at: sourceTime, tolerance: tolerance) else { return self }
        let sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        var updated = keyframes
        updated.append(
            SpeedKeyframe(
                time: sourceTime,
                speed: speed(at: sourceTime)
            )
        )
        return SpeedMap(keyframes: updated)
    }

    func removingKeyframe(at sourceTime: Double, tolerance: Double) -> SpeedMap {
        guard sourceTime > tolerance else { return self }
        let updated = keyframes.filter { abs($0.time - sourceTime) > tolerance }
        return SpeedMap(keyframes: updated)
    }

    func settingSpeed(
        _ speed: Double,
        at sourceTime: Double,
        createKeyframe: Bool,
        tolerance: Double
    ) -> SpeedMap {
        guard createKeyframe else { return .constant(speed: speed) }
        let sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        var updated = keyframes
        if let index = updated.firstIndex(where: { abs($0.time - sourceTime) <= tolerance }) {
            updated[index].speed = Self.boundedSpeed(speed)
        } else {
            updated.append(
                SpeedKeyframe(
                    time: sourceTime,
                    speed: Self.boundedSpeed(speed)
                )
            )
        }
        return SpeedMap(keyframes: updated)
    }

    private static func boundedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max(speed, 0.1), 8)
    }

    private static func safeDuration(_ duration: Double) -> Double {
        duration.isFinite ? max(duration, 0) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case keyframes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyframes = try container.decodeIfPresent([SpeedKeyframe].self, forKey: .keyframes) ?? []
        self.init(keyframes: keyframes)
    }
}

struct ItemMask: Codable, Equatable, Sendable {
    enum Shape: String, Codable, Sendable {
        case rectangle
        case roundedRectangle
        case ellipse
        case diamond
        case triangle
        case star
        case heart
        case bar
        case split
    }

    var shape: Shape
    var widthScale: Double
    var heightScale: Double
    var featherScale: Double
    var roundnessScale: Double
    var rotationDegrees: Double
    var offsetScale: Double
    var isInverted: Bool

    /// Legacy initializer retained for existing call sites and decoded projects.
    init(
        shape: Shape = .rectangle,
        insetX: Double = 0,
        insetY: Double = 0,
        feather: Double = 0
    ) {
        self.shape = shape
        widthScale = 1 - Self.bounded(insetX, to: 0...0.48) * 2
        heightScale = 1 - Self.bounded(insetY, to: 0...0.48) * 2
        featherScale = Self.bounded(feather, to: 0...0.25)
        roundnessScale = shape == .roundedRectangle ? 0.36 : 0
        rotationDegrees = 0
        offsetScale = 0
        isInverted = false
    }

    init(
        shape: Shape,
        widthScale: Double,
        heightScale: Double,
        featherScale: Double = 0,
        roundnessScale: Double? = nil,
        rotationDegrees: Double = 0,
        offsetScale: Double = 0,
        isInverted: Bool = false
    ) {
        self.shape = shape
        self.widthScale = Self.bounded(widthScale, to: 0...1)
        self.heightScale = Self.bounded(heightScale, to: 0...1)
        self.featherScale = Self.bounded(featherScale, to: 0...1)
        self.roundnessScale = Self.bounded(
            roundnessScale ?? (shape == .roundedRectangle ? 0.36 : 0),
            to: 0...1
        )
        self.rotationDegrees = Self.bounded(rotationDegrees, to: -180...180)
        self.offsetScale = Self.bounded(offsetScale, to: -1...1)
        self.isInverted = isInverted
    }

    var insetX: Double {
        (1 - widthScale) * 0.5
    }

    var insetY: Double {
        (1 - heightScale) * 0.5
    }

    var feather: Double {
        featherScale
    }

    private enum CodingKeys: String, CodingKey {
        case shape
        case widthScale
        case heightScale
        case featherScale
        case roundnessScale
        case rotationDegrees
        case offsetScale
        case isInverted
        case insetX
        case insetY
        case feather
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .rectangle
        if container.contains(.widthScale) || container.contains(.heightScale) {
            self.init(
                shape: shape,
                widthScale: try container.decodeIfPresent(Double.self, forKey: .widthScale) ?? 1,
                heightScale: try container.decodeIfPresent(Double.self, forKey: .heightScale) ?? 1,
                featherScale: try container.decodeIfPresent(Double.self, forKey: .featherScale) ?? 0,
                roundnessScale: try container.decodeIfPresent(Double.self, forKey: .roundnessScale),
                rotationDegrees: try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
                offsetScale: try container.decodeIfPresent(Double.self, forKey: .offsetScale) ?? 0,
                isInverted: try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
            )
        } else {
            self.init(
                shape: shape,
                insetX: try container.decodeIfPresent(Double.self, forKey: .insetX) ?? 0,
                insetY: try container.decodeIfPresent(Double.self, forKey: .insetY) ?? 0,
                feather: try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shape, forKey: .shape)
        try container.encode(widthScale, forKey: .widthScale)
        try container.encode(heightScale, forKey: .heightScale)
        try container.encode(featherScale, forKey: .featherScale)
        try container.encode(roundnessScale, forKey: .roundnessScale)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(offsetScale, forKey: .offsetScale)
        try container.encode(isInverted, forKey: .isInverted)
    }

    private static func bounded(
        _ value: Double,
        to range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
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
    var blendIntensity: Double
    var mask: ItemMask?
    var backgroundRemoval: BackgroundRemovalSettings?

    init(
        transform: ClipTransform = ClipTransform(),
        adjustments: AdjustmentSettings = AdjustmentSettings(),
        effectStack: EffectStack = EffectStack(),
        volume: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        blendMode: BlendMode = .normal,
        blendIntensity: Double = 1,
        mask: ItemMask? = nil,
        backgroundRemoval: BackgroundRemovalSettings? = nil
    ) {
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.volume = volume.clamped(to: 0...2)
        self.blendMode = blendMode
        self.blendIntensity = min(max(blendIntensity.isFinite ? blendIntensity : 1, 0), 1)
        self.mask = mask
        self.backgroundRemoval = backgroundRemoval
    }

    private enum CodingKeys: String, CodingKey {
        case transform
        case adjustments
        case effectStack
        case volume
        case blendMode
        case blendIntensity
        case mask
        case backgroundRemoval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVolume: AnimatableProperty<Double>
        if let property = try? container.decode(AnimatableProperty<Double>.self, forKey: .volume) {
            decodedVolume = property
        } else {
            let legacyVolume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
            decodedVolume = AnimatableProperty(baseValue: min(max(legacyVolume, 0), 2))
        }
        self.init(
            transform: try container.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform(),
            adjustments: try container.decodeIfPresent(AdjustmentSettings.self, forKey: .adjustments) ?? AdjustmentSettings(),
            effectStack: try container.decodeIfPresent(EffectStack.self, forKey: .effectStack) ?? EffectStack(),
            volume: decodedVolume,
            blendMode: try container.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal,
            blendIntensity: try container.decodeIfPresent(Double.self, forKey: .blendIntensity) ?? 1,
            mask: try container.decodeIfPresent(ItemMask.self, forKey: .mask),
            backgroundRemoval: try container.decodeIfPresent(BackgroundRemovalSettings.self, forKey: .backgroundRemoval)
        )
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
