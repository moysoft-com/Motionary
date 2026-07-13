// Typed timeline items and legacy clip bridging.

import Foundation

struct MediaTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var mediaID: MediaID
    var mediaType: ClipMediaType
    var timelineStart: Double
    var sourceRange: TimeRangeValue
    var visuals: TimelineItemVisuals
    var speedMap: SpeedMap
    var transitionOut: TimelineTransition?
    var linkGroupID: UUID?

    var timelineEnd: Double {
        timelineStart + timelineDuration
    }

    var timelineDuration: Double {
        speedMap.timelineDuration(sourceDuration: sourceRange.duration)
    }

    init(
        id: UUID = UUID(),
        name: String,
        mediaID: MediaID,
        mediaType: ClipMediaType,
        timelineStart: Double,
        sourceRange: TimeRangeValue,
        visuals: TimelineItemVisuals = TimelineItemVisuals(),
        speedMap: SpeedMap = .constant,
        transitionOut: TimelineTransition? = nil,
        linkGroupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.mediaID = mediaID
        self.mediaType = mediaType
        self.timelineStart = max(0, timelineStart)
        self.sourceRange = sourceRange
        self.visuals = visuals
        self.speedMap = speedMap
        self.transitionOut = transitionOut
        self.linkGroupID = linkGroupID
    }
}

struct ShapeTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var mediaID: MediaID
    var shape: ClipShape
    var timelineStart: Double
    var sourceRange: TimeRangeValue
    var visuals: TimelineItemVisuals
    var transitionOut: TimelineTransition?

    var timelineEnd: Double { timelineStart + sourceRange.duration }

    init(
        id: UUID = UUID(),
        name: String,
        mediaID: MediaID,
        shape: ClipShape,
        timelineStart: Double,
        sourceRange: TimeRangeValue,
        visuals: TimelineItemVisuals = TimelineItemVisuals(),
        transitionOut: TimelineTransition? = nil
    ) {
        self.id = id
        self.name = name
        self.mediaID = mediaID
        self.shape = shape
        self.timelineStart = max(0, timelineStart)
        self.sourceRange = sourceRange
        self.visuals = visuals
        self.transitionOut = transitionOut
    }
}

struct TextTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var text: String
    var style: TextStyle
    var timelineStart: Double
    var duration: Double
    var visuals: TimelineItemVisuals

    var timelineEnd: Double { timelineStart + duration }
    var sourceRange: TimeRangeValue { TimeRangeValue(start: 0, duration: duration) }

    init(
        id: UUID = UUID(),
        name: String = "Text",
        text: String,
        style: TextStyle = TextStyle(),
        timelineStart: Double,
        duration: Double,
        visuals: TimelineItemVisuals = TimelineItemVisuals()
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.style = style
        self.timelineStart = max(0, timelineStart)
        self.duration = max(duration, 0.1)
        self.visuals = visuals
    }
}

struct CaptionTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var style: TextStyle
    var timelineStart: Double
    var duration: Double

    var timelineEnd: Double { timelineStart + duration }

    init(
        id: UUID = UUID(),
        text: String,
        style: TextStyle = TextStyle(fontSize: 32),
        timelineStart: Double,
        duration: Double
    ) {
        self.id = id
        self.text = text
        self.style = style
        self.timelineStart = max(0, timelineStart)
        self.duration = max(duration, 0.1)
    }
}

struct AdjustmentTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var timelineStart: Double
    var duration: Double
    var visuals: TimelineItemVisuals

    var timelineEnd: Double { timelineStart + duration }

    init(
        id: UUID = UUID(),
        name: String = "Adjustment",
        timelineStart: Double,
        duration: Double,
        visuals: TimelineItemVisuals = TimelineItemVisuals()
    ) {
        self.id = id
        self.name = name
        self.timelineStart = max(0, timelineStart)
        self.duration = max(duration, 0.1)
        self.visuals = visuals
    }
}

struct CompoundTimelineItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sequenceID: UUID
    var timelineStart: Double
    var duration: Double
    var visuals: TimelineItemVisuals

    var timelineEnd: Double { timelineStart + duration }

    init(
        id: UUID = UUID(),
        name: String,
        sequenceID: UUID,
        timelineStart: Double,
        duration: Double,
        visuals: TimelineItemVisuals = TimelineItemVisuals()
    ) {
        self.id = id
        self.name = name
        self.sequenceID = sequenceID
        self.timelineStart = max(0, timelineStart)
        self.duration = max(duration, 0.1)
        self.visuals = visuals
    }
}

enum TimelineItem: Identifiable, Codable, Equatable, Sendable {
    case media(MediaTimelineItem)
    case shape(ShapeTimelineItem)
    case text(TextTimelineItem)
    case caption(CaptionTimelineItem)
    case adjustment(AdjustmentTimelineItem)
    case compound(CompoundTimelineItem)

    var id: UUID {
        switch self {
        case .media(let item): item.id
        case .shape(let item): item.id
        case .text(let item): item.id
        case .caption(let item): item.id
        case .adjustment(let item): item.id
        case .compound(let item): item.id
        }
    }

    var kind: TimelineItemKind {
        switch self {
        case .media: .media
        case .shape: .shape
        case .text: .text
        case .caption: .caption
        case .adjustment: .adjustment
        case .compound: .compound
        }
    }

    var timelineStart: Double {
        get {
            switch self {
            case .media(let item): item.timelineStart
            case .shape(let item): item.timelineStart
            case .text(let item): item.timelineStart
            case .caption(let item): item.timelineStart
            case .adjustment(let item): item.timelineStart
            case .compound(let item): item.timelineStart
            }
        }
        set {
            switch self {
            case .media(var item):
                item.timelineStart = newValue
                self = .media(item)
            case .shape(var item):
                item.timelineStart = newValue
                self = .shape(item)
            case .text(var item):
                item.timelineStart = newValue
                self = .text(item)
            case .caption(var item):
                item.timelineStart = newValue
                self = .caption(item)
            case .adjustment(var item):
                item.timelineStart = newValue
                self = .adjustment(item)
            case .compound(var item):
                item.timelineStart = newValue
                self = .compound(item)
            }
        }
    }

    var timelineEnd: Double {
        switch self {
        case .media(let item): item.timelineEnd
        case .shape(let item): item.timelineEnd
        case .text(let item): item.timelineEnd
        case .caption(let item): item.timelineEnd
        case .adjustment(let item): item.timelineEnd
        case .compound(let item): item.timelineEnd
        }
    }

    var requiredTrackKind: TrackKind {
        switch self {
        case .media(let item):
            item.mediaType == .audio ? .audio : .visual
        case .shape:
            .shape
        case .text, .caption, .adjustment, .compound:
            .visual
        }
    }

    var placementDuration: Double {
        switch self {
        case .media(let item): item.timelineDuration
        case .shape(let item): item.sourceRange.duration
        case .text(let item): item.duration
        case .caption(let item): item.duration
        case .adjustment(let item): item.duration
        case .compound(let item): item.duration
        }
    }

    static func fromLegacyClip(_ clip: TimelineClip) -> TimelineItem {
        let visuals = TimelineItemVisuals(
            transform: clip.transform,
            adjustments: clip.adjustments,
            effectStack: clip.effectStack,
            volume: clip.volume
        )
        if let shape = clip.shape {
            return .shape(
                ShapeTimelineItem(
                    id: clip.id,
                    name: clip.name,
                    mediaID: clip.mediaID,
                    shape: shape,
                    timelineStart: clip.timelineStart,
                    sourceRange: clip.sourceRange,
                    visuals: visuals
                )
            )
        }
        return .media(
            MediaTimelineItem(
                id: clip.id,
                name: clip.name,
                mediaID: clip.mediaID,
                mediaType: clip.mediaType,
                timelineStart: clip.timelineStart,
                sourceRange: clip.sourceRange,
                visuals: visuals
            )
        )
    }

    func legacyClip() -> TimelineClip? {
        switch self {
        case .media(let item):
            TimelineClip(
                id: item.id,
                name: item.name,
                mediaID: item.mediaID,
                mediaType: item.mediaType,
                timelineStart: item.timelineStart,
                sourceRange: item.sourceRange,
                transform: item.visuals.transform,
                adjustments: item.visuals.adjustments,
                effectStack: item.visuals.effectStack,
                volume: item.visuals.volume
            )
        case .shape(let item):
            TimelineClip(
                id: item.id,
                name: item.name,
                mediaID: item.mediaID,
                mediaType: .video,
                timelineStart: item.timelineStart,
                sourceRange: item.sourceRange,
                transform: item.visuals.transform,
                adjustments: item.visuals.adjustments,
                effectStack: item.visuals.effectStack,
                volume: item.visuals.volume,
                shape: item.shape
            )
        case .text, .caption, .adjustment, .compound:
            nil
        }
    }
}

extension TimelineItem {
    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(TimelineItemKind.self, forKey: .kind)
        switch kind {
        case .media:
            self = .media(try container.decode(MediaTimelineItem.self, forKey: .payload))
        case .shape:
            self = .shape(try container.decode(ShapeTimelineItem.self, forKey: .payload))
        case .text:
            self = .text(try container.decode(TextTimelineItem.self, forKey: .payload))
        case .caption:
            self = .caption(try container.decode(CaptionTimelineItem.self, forKey: .payload))
        case .adjustment:
            self = .adjustment(try container.decode(AdjustmentTimelineItem.self, forKey: .payload))
        case .compound:
            self = .compound(try container.decode(CompoundTimelineItem.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .media(let item):
            try container.encode(item, forKey: .payload)
        case .shape(let item):
            try container.encode(item, forKey: .payload)
        case .text(let item):
            try container.encode(item, forKey: .payload)
        case .caption(let item):
            try container.encode(item, forKey: .payload)
        case .adjustment(let item):
            try container.encode(item, forKey: .payload)
        case .compound(let item):
            try container.encode(item, forKey: .payload)
        }
    }
}
