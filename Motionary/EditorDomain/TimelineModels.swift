// Source media, clips, and track entities used by the editor timeline.

import CoreGraphics
import Foundation

/// Project-local media reference and source metadata.
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

/// Codable bridge for persisted Core Graphics sizes.
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

/// Timeline placement and editable state for one source media item.
struct TimelineClip: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var source: ClipSource
    var timelineStart: Double
    var sourceRange: TimeRangeValue
    var transform: ClipTransform
    var adjustments: AdjustmentSettings
    var effectStack: EffectStack
    var volume: AnimatableProperty<Double>

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
        volume: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1)
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.timelineStart = max(0, timelineStart)
        self.sourceRange = sourceRange
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.volume = volume.clamped(to: 0...2)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case source
        case timelineStart
        case sourceRange
        case transform
        case adjustments
        case effectStack
        case volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(ClipSource.self, forKey: .source)
        timelineStart = max(try container.decode(Double.self, forKey: .timelineStart), 0)
        sourceRange = try container.decode(TimeRangeValue.self, forKey: .sourceRange)
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        adjustments =
            try container.decodeIfPresent(AdjustmentSettings.self, forKey: .adjustments)
            ?? AdjustmentSettings()
        effectStack =
            try container.decodeIfPresent(EffectStack.self, forKey: .effectStack)
            ?? EffectStack()

        if let property = try? container.decode(AnimatableProperty<Double>.self, forKey: .volume) {
            volume = property.clamped(to: 0...2)
        } else {
            let legacyVolume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
            volume = AnimatableProperty(baseValue: min(max(legacyVolume, 0), 2))
        }
    }
}

/// Ordered collection of compatible clips in the editor timeline.
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
