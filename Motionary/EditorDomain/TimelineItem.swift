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
    var layout: TextLayout
    var animations: TextAnimationSet
    var propertyAnimations: TextPropertyAnimations
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
        layout: TextLayout = TextLayout(),
        animations: TextAnimationSet = TextAnimationSet(),
        propertyAnimations: TextPropertyAnimations? = nil,
        timelineStart: Double,
        duration: Double,
        visuals: TimelineItemVisuals = TimelineItemVisuals()
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.style = style
        self.layout = layout
        self.animations = animations.normalized(for: max(duration, 0.1))
        self.propertyAnimations = propertyAnimations
            ?? TextPropertyAnimations(style: style, layout: layout)
        self.timelineStart = max(0, timelineStart)
        self.duration = max(duration, 0.1)
        self.visuals = visuals
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case text
        case style
        case layout
        case animations
        case propertyAnimations
        case timelineStart
        case duration
        case visuals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let style = try container.decodeIfPresent(TextStyle.self, forKey: .style) ?? TextStyle()
        let layout = try container.decodeIfPresent(TextLayout.self, forKey: .layout) ?? TextLayout()
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Text",
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            style: style,
            layout: layout,
            animations: try container.decodeIfPresent(TextAnimationSet.self, forKey: .animations)
                ?? TextAnimationSet(),
            propertyAnimations: try container.decodeIfPresent(
                TextPropertyAnimations.self,
                forKey: .propertyAnimations
            ) ?? TextPropertyAnimations(style: style, layout: layout),
            timelineStart: try container.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            duration: try container.decodeIfPresent(Double.self, forKey: .duration) ?? 5,
            visuals: try container.decodeIfPresent(TimelineItemVisuals.self, forKey: .visuals)
                ?? TimelineItemVisuals()
        )
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
        case .text:
            .text
        case .caption, .adjustment, .compound:
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
    var sourceRange: TimeRangeValue {
        switch self {
        case .media(let item): item.sourceRange
        case .shape(let item): item.sourceRange
        case .text(let item): item.sourceRange
        case .caption(let item): TimeRangeValue(start: 0, duration: item.duration)
        case .adjustment(let item): TimeRangeValue(start: 0, duration: item.duration)
        case .compound(let item): TimeRangeValue(start: 0, duration: item.duration)
        }
    }

    var mediaType: ClipMediaType? {
        guard case .media(let item) = self else { return nil }
        return item.mediaType
    }

    func duplicated(startingAt timelineStart: Double) -> TimelineItem {
        var copy = self
        copy.assignNewIdentityAndCopyName()
        copy.timelineStart = timelineStart
        return copy
    }

    func mergingLegacyClip(_ clip: TimelineClip) -> TimelineItem {
        let replacement = TimelineItem.fromLegacyClip(clip)
        switch (self, replacement) {
        case (.media(let previous), .media(var updated)):
            updated.speedMap = previous.speedMap
            updated.transitionOut = previous.transitionOut
            updated.linkGroupID = previous.linkGroupID
            updated.visuals.blendMode = previous.visuals.blendMode
            updated.visuals.mask = previous.visuals.mask
            return .media(updated)
        case (.shape(let previous), .shape(var updated)):
            updated.transitionOut = previous.transitionOut
            updated.visuals.blendMode = previous.visuals.blendMode
            updated.visuals.mask = previous.visuals.mask
            return .shape(updated)
        default:
            return replacement
        }
    }

    func split(at offset: Double) -> (left: TimelineItem, right: TimelineItem)? {
        guard offset > 0.08, offset < placementDuration - 0.08 else { return nil }

        switch self {
        case .media(var item):
            let sourceOffset = item.speedMap.sourceTime(
                at: offset,
                sourceDuration: item.sourceRange.duration
            )
            guard sourceOffset > 0.08, sourceOffset < item.sourceRange.duration - 0.08 else { return nil }
            let splitVisuals = item.visuals.splittingAnimations(at: offset)
            let transition = item.transitionOut
            item.sourceRange = TimeRangeValue(start: item.sourceRange.start, duration: sourceOffset)
            item.visuals = splitVisuals.left
            item.transitionOut = nil
            var second = item
            second.id = UUID()
            second.name += " split"
            second.timelineStart = timelineStart + offset
            second.sourceRange = TimeRangeValue(
                start: sourceRange.start + sourceOffset,
                duration: sourceRange.duration - sourceOffset
            )
            second.visuals = splitVisuals.right
            second.transitionOut = transition
            return (.media(item), .media(second))

        case .shape(var item):
            let splitVisuals = item.visuals.splittingAnimations(at: offset)
            let transition = item.transitionOut
            item.sourceRange = TimeRangeValue(start: item.sourceRange.start, duration: offset)
            item.visuals = splitVisuals.left
            item.transitionOut = nil
            var second = item
            second.id = UUID()
            second.name += " split"
            second.timelineStart = timelineStart + offset
            second.sourceRange = TimeRangeValue(
                start: sourceRange.start + offset,
                duration: sourceRange.duration - offset
            )
            second.visuals = splitVisuals.right
            second.transitionOut = transition
            return (.shape(item), .shape(second))

        case .text(var item):
            let originalDuration = item.duration
            let splitVisuals = item.visuals.splittingAnimations(at: offset)
            let splitTextAnimations = item.animations.splitting(
                at: offset,
                duration: originalDuration
            )
            let splitPropertyAnimations = item.propertyAnimations.splitting(at: offset)
            item.duration = offset
            item.visuals = splitVisuals.left
            item.animations = splitTextAnimations.left
            item.propertyAnimations = splitPropertyAnimations.left
            var second = item
            second.id = UUID()
            second.name += " split"
            second.timelineStart = timelineStart + offset
            second.duration = originalDuration - offset
            second.visuals = splitVisuals.right
            second.animations = splitTextAnimations.right
            second.propertyAnimations = splitPropertyAnimations.right
            return (.text(item), .text(second))

        case .caption(var item):
            let originalDuration = item.duration
            item.duration = offset
            var second = item
            second.id = UUID()
            second.timelineStart = timelineStart + offset
            second.duration = originalDuration - offset
            return (.caption(item), .caption(second))

        case .adjustment(var item):
            let originalDuration = item.duration
            item.duration = offset
            var second = item
            second.id = UUID()
            second.name += " split"
            second.timelineStart = timelineStart + offset
            second.duration = originalDuration - offset
            return (.adjustment(item), .adjustment(second))

        case .compound(var item):
            let originalDuration = item.duration
            item.duration = offset
            var second = item
            second.id = UUID()
            second.name += " split"
            second.timelineStart = timelineStart + offset
            second.duration = originalDuration - offset
            return (.compound(item), .compound(second))
        }
    }

    func trimmingStart(by delta: Double) -> TimelineItem {
        var result = self
        switch result {
        case .media(var item):
            let oldSourceDuration = item.sourceRange.duration
            let oldTimelineDuration = item.timelineDuration
            let sourceDelta = delta >= 0
                ? item.speedMap.sourceTime(at: delta, sourceDuration: oldSourceDuration)
                : delta * item.speedMap.speed(at: 0)
            item.timelineStart += delta
            item.sourceRange = TimeRangeValue(
                start: item.sourceRange.start + sourceDelta,
                duration: oldSourceDuration - sourceDelta
            )
            item.visuals.trimAnimationsAtStart(by: delta, oldDuration: oldTimelineDuration)
            result = .media(item)
        case .shape(var item):
            let oldDuration = item.sourceRange.duration
            item.timelineStart += delta
            item.sourceRange = TimeRangeValue(
                start: item.sourceRange.start + delta,
                duration: oldDuration - delta
            )
            item.visuals.trimAnimationsAtStart(by: delta, oldDuration: oldDuration)
            result = .shape(item)
        case .text(var item):
            let oldDuration = item.duration
            item.timelineStart += delta
            item.duration = max(item.duration - delta, 0.1)
            item.visuals.trimAnimationsAtStart(by: delta, oldDuration: oldDuration)
            item.animations = item.animations.trimmingStart(
                by: delta,
                oldDuration: oldDuration
            ).normalized(for: item.duration)
            item.propertyAnimations = item.propertyAnimations.trimmingStart(
                by: delta,
                oldDuration: oldDuration
            )
            result = .text(item)
        case .caption(var item):
            item.timelineStart += delta
            item.duration -= delta
            result = .caption(item)
        case .adjustment(var item):
            item.timelineStart += delta
            item.duration -= delta
            result = .adjustment(item)
        case .compound(var item):
            item.timelineStart += delta
            item.duration -= delta
            result = .compound(item)
        }
        return result
    }

    func trimmingEnd(by delta: Double) -> TimelineItem {
        var result = self
        switch result {
        case .media(var item):
            let oldSourceDuration = item.sourceRange.duration
            let oldTimelineDuration = item.timelineDuration
            let newTimelineDuration = max(oldTimelineDuration + delta, 0.1)
            let newSourceDuration: Double
            if newTimelineDuration <= oldTimelineDuration {
                newSourceDuration = item.speedMap.sourceTime(
                    at: newTimelineDuration,
                    sourceDuration: oldSourceDuration
                )
            } else {
                newSourceDuration = oldSourceDuration
                    + (newTimelineDuration - oldTimelineDuration) * item.speedMap.speed(at: oldSourceDuration)
            }
            item.sourceRange = TimeRangeValue(
                start: item.sourceRange.start,
                duration: newSourceDuration
            )
            item.visuals.trimAnimationsAtEnd(
                newDuration: newTimelineDuration,
                oldDuration: oldTimelineDuration
            )
            result = .media(item)
        case .shape(var item):
            let oldDuration = item.sourceRange.duration
            item.sourceRange = TimeRangeValue(
                start: item.sourceRange.start,
                duration: oldDuration + delta
            )
            item.visuals.trimAnimationsAtEnd(newDuration: item.sourceRange.duration, oldDuration: oldDuration)
            result = .shape(item)
        case .text(var item):
            let oldDuration = item.duration
            item.duration = max(item.duration + delta, 0.1)
            item.visuals.trimAnimationsAtEnd(newDuration: item.duration, oldDuration: oldDuration)
            item.animations = item.animations.trimmingEnd(newDuration: item.duration)
            item.propertyAnimations = item.propertyAnimations.trimmingEnd(
                newDuration: item.duration,
                oldDuration: oldDuration
            )
            result = .text(item)
        case .caption(var item):
            item.duration += delta
            result = .caption(item)
        case .adjustment(var item):
            item.duration += delta
            result = .adjustment(item)
        case .compound(var item):
            item.duration += delta
            result = .compound(item)
        }
        return result
    }

    private mutating func assignNewIdentityAndCopyName() {
        switch self {
        case .media(var item):
            item.id = UUID()
            item.name += " copy"
            self = .media(item)
        case .shape(var item):
            item.id = UUID()
            item.name += " copy"
            self = .shape(item)
        case .text(var item):
            item.id = UUID()
            item.name += " copy"
            self = .text(item)
        case .caption(var item):
            item.id = UUID()
            self = .caption(item)
        case .adjustment(var item):
            item.id = UUID()
            item.name += " copy"
            self = .adjustment(item)
        case .compound(var item):
            item.id = UUID()
            item.name += " copy"
            self = .compound(item)
        }
    }

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
