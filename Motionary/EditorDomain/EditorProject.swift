import CoreGraphics
import Foundation

enum ClipMediaType: String, Codable, CaseIterable {
    case video
    case image
    case audio
}

enum TrackKind: String, Codable, CaseIterable {
    case visual
    case audio
}

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

struct TimeRangeValue: Codable, Equatable {
    var start: Double
    var duration: Double

    var end: Double { start + duration }

    init(start: Double, duration: Double) {
        self.start = max(0, start)
        self.duration = max(0, duration)
    }
}

struct Keyframe<Value: Codable & Equatable>: Identifiable, Codable, Equatable {
    var id: UUID
    var time: Double
    var value: Value

    init(id: UUID = UUID(), time: Double, value: Value) {
        self.id = id
        self.time = max(0, time)
        self.value = value
    }
}

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
            return left.value + ((right.value - left.value) * progress)
        }

        return baseValue
    }
}

struct ClipSource: Identifiable, Codable, Equatable {
    var id: UUID
    var url: URL
    var mediaType: ClipMediaType
    var originalDuration: Double
    var naturalSize: CGSizeValue?

    init(
        id: UUID = UUID(),
        url: URL,
        mediaType: ClipMediaType,
        originalDuration: Double,
        naturalSize: CGSizeValue? = nil
    ) {
        self.id = id
        self.url = url
        self.mediaType = mediaType
        self.originalDuration = max(0, originalDuration)
        self.naturalSize = naturalSize
    }
}

struct CGSizeValue: Codable, Equatable {
    var width: Double
    var height: Double

    var cgSize: CGSize { CGSize(width: width, height: height) }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }
}

struct TimelineClip: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var source: ClipSource
    var timelineStart: Double
    var sourceRange: TimeRangeValue
    var transform: ClipTransform
    var adjustments: AdjustmentSettings
    var effectStack: EffectStack
    var volume: Double

    var timelineEnd: Double { timelineStart + sourceRange.duration }
    var mediaType: ClipMediaType { source.mediaType }

    init(
        id: UUID = UUID(),
        name: String,
        source: ClipSource,
        timelineStart: Double,
        sourceRange: TimeRangeValue,
        transform: ClipTransform = ClipTransform(),
        adjustments: AdjustmentSettings = AdjustmentSettings(),
        effectStack: EffectStack = EffectStack(),
        volume: Double = 1
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.timelineStart = max(0, timelineStart)
        self.sourceRange = sourceRange
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.volume = min(max(volume, 0), 2)
    }
}

struct TimelineTrack: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var kind: TrackKind
    var clips: [TimelineClip]
    var isMuted: Bool
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind,
        clips: [TimelineClip] = [],
        isMuted: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.clips = clips
        self.isMuted = isMuted
        self.isLocked = isLocked
    }
}

struct ClipTransform: Codable, Equatable {
    var positionX: AnimatableProperty<Double>
    var positionY: AnimatableProperty<Double>
    var scale: AnimatableProperty<Double>
    var rotationDegrees: AnimatableProperty<Double>
    var opacity: AnimatableProperty<Double>

    init(
        positionX: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        positionY: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        scale: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        rotationDegrees: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        opacity: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1)
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
    }
}

struct AdjustmentSettings: Codable, Equatable {
    var brightness: AnimatableProperty<Double>
    var contrast: AnimatableProperty<Double>
    var saturation: AnimatableProperty<Double>
    var exposure: AnimatableProperty<Double>

    init(
        brightness: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        contrast: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        saturation: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        exposure: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0)
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
    }
}

enum ClipEffectKind: String, Codable, CaseIterable, Identifiable {
    case sepia = "Sepia"
    case noir = "Noir"
    case chrome = "Chrome"
    case blur = "Blur"
    case vignette = "Vignette"

    var id: String { rawValue }
}

struct ClipEffect: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ClipEffectKind
    var isEnabled: Bool
    var intensity: AnimatableProperty<Double>

    init(
        id: UUID = UUID(),
        kind: ClipEffectKind,
        isEnabled: Bool = true,
        intensity: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0.6)
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.intensity = intensity
    }
}

struct EffectStack: Codable, Equatable {
    var effects: [ClipEffect]

    init(effects: [ClipEffect] = []) {
        self.effects = effects
    }
}

struct RenderSettings: Codable, Equatable {
    var width: Int
    var height: Int
    var frameRate: Int32

    var size: CGSize { CGSize(width: width, height: height) }

    init(width: Int = 1080, height: Int = 1920, frameRate: Int32 = 30) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    init(size: CGSize, frameRate: Int32 = 30) {
        let safeWidth = max(Int(size.width.rounded()), 1)
        let safeHeight = max(Int(size.height.rounded()), 1)
        self.width = safeWidth
        self.height = safeHeight
        self.frameRate = frameRate
    }
}

struct EditorProject: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 2

    var id: UUID
    var schemaVersion: Int
    var title: String
    var renderSettings: RenderSettings
    var tracks: [TimelineTrack]
    var createdAt: Date
    var updatedAt: Date

    var duration: Double {
        tracks
            .flatMap(\.clips)
            .map(\.timelineEnd)
            .max() ?? 0
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = EditorProject.currentSchemaVersion,
        title: String,
        renderSettings: RenderSettings = RenderSettings(),
        tracks: [TimelineTrack] = EditorProject.defaultTracks(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.renderSettings = renderSettings
        self.tracks = tracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func empty(title: String) -> EditorProject {
        EditorProject(title: title)
    }

    static func defaultTracks() -> [TimelineTrack] {
        [
            TimelineTrack(name: "Layer 1", kind: .visual)
        ]
    }

    static func migratingLegacy(title: String, clips: [Clip], keyframes: [Keyframe<Double>], selectedEffect: VideoEffect, effectIntensity: Double) -> EditorProject {
        var timelineStart = 0.0
        var visualClips: [TimelineClip] = []
        var audioClips: [TimelineClip] = []

        for legacyClip in clips {
            let duration = max(legacyClip.endTime - legacyClip.startTime, 0)
            let mediaType: ClipMediaType = legacyClip.mediaType == .audio ? .audio : .video
            let source = ClipSource(
                url: legacyClip.sourceURL,
                mediaType: mediaType,
                originalDuration: legacyClip.endTime,
                naturalSize: nil
            )

            var stack = EffectStack()
            if mediaType != .audio, let kind = selectedEffect.effectKind {
                let localKeyframes = keyframes
                    .filter { $0.time >= timelineStart && $0.time <= timelineStart + duration }
                    .map { Keyframe<Double>(id: $0.id, time: $0.time - timelineStart, value: $0.value) }
                stack.effects = [
                    ClipEffect(kind: kind, intensity: AnimatableProperty(baseValue: effectIntensity, keyframes: localKeyframes))
                ]
            }

            let clip = TimelineClip(
                name: legacyClip.sourceURL.deletingPathExtension().lastPathComponent,
                source: source,
                timelineStart: mediaType == .audio ? 0 : timelineStart,
                sourceRange: TimeRangeValue(start: legacyClip.startTime, duration: duration),
                effectStack: stack
            )

            if mediaType == .audio {
                audioClips.append(clip)
            } else {
                visualClips.append(clip)
                timelineStart += duration
            }
        }

        var tracks = [TimelineTrack(name: "Layer 1", kind: .visual, clips: visualClips)]
        if !audioClips.isEmpty {
            tracks.append(TimelineTrack(name: "Audio 1", kind: .audio, clips: audioClips))
        }

        return EditorProject(title: title, tracks: tracks)
    }
}
