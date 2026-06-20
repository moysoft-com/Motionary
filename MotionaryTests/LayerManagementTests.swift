// Layer creation, persistence, deletion, and ordering tests.

import Foundation
import Testing

@testable import Motionary

@MainActor
struct LayerManagementTests {
    @Test func toolbarCanCreateMultipleTemporaryUndefinedLayers() async throws {
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject.empty(title: "Toolbar Layer"))
        )

        viewModel.addLayer()
        viewModel.addLayer()

        let undefinedTracks = viewModel.project.tracks.filter { $0.kind == .undefined }
        #expect(undefinedTracks.count == 2)
        #expect(undefinedTracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func emptyUndefinedLayersAreRemovedDuringPersistenceRoundTrip() async throws {
        let project = EditorProject(
            title: "Temporary layers",
            tracks: [
                TimelineTrack(name: "Temporary 1", kind: .undefined),
                TimelineTrack(name: "Layer 1", kind: .visual),
                TimelineTrack(name: "Temporary 2", kind: .undefined)
            ]
        )

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.tracks.count == 1)
        #expect(decoded.editorProject.tracks[0].kind == .visual)
    }

    @Test func emptyTypedLayersSurvivePersistenceRoundTrip() async throws {
        let project = EditorProject(
            title: "Typed layers",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual),
                TimelineTrack(name: "Audio 1", kind: .audio)
            ]
        )

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.tracks.map(\.kind) == [.visual, .audio])
    }

    @MainActor
    @Test func deletingLayerRemovesItsClipsAndUpdatesSelection() async throws {
        let deletedTrackID = UUID()
        let remainingTrackID = UUID()
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Deleted clip",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/deleted.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Delete layer",
            tracks: [
                TimelineTrack(id: deletedTrackID, name: "Layer 1", kind: .visual, clips: [clip]),
                TimelineTrack(id: remainingTrackID, name: "Layer 2", kind: .visual)
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectClip(clipID, trackID: deletedTrackID)

        viewModel.deleteLayer(deletedTrackID)

        #expect(viewModel.project.tracks.map(\.id) == [remainingTrackID])
        #expect(viewModel.selectedClipID == nil)
        #expect(viewModel.selectedTrackID == remainingTrackID)
    }

    @MainActor
    @Test func deletingLastClipRemovesItsLayer() async throws {
        let trackID = UUID()
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Only clip",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/only.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Keep layer",
            tracks: [
                TimelineTrack(id: trackID, name: "Layer 1", kind: .visual, clips: [clip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectClip(clipID, trackID: trackID)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks.isEmpty)
        #expect(viewModel.selectedClipID == nil)
        #expect(viewModel.selectedTrackID == nil)
    }

    @MainActor
    @Test func trackReorderUsesVisibleAbsoluteIndicesAcrossKinds() async throws {
        let visualID = UUID()
        let audioID = UUID()
        let undefinedID = UUID()
        let project = EditorProject(
            title: "Track order",
            tracks: [
                TimelineTrack(id: visualID, name: "Layer 1", kind: .visual),
                TimelineTrack(id: audioID, name: "Audio 1", kind: .audio),
                TimelineTrack(id: undefinedID, name: "Layer", kind: .undefined)
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.moveTrack(audioID, to: 0)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, visualID, undefinedID])

        viewModel.moveTrack(undefinedID, to: 1)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, undefinedID, visualID])
    }
}
