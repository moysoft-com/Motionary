// Timeline trimming and selection-visibility tests.

import Foundation
import Testing

@testable import Motionary

struct TimelineEditingTests {
    @MainActor
    @Test func rippleDeleteClosesGapAndUndoRestoresTrack() async throws {
        let first = TimelineClip(
            name: "First",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/first.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let deletedID = UUID()
        let deleted = TimelineClip(
            id: deletedID,
            name: "Deleted",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/deleted.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 2,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let last = TimelineClip(
            name: "Last",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/last.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 4,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Ripple delete",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [first, deleted, last])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.isRippleEditingEnabled = true
        viewModel.selectClip(deletedID, trackID: viewModel.project.tracks[0].id)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks[0].clips.map(\.timelineStart) == [0, 2])

        viewModel.undo()

        #expect(viewModel.project.tracks[0].clips.map(\.timelineStart) == [0, 2, 4])
    }

    @MainActor
    @Test func trimmingClipEdgesCannotCrossNeighbors() async throws {
        let middleID = UUID()
        let left = TimelineClip(
            name: "Left",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/left.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let middle = TimelineClip(
            id: middleID,
            name: "Middle",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/middle.mov"), mediaType: .video, originalDuration: 8),
            timelineStart: 3,
            sourceRange: TimeRangeValue(start: 1, duration: 3)
        )
        let right = TimelineClip(
            name: "Right",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/right.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 7,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Trim bounds",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [left, middle, right])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.trimClipStart(middleID, by: -5, rebuild: false)
        viewModel.trimClipEnd(middleID, by: 5, rebuild: false)

        let clips = viewModel.project.tracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(clips[0].timelineEnd <= clips[1].timelineStart)
        #expect(clips[1].timelineEnd <= clips[2].timelineStart)
    }

    @MainActor
    @Test func imageClipEndCanExtendBeyondSourceDuration() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Still",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/still.png"), mediaType: .image, originalDuration: 1),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Image trim",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.trimClipEnd(clipID, by: 9, rebuild: false)

        #expect(viewModel.project.tracks[0].clips[0].sourceRange.duration == 10)
        #expect(viewModel.project.tracks[0].clips[0].sourceRange.start == 0)
    }

    @MainActor
    @Test func selectingTimelineClipRevealsNearestVisibleEdge() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Late",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/late.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let project = EditorProject(
            title: "Reveal",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id, revealInPreview: true)
        #expect(abs(viewModel.currentTime - 5.01) < 0.0001)

        viewModel.seek(to: 8)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id, revealInPreview: true)
        #expect(abs(viewModel.currentTime - 7.99) < 0.0001)
    }

    @MainActor
    @Test func selectedClipRemainsSelectedWhenCurrentTimeLeavesClip() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Short",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/short.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Deselect",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.seek(to: 2)

        #expect(viewModel.selectedClipID == clipID)
        #expect(viewModel.selectedClipIsActiveAtPlayhead == false)
    }
}
