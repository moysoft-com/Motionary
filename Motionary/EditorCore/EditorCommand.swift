import Foundation

struct EditorInvalidation: OptionSet, Sendable {
    let rawValue: Int

    static let userInterface = EditorInvalidation(rawValue: 1 << 0)
    static let timelineLayout = EditorInvalidation(rawValue: 1 << 1)
    static let previewFrame = EditorInvalidation(rawValue: 1 << 2)
    static let compositionTopology = EditorInvalidation(rawValue: 1 << 3)
    static let persistence = EditorInvalidation(rawValue: 1 << 4)
    static let audioMix = EditorInvalidation(rawValue: 1 << 5)
}

protocol EditorCommand {
    var invalidation: EditorInvalidation { get }
    func apply(to project: inout EditorProject)
    func undo(on project: inout EditorProject)
}

struct AnyEditorCommand: EditorCommand {
    let invalidation: EditorInvalidation
    private let applyAction: (inout EditorProject) -> Void
    private let undoAction: (inout EditorProject) -> Void

    init<C: EditorCommand>(_ command: C) {
        invalidation = command.invalidation
        applyAction = command.apply
        undoAction = command.undo
    }

    func apply(to project: inout EditorProject) {
        applyAction(&project)
    }

    func undo(on project: inout EditorProject) {
        undoAction(&project)
    }
}

struct ReplaceClipCommand: EditorCommand {
    let before: TimelineItem
    let after: TimelineItem
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.replaceItem(id: after.id, with: after)
    }

    func undo(on project: inout EditorProject) {
        project.replaceItem(id: before.id, with: before)
    }
}

struct ProjectDeltaCommand: EditorCommand {
    let delta: ProjectDelta
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        delta.apply(to: &project, forward: true)
    }

    func undo(on project: inout EditorProject) {
        delta.apply(to: &project, forward: false)
    }
}

struct ProjectDelta {
    struct ValueChange<Value> {
        let before: Value
        let after: Value
    }

    struct TrackChange {
        let id: UUID
        let before: TimelineTrack?
        let after: TimelineTrack?
    }

    struct MediaChange {
        let id: MediaID
        let before: MediaAsset?
        let after: MediaAsset?
    }

    let title: ValueChange<String>?
    let renderSettings: ValueChange<RenderSettings>?
    let trackOrder: ValueChange<[UUID]>?
    let tracks: [TrackChange]
    let media: [MediaChange]

    init(from previous: EditorProject, to current: EditorProject) {
        title = previous.title == current.title
            ? nil : ValueChange(before: previous.title, after: current.title)
        renderSettings = previous.renderSettings == current.renderSettings
            ? nil : ValueChange(before: previous.renderSettings, after: current.renderSettings)

        let oldTracks = Dictionary(uniqueKeysWithValues: previous.tracks.map { ($0.id, $0) })
        let newTracks = Dictionary(uniqueKeysWithValues: current.tracks.map { ($0.id, $0) })
        let oldOrder = previous.tracks.map(\.id)
        let newOrder = current.tracks.map(\.id)
        trackOrder = oldOrder == newOrder ? nil : ValueChange(before: oldOrder, after: newOrder)
        tracks = Set(oldTracks.keys).union(newTracks.keys).compactMap { id in
            let before = oldTracks[id]
            let after = newTracks[id]
            return before == after ? nil : TrackChange(id: id, before: before, after: after)
        }

        media = Set(previous.mediaLibrary.keys).union(current.mediaLibrary.keys).compactMap { id in
            let before = previous.mediaLibrary[id]
            let after = current.mediaLibrary[id]
            return before == after ? nil : MediaChange(id: id, before: before, after: after)
        }
    }

    func apply(to project: inout EditorProject, forward: Bool) {
        if let title {
            project.title = forward ? title.after : title.before
        }
        if let renderSettings {
            project.renderSettings = forward ? renderSettings.after : renderSettings.before
        }

        var tracksByID = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0) })
        for change in tracks {
            tracksByID[change.id] = forward ? change.after : change.before
        }
        let order = trackOrder.map { forward ? $0.after : $0.before }
            ?? project.tracks.map(\.id)
        project.tracks = order.compactMap { tracksByID[$0] }

        for change in media {
            project.mediaLibrary[change.id] = forward ? change.after : change.before
        }
        project.synchronizeMediaLibrary()
    }
}

extension EditorProject {
    func renderInvalidation(comparedTo previous: EditorProject) -> EditorInvalidation {
        guard renderTopologySignature == previous.renderTopologySignature else {
            return [.previewFrame, .compositionTopology, .audioMix]
        }

        var invalidation: EditorInvalidation = []
        if renderVisualSignature != previous.renderVisualSignature {
            invalidation.insert(.previewFrame)
        }
        if renderSettings.frameRate != previous.renderSettings.frameRate {
            invalidation.insert(.audioMix)
        }
        if renderAudioSignature != previous.renderAudioSignature {
            invalidation.insert(.audioMix)
        }
        return invalidation
    }

    mutating func replaceClip(id: UUID, with replacement: TimelineClip) {
        replaceLegacyClip(id: id, with: replacement)
    }

    mutating func replaceLegacyClip(id: UUID, with replacement: TimelineClip) {
        guard let location = itemLocation(id: id) else { return }
        tracks[location.track].replaceLegacyClip(id: id, with: replacement)
        synchronizeMediaLibrary()
    }

    func historyCommand(
        from previous: EditorProject,
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        if renderSettings == previous.renderSettings,
            title == previous.title,
            trackStructureMatches(previous),
            let change = singleItemChange(from: previous)
        {
            return AnyEditorCommand(
                ReplaceClipCommand(
                    before: change.before,
                    after: change.after,
                    invalidation: invalidation
                )
            )
        }

        return AnyEditorCommand(
            ProjectDeltaCommand(
                delta: ProjectDelta(from: previous, to: self),
                invalidation: invalidation
            )
        )
    }

    static func renderInvalidation(before: TimelineClip, after: TimelineClip) -> EditorInvalidation {
        if before.mediaID != after.mediaID
            || before.mediaType != after.mediaType
            || before.timelineStart != after.timelineStart
            || before.sourceRange != after.sourceRange
            || (before.shape == nil) != (after.shape == nil)
        {
            return [.previewFrame, .compositionTopology, .audioMix]
        }

        var invalidation: EditorInvalidation = []
        if before.transform != after.transform
            || before.adjustments != after.adjustments
            || before.effectStack != after.effectStack
            || before.shape != after.shape
        {
            invalidation.insert(.previewFrame)
        }
        if before.volume != after.volume {
            invalidation.insert(.audioMix)
        }
        return invalidation
    }

    private func trackStructureMatches(_ previous: EditorProject) -> Bool {
        guard tracks.count == previous.tracks.count else { return false }
        return zip(tracks, previous.tracks).allSatisfy { current, old in
            current.id == old.id
                && current.name == old.name
                && current.kind == old.kind
                && current.isMuted == old.isMuted
                && current.isLocked == old.isLocked
                && current.items.map(\.id) == old.items.map(\.id)
        }
    }

    private func singleItemChange(from previous: EditorProject) -> (before: TimelineItem, after: TimelineItem)? {
        let oldItems = Dictionary(uniqueKeysWithValues: previous.tracks.flatMap(\.items).map { ($0.id, $0) })
        let newItems = Dictionary(uniqueKeysWithValues: tracks.flatMap(\.items).map { ($0.id, $0) })
        guard oldItems.keys == newItems.keys else { return nil }

        let changedIDs = oldItems.keys.filter { oldItems[$0] != newItems[$0] }
        guard changedIDs.count == 1,
            let id = changedIDs.first,
            let before = oldItems[id],
            let after = newItems[id]
        else { return nil }
        return (before, after)
    }

    private var renderTopologySignature: RenderTopologySignature {
        RenderTopologySignature(
            tracks: tracks.map { track in
                RenderTrackTopology(
                    id: track.id,
                    kind: track.kind,
                    isMuted: track.isMuted,
                    items: track.items.map { item in
                        let mediaID: MediaID?
                        let mediaType: ClipMediaType?
                        let speedSignature: UInt64
                        switch item {
                        case .media(let media):
                            mediaID = media.mediaID
                            mediaType = media.mediaType
                            speedSignature = media.speedMap.topologySignature
                        case .shape(let shape):
                            mediaID = shape.mediaID
                            mediaType = .video
                            speedSignature = 0
                        default:
                            mediaID = nil
                            mediaType = nil
                            speedSignature = 0
                        }
                        return RenderItemTopology(
                            id: item.id,
                            kind: item.kind,
                            mediaID: mediaID,
                            mediaType: mediaType,
                            timelineStart: item.timelineStart,
                            placementDuration: item.placementDuration,
                            sourceRange: item.sourceRange,
                            hasShape: {
                                if case .shape = item { return true }
                                return false
                            }(),
                            speedSignature: speedSignature,
                            usesBackgroundRemoval: item.editableVisuals?.backgroundRemoval != nil,
                            backgroundRemovalArtifact: item.editableVisuals?.backgroundRemoval == nil
                                ? nil
                                : mediaID.flatMap { mediaLibrary[$0]?.backgroundRemovalArtifact }
                        )
                    }
                )
            }
        )
    }

    private var renderVisualSignature: RenderVisualSignature {
        RenderVisualSignature(
            canvasWidth: renderSettings.width,
            canvasHeight: renderSettings.height,
            frameRate: renderSettings.frameRate,
            backgroundColor: renderSettings.backgroundColor,
            items: tracks.flatMap(\.items).compactMap { item in
                switch item {
                case .media(let media):
                    RenderItemVisual(
                        id: media.id,
                        transform: media.visuals.transform,
                        adjustments: media.visuals.adjustments,
                        effects: media.visuals.effectStack,
                        mask: media.visuals.mask,
                        backgroundRemoval: media.visuals.backgroundRemoval,
                        blendMode: media.visuals.blendMode,
                        blendIntensity: media.visuals.blendIntensity,
                        shape: nil,
                        text: nil
                    )
                case .shape(let shape):
                    RenderItemVisual(
                        id: shape.id,
                        transform: shape.visuals.transform,
                        adjustments: shape.visuals.adjustments,
                        effects: shape.visuals.effectStack,
                        mask: shape.visuals.mask,
                        backgroundRemoval: nil,
                        blendMode: shape.visuals.blendMode,
                        blendIntensity: shape.visuals.blendIntensity,
                        shape: shape.shape,
                        text: nil
                    )
                case .text(let text):
                    RenderItemVisual(
                        id: text.id,
                        transform: text.visuals.transform,
                        adjustments: text.visuals.adjustments,
                        effects: text.visuals.effectStack,
                        mask: text.visuals.mask,
                        backgroundRemoval: nil,
                        blendMode: text.visuals.blendMode,
                        blendIntensity: text.visuals.blendIntensity,
                        shape: nil,
                        text: text
                    )
                case .caption, .adjustment, .compound:
                    nil
                }
            }
        )
    }

    private var renderAudioSignature: [RenderClipAudio] {
        tracks.flatMap(\.items).compactMap { item in
            guard let clip = item.legacyClip() else { return nil }
            let pitchFollowsSpeed: Bool
            if case .media(let media) = item {
                pitchFollowsSpeed = media.pitchFollowsSpeed
            } else {
                pitchFollowsSpeed = false
            }
            return RenderClipAudio(
                id: clip.id,
                volume: clip.volume,
                pitchFollowsSpeed: pitchFollowsSpeed
            )
        }
    }
}

private struct RenderTopologySignature: Equatable {
    let tracks: [RenderTrackTopology]
}

private struct RenderTrackTopology: Equatable {
    let id: UUID
    let kind: TrackKind
    let isMuted: Bool
    let items: [RenderItemTopology]
}

private struct RenderItemTopology: Equatable {
    let id: UUID
    let kind: TimelineItemKind
    let mediaID: MediaID?
    let mediaType: ClipMediaType?
    let timelineStart: Double
    let placementDuration: Double
    let sourceRange: TimeRangeValue
    let hasShape: Bool
    let speedSignature: UInt64
    let usesBackgroundRemoval: Bool
    let backgroundRemovalArtifact: BackgroundRemovalArtifact?
}

private struct RenderVisualSignature: Equatable {
    let canvasWidth: Int
    let canvasHeight: Int
    let frameRate: Int32
    let backgroundColor: RGBAColor
    let items: [RenderItemVisual]
}

private struct RenderItemVisual: Equatable {
    let id: UUID
    let transform: ClipTransform
    let adjustments: AdjustmentSettings
    let effects: EffectStack
    let mask: ItemMask?
    let backgroundRemoval: BackgroundRemovalSettings?
    let blendMode: BlendMode
    let blendIntensity: Double
    let shape: ClipShape?
    let text: TextTimelineItem?
}

private struct RenderClipAudio: Equatable {
    let id: UUID
    let volume: AnimatableProperty<Double>
    let pitchFollowsSpeed: Bool
}
