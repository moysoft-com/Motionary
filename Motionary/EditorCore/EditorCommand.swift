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
    let before: TimelineClip
    let after: TimelineClip
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.replaceClip(id: after.id, with: after)
    }

    func undo(on project: inout EditorProject) {
        project.replaceClip(id: before.id, with: before)
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
            let change = singleClipChange(from: previous)
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

    private func singleClipChange(from previous: EditorProject) -> (before: TimelineClip, after: TimelineClip)? {
        let oldClips = Dictionary(uniqueKeysWithValues: previous.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let newClips = Dictionary(uniqueKeysWithValues: tracks.flatMap(\.clips).map { ($0.id, $0) })
        guard oldClips.keys == newClips.keys else { return nil }

        let changedIDs = oldClips.keys.filter { oldClips[$0] != newClips[$0] }
        guard changedIDs.count == 1,
            let id = changedIDs.first,
            let before = oldClips[id],
            let after = newClips[id]
        else { return nil }
        return (before, after)
    }

    private var renderTopologySignature: RenderTopologySignature {
        RenderTopologySignature(
            canvasWidth: renderSettings.width,
            canvasHeight: renderSettings.height,
            frameRate: renderSettings.frameRate,
            tracks: tracks.map { track in
                RenderTrackTopology(
                    id: track.id,
                    kind: track.kind,
                    isMuted: track.isMuted,
                    clips: track.clips.map { clip in
                        RenderClipTopology(
                            id: clip.id,
                            mediaID: clip.mediaID,
                            mediaType: clip.mediaType,
                            timelineStart: clip.timelineStart,
                            sourceRange: clip.sourceRange,
                            hasShape: clip.shape != nil
                        )
                    }
                )
            }
        )
    }

    private var renderVisualSignature: RenderVisualSignature {
        RenderVisualSignature(
            backgroundColor: renderSettings.backgroundColor,
            clips: tracks.flatMap(\.clips).map {
                RenderClipVisual(
                    id: $0.id,
                    transform: $0.transform,
                    adjustments: $0.adjustments,
                    effects: $0.effectStack,
                    shape: $0.shape
                )
            }
        )
    }

    private var renderAudioSignature: [RenderClipAudio] {
        tracks.flatMap(\.clips).map {
            RenderClipAudio(id: $0.id, volume: $0.volume)
        }
    }
}

private struct RenderTopologySignature: Equatable {
    let canvasWidth: Int
    let canvasHeight: Int
    let frameRate: Int32
    let tracks: [RenderTrackTopology]
}

private struct RenderTrackTopology: Equatable {
    let id: UUID
    let kind: TrackKind
    let isMuted: Bool
    let clips: [RenderClipTopology]
}

private struct RenderClipTopology: Equatable {
    let id: UUID
    let mediaID: MediaID
    let mediaType: ClipMediaType
    let timelineStart: Double
    let sourceRange: TimeRangeValue
    let hasShape: Bool
}

private struct RenderVisualSignature: Equatable {
    let backgroundColor: RGBAColor
    let clips: [RenderClipVisual]
}

private struct RenderClipVisual: Equatable {
    let id: UUID
    let transform: ClipTransform
    let adjustments: AdjustmentSettings
    let effects: EffectStack
    let shape: ClipShape?
}

private struct RenderClipAudio: Equatable {
    let id: UUID
    let volume: AnimatableProperty<Double>
}
