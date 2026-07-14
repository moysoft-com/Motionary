import Foundation

struct SetRenderSettingsCommand: EditorCommand {
    let before: RenderSettings
    let after: RenderSettings
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.renderSettings = after
    }

    func undo(on project: inout EditorProject) {
        project.renderSettings = before
    }
}

struct ReplaceClipMediaCommand: EditorCommand {
    let clipID: UUID
    let beforeClip: TimelineClip
    let beforeMedia: MediaAsset?
    let afterClip: TimelineClip
    let afterMedia: MediaAsset
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.replaceClip(id: clipID, with: afterClip)
        project.mediaLibrary[afterMedia.id] = afterMedia
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        project.replaceClip(id: clipID, with: beforeClip)
        if let beforeMedia {
            project.mediaLibrary[beforeMedia.id] = beforeMedia
        } else {
            project.mediaLibrary.removeValue(forKey: afterMedia.id)
        }
        project.synchronizeMediaLibrary()
    }
}

struct SplitClipCommand: EditorCommand {
    let trackID: UUID
    let originalItem: TimelineItem
    let first: TimelineItem
    let second: TimelineItem
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
            let itemIndex = project.tracks[trackIndex].itemIndex(id: originalItem.id)
        else { return }
        project.tracks[trackIndex].items[itemIndex] = first
        project.tracks[trackIndex].items.insert(second, at: itemIndex + 1)
        project.tracks[trackIndex].sortItems()
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        _ = project.tracks[trackIndex].removeItem(id: second.id)
        guard let firstIndex = project.tracks[trackIndex].itemIndex(id: first.id) else { return }
        project.tracks[trackIndex].items[firstIndex] = originalItem
        project.tracks[trackIndex].sortItems()
        project.synchronizeMediaLibrary()
    }
}

struct DuplicateClipCommand: EditorCommand {
    let trackID: UUID
    let copy: TimelineItem
    let insertIndex: Int
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        project.tracks[trackIndex].items.insert(copy, at: min(max(insertIndex, 0), project.tracks[trackIndex].items.count))
        project.tracks[trackIndex].sortItems()
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        _ = project.tracks[trackIndex].removeItem(id: copy.id)
        project.synchronizeMediaLibrary()
    }
}

struct MoveClipCommand: EditorCommand {
    let clipID: UUID
    let beforeStart: Double
    let afterStart: Double
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard let location = project.clipLocation(id: clipID) else { return }
        project.tracks[location.track].setTimelineStart(id: clipID, to: afterStart)
    }

    func undo(on project: inout EditorProject) {
        guard let location = project.clipLocation(id: clipID) else { return }
        project.tracks[location.track].setTimelineStart(id: clipID, to: beforeStart)
    }
}

struct PlaceClipCommand: EditorCommand {
    let beforeTracks: [TimelineTrack]
    let afterTracks: [TimelineTrack]
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.tracks = afterTracks
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        project.tracks = beforeTracks
        project.synchronizeMediaLibrary()
    }
}

struct TrimClipCommand: EditorCommand {
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

struct TrackStructureCommand: EditorCommand {
    let beforeTracks: [TimelineTrack]
    let afterTracks: [TimelineTrack]
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.tracks = afterTracks
        project.renumberTracks()
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        project.tracks = beforeTracks
        project.renumberTracks()
        project.synchronizeMediaLibrary()
    }
}

struct ImportMediaCommand: EditorCommand {
    let beforeTracks: [TimelineTrack]
    let beforeRenderSettings: RenderSettings
    let beforeMediaLibrary: [MediaID: MediaAsset]
    let afterTracks: [TimelineTrack]
    let afterRenderSettings: RenderSettings
    let afterMediaLibrary: [MediaID: MediaAsset]
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.tracks = afterTracks
        project.renderSettings = afterRenderSettings
        project.mediaLibrary = afterMediaLibrary
        project.renumberTracks()
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        project.tracks = beforeTracks
        project.renderSettings = beforeRenderSettings
        project.mediaLibrary = beforeMediaLibrary
        project.renumberTracks()
        project.synchronizeMediaLibrary()
    }
}

struct ExtractAudioCommand: EditorCommand {
    let beforeTracks: [TimelineTrack]
    let beforeMediaLibrary: [MediaID: MediaAsset]
    let afterTracks: [TimelineTrack]
    let afterMediaLibrary: [MediaID: MediaAsset]
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        project.tracks = afterTracks
        project.mediaLibrary = afterMediaLibrary
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        project.tracks = beforeTracks
        project.mediaLibrary = beforeMediaLibrary
        project.synchronizeMediaLibrary()
    }
}

enum EditorCommandFactory {
    static func setRenderSettings(
        before: RenderSettings,
        after: RenderSettings,
        invalidation: EditorInvalidation = [.previewFrame, .compositionTopology, .persistence]
    ) -> AnyEditorCommand {
        AnyEditorCommand(
            SetRenderSettingsCommand(before: before, after: after, invalidation: invalidation)
        )
    }

    static func replaceClip(
        before: TimelineItem,
        after: TimelineItem,
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        AnyEditorCommand(ReplaceClipCommand(before: before, after: after, invalidation: invalidation))
    }

    /// Keeps existing media/shape callers source-compatible while the command
    /// itself operates on the shared typed timeline-item representation.
    static func replaceClip(
        before: TimelineClip,
        after: TimelineClip,
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        replaceClip(
            before: .fromLegacyClip(before),
            after: .fromLegacyClip(after),
            invalidation: invalidation
        )
    }

    static func trackStructure(
        before: [TimelineTrack],
        after: [TimelineTrack],
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        AnyEditorCommand(
            TrackStructureCommand(
                beforeTracks: before,
                afterTracks: after,
                invalidation: invalidation
            )
        )
    }

    static func importMedia(
        before: EditorProject,
        after: EditorProject,
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        AnyEditorCommand(
            ImportMediaCommand(
                beforeTracks: before.tracks,
                beforeRenderSettings: before.renderSettings,
                beforeMediaLibrary: before.mediaLibrary,
                afterTracks: after.tracks,
                afterRenderSettings: after.renderSettings,
                afterMediaLibrary: after.mediaLibrary,
                invalidation: invalidation
            )
        )
    }
}
