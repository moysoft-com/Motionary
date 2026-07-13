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
    let originalClip: TimelineClip
    let first: TimelineClip
    let second: TimelineClip
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }),
            let itemIndex = project.tracks[trackIndex].itemIndex(id: originalClip.id)
        else { return }
        project.tracks[trackIndex].replaceLegacyClip(id: first.id, with: first)
        project.tracks[trackIndex].insertLegacyClip(second, at: itemIndex + 1)
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        _ = project.tracks[trackIndex].removeItem(id: second.id)
        project.tracks[trackIndex].replaceLegacyClip(id: first.id, with: originalClip)
        project.synchronizeMediaLibrary()
    }
}

struct RemoveClipCommand: EditorCommand {
    let removedTrack: TimelineTrack?
    let trackIndex: Int
    let itemIndex: Int
    let item: TimelineItem
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        project.tracks[trackIndex].items.remove(at: itemIndex)
        if project.tracks[trackIndex].items.isEmpty {
            project.tracks.remove(at: trackIndex)
        }
        project.synchronizeMediaLibrary()
    }

    func undo(on project: inout EditorProject) {
        if let removedTrack {
            project.tracks.insert(removedTrack, at: min(trackIndex, project.tracks.count))
        } else if project.tracks.indices.contains(trackIndex) {
            project.tracks[trackIndex].items.insert(
                item,
                at: min(itemIndex, project.tracks[trackIndex].items.count)
            )
        }
        project.synchronizeMediaLibrary()
    }
}

struct DuplicateClipCommand: EditorCommand {
    let trackID: UUID
    let copy: TimelineClip
    let insertIndex: Int
    let invalidation: EditorInvalidation

    func apply(to project: inout EditorProject) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        project.tracks[trackIndex].insertLegacyClip(copy, at: insertIndex)
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
        before: TimelineClip,
        after: TimelineClip,
        invalidation: EditorInvalidation
    ) -> AnyEditorCommand {
        AnyEditorCommand(ReplaceClipCommand(before: before, after: after, invalidation: invalidation))
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
