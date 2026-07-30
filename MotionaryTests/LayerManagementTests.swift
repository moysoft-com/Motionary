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
    @Test func deletingLastClipKeepsItsLayer() async throws {
        let trackID = UUID()
        let clipID = UUID()
        let sourceURL = URL(fileURLWithPath: "/tmp/only.mov")
        let clip = TimelineClip(
            id: clipID,
            name: "Only clip",
            source: ClipSource(
                url: sourceURL,
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

        viewModel.seek(to: viewModel.duration)

        #expect(abs(viewModel.currentTime - viewModel.duration) < 0.000_001)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].clips.isEmpty)
        #expect(viewModel.project.tracks[0].kind == .undefined)
        #expect(viewModel.project.tracks[0].name == "Layer")
        #expect(viewModel.selectedClipID == nil)
        #expect(viewModel.selectedTrackID == trackID)
        #expect(viewModel.currentTime == 0)

        let persistedData = try JSONEncoder().encode(ProjectContent(editorProject: viewModel.project))
        let persistedContent = try JSONDecoder().decode(ProjectContent.self, from: persistedData)
        #expect(persistedContent.editorProject.tracks.count == 1)
        #expect(persistedContent.editorProject.tracks[0].id == trackID)
        #expect(persistedContent.editorProject.tracks[0].kind == .undefined)

        let textID = viewModel.addText()

        #expect(textID != nil)
        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].kind == .text)

        viewModel.undo()
        viewModel.undo()

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].kind == .visual)
        #expect(viewModel.project.tracks[0].clips.map(\.id) == [clipID])
        #expect(viewModel.project.mediaAsset(for: viewModel.project.tracks[0].clips[0])?.url == sourceURL)
    }

    @MainActor
    @Test func newOverlayLayersStartOnCurrentVisibleFrame() async throws {
        let existingClip = TimelineClip(
            name: "Existing",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/existing.mov"),
                mediaType: .video,
                originalDuration: 4
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var project = EditorProject(
            title: "Visible frame insertion",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [existingClip])]
        )
        project.renderSettings.frameRate = 30
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.currentTime = 1.049

        viewModel.addShape(.rectangle)
        let shape = try #require(viewModel.selectedTimelineItem?.legacyClip())
        #expect(abs(shape.timelineStart - (31.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (31.0 / 30.0)) < 0.000_001)

        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/imported.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        viewModel.currentTime = 2.049
        viewModel.addImportedMedia(
            ImportedMedia(source: source, storedURL: source.url)
        )
        let imported = try #require(viewModel.selectedClip)
        #expect(abs(imported.timelineStart - (61.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (61.0 / 30.0)) < 0.000_001)
    }

    @MainActor
    @Test func newTextLayersUseVisibleFrameAndLargerDefaultSize() async throws {
        var project = EditorProject(title: "Text defaults")
        project.renderSettings.frameRate = 30
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.currentTime = 1.049

        let textID = try #require(viewModel.addText())
        guard case .text(let text) = try #require(viewModel.project.item(id: textID)) else {
            Issue.record("Expected inserted text item")
            return
        }

        #expect(abs(text.timelineStart - (31.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (31.0 / 30.0)) < 0.000_001)
        #expect(text.style.fontSize == 72)
        #expect(text.propertyAnimations.fontSize.baseValue == 72)
    }

    @MainActor
    @Test func deletingOnlyClipRemovesLayerWhenAnotherLayerRemains() async throws {
        let deletedTrackID = UUID()
        let remainingTrackID = UUID()
        let clip = TimelineClip(
            name: "Only layer clip",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/only-layer-clip.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Remove empty layer",
                    tracks: [
                        TimelineTrack(id: deletedTrackID, name: "Layer 1", kind: .visual, clips: [clip]),
                        TimelineTrack(id: remainingTrackID, name: "Layer", kind: .undefined),
                    ]
                )
            )
        )
        viewModel.selectClip(clip.id, trackID: deletedTrackID)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks.map(\.id) == [remainingTrackID])
        #expect(viewModel.selectedTrackID == remainingTrackID)

        viewModel.undo()

        #expect(viewModel.project.tracks.map(\.id) == [deletedTrackID, remainingTrackID])
        #expect(viewModel.project.clip(id: clip.id) != nil)
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
        let previewGenerationBeforeReorder = viewModel.previewGeneration

        viewModel.moveTrack(audioID, to: 0)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, visualID, undefinedID])
        #expect(viewModel.previewGeneration > previewGenerationBeforeReorder)

        viewModel.moveTrack(undefinedID, to: 1)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, undefinedID, visualID])
    }

    @Test func automergeUsesTopMatchingLayerWhenImportedRangeIsFree() {
        let occupied = TimelineClip(
            name: "Existing",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/existing.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Automerge",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [occupied]),
                TimelineTrack(name: "Layer 2", kind: .visual)
            ]
        )

        #expect(project.topAvailableTrackIndex(kind: .visual, start: 2, duration: 3) == 0)
        #expect(project.topAvailableTrackIndex(kind: .visual, start: 1, duration: 3) == 1)
        #expect(project.topAvailableTrackIndex(kind: .audio, start: 0, duration: 3) == nil)
    }
}
