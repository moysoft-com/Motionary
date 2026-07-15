// Timeline placement, compatibility, snapping-preview, and overlap tests.

import Foundation
import Testing

@testable import Motionary

struct TimelinePlacementTests {
    @Test func snappingAlwaysChoosesNearestEligibleAnchor() async throws {
        let firstAnchor = TimelineClip(
            name: "First",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/first.mov"), mediaType: .video, originalDuration: 0.1),
            timelineStart: 1,
            sourceRange: TimeRangeValue(start: 0, duration: 0.1)
        )
        let secondAnchor = TimelineClip(
            name: "Second",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/second.mov"), mediaType: .video, originalDuration: 0.1),
            timelineStart: 1.08,
            sourceRange: TimeRangeValue(start: 0, duration: 0.1)
        )
        let project = EditorProject(
            title: "Nearest snap",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [firstAnchor, secondAnchor]),
                TimelineTrack(name: "Layer 2", kind: .visual)
            ]
        )

        let placement = project.resolvedPlacement(
            proposedStart: 1.055,
            duration: 0.2,
            destinationTrackIndex: 1,
            requiredKind: .visual
        )

        #expect(abs(placement.start - 1.08) < 0.0001)
        #expect(placement.snapTime == 1.08)
    }

    @MainActor
    @Test func placingVisualClipBeyondRowsStaysOnNearestVisualLayer() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Video",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/video.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let project = EditorProject(
            title: "Placement",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(clipID, at: 2.5, proposedTrackIndex: 1, rebuild: false)

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].kind == TrackKind.visual)
        #expect(viewModel.project.tracks[0].clips.first?.id == clipID)
        #expect(viewModel.project.tracks[0].clips.first?.timelineStart == 2.5)
    }

    @MainActor
    @Test func placingAudioClipOnVisualAreaCreatesAudioTrack() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Audio",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/audio.m4a"), mediaType: .audio, originalDuration: 3),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let project = EditorProject(
            title: "Audio Placement",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual),
                TimelineTrack(name: "Audio 1", kind: .audio, clips: [clip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(clipID, at: 1, proposedTrackIndex: 0, rebuild: false)

        let emptyVisualTracks = viewModel.project.tracks.filter { $0.kind == .visual && $0.clips.isEmpty }
        #expect(emptyVisualTracks.count <= 1)
        #expect(
            viewModel.project.tracks.contains { track in
                track.kind == .audio && track.clips.contains { $0.id == clipID }
            })
    }

    @MainActor
    @Test func placingClipCannotOverlapSameLayer() async throws {
        let movingID = UUID()
        let lockedClip = TimelineClip(
            name: "Locked",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/locked.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let project = EditorProject(
            title: "No overlap",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [lockedClip, movingClip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 2, proposedTrackIndex: 0, rebuild: false)

        let clips = viewModel.project.tracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(clips.count == 2)
        #expect(clips[0].timelineEnd <= clips[1].timelineStart)
    }

    @MainActor
    @Test func movingSelectedClipCannotOverlapSameLayer() async throws {
        let movingID = UUID()
        let firstClip = TimelineClip(
            name: "First",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/first.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let project = EditorProject(
            title: "Move no overlap",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [firstClip, movingClip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(movingID, trackID: viewModel.project.tracks[0].id)
        viewModel.moveSelectedClip(by: -3)

        let clips = viewModel.project.tracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(clips.count == 2)
        #expect(clips[0].timelineEnd <= clips[1].timelineStart)
    }

    @MainActor
    @Test func placingClipAcrossTracksCannotOverlapDestinationLayer() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let destinationClip = TimelineClip(
            name: "Destination",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/destination.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 1,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let project = EditorProject(
            title: "Cross track no overlap",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip]),
                TimelineTrack(name: "Layer 2", kind: .visual, clips: [destinationClip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 2, proposedTrackIndex: 1, rebuild: false)

        let destination = viewModel.project.tracks.first { track in
            track.clips.contains { $0.id == movingID }
        }
        let clips = destination?.clips.sorted { $0.timelineStart < $1.timelineStart } ?? []
        #expect(clips.count == 2)
        #expect(clips[0].timelineEnd <= clips[1].timelineStart)
    }

    @MainActor
    @Test func placingClipIntoInsertionSlotDoesNotCreateLayer() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let sourceAnchor = TimelineClip(
            name: "Anchor",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/anchor.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let lowerClip = TimelineClip(
            name: "Lower",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/lower.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Insert layer",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip, sourceAnchor]),
                TimelineTrack(name: "Layer 2", kind: .visual, clips: [lowerClip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 1, proposedTrackIndex: 1, insertTrackAt: 1, rebuild: false)

        #expect(viewModel.project.tracks.count == 2)
        #expect(viewModel.project.tracks[0].clips.contains { $0.name == "Anchor" })
        #expect(viewModel.project.tracks[1].clips.contains { $0.id == movingID })
        #expect(viewModel.project.tracks[1].clips.contains { $0.name == "Lower" })
    }

    @MainActor
    @Test func placingClipOnUndefinedLayerAdoptsClipKind() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let project = EditorProject(
            title: "Undefined target",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip]),
                TimelineTrack(name: "Layer", kind: .undefined)
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 1, proposedTrackIndex: 1, rebuild: false)

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].kind == .visual)
        #expect(viewModel.project.tracks[0].clips.first?.id == movingID)
        #expect(viewModel.project.tracks[0].clips.first?.timelineStart == 1)
    }

    @MainActor
    @Test func draggingOverIncompatibleLayerUsesNearestCompatibleInDragDirection() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let audioClip = TimelineClip(
            name: "Audio",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/audio.m4a"), mediaType: .audio, originalDuration: 3),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let lowerClip = TimelineClip(
            name: "Lower",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/lower.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Incompatible middle",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip]),
                TimelineTrack(name: "Audio 1", kind: .audio, clips: [audioClip]),
                TimelineTrack(name: "Layer 2", kind: .visual, clips: [lowerClip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 1, proposedTrackIndex: 1, rebuild: false)

        let destination = viewModel.project.tracks.first { track in
            track.kind == .visual && track.clips.contains { $0.name == "Lower" }
        }
        #expect(viewModel.project.tracks.count == 2)
        #expect(viewModel.project.tracks.allSatisfy { !$0.clips.isEmpty })
        #expect(destination?.clips.contains { $0.id == movingID } == true)
    }

    @MainActor
    @Test func previewPlacementCommitsExactResolvedPlacement() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 1),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let sourceAnchor = TimelineClip(
            name: "Source Anchor",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/source-anchor.mov"), mediaType: .video, originalDuration: 1),
            timelineStart: 5,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let destinationAnchor = TimelineClip(
            name: "Destination Anchor",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/destination-anchor.mov"), mediaType: .video, originalDuration: 1),
            timelineStart: 6,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Preview commit",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip, sourceAnchor]),
                TimelineTrack(name: "Layer 2", kind: .visual, clips: [destinationAnchor])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        let preview = try #require(viewModel.resolveClipPlacement(movingID, at: 2, proposedTrackIndex: 1))
        let committed = try #require(viewModel.placeClip(movingID, using: preview, rebuild: false))

        #expect(committed == preview)
        #expect(viewModel.project.tracks[1].clips.contains { $0.id == movingID && $0.timelineStart == preview.start })
    }
}
