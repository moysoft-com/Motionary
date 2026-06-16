//
//  MotionaryTests.swift
//  MotionaryTests
//
//  Created by Lian on 28.02.25.
//

import Foundation
import Testing
@testable import Motionary

struct MotionaryTests {

    @Test func keyframeInterpolationUsesLinearValues() async throws {
        let property = AnimatableProperty(
            baseValue: 0.2,
            keyframes: [
                Keyframe(time: 0, value: 0.0),
                Keyframe(time: 10, value: 1.0)
            ]
        )

        #expect(property.value(at: -1) == 0)
        #expect(property.value(at: 0) == 0)
        #expect(property.value(at: 5) == 0.5)
        #expect(property.value(at: 10) == 1)
        #expect(property.value(at: 20) == 1)
    }

    @Test func legacyContentMigratesIntoLayerTimeline() async throws {
        let clip = Clip(
            sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
            startTime: 1,
            endTime: 6,
            mediaType: .video
        )

        let content = ProjectContent(
            clips: [clip],
            keyframes: [Keyframe(time: 2, value: 0.8)],
            selectedEffect: .sepia,
            effectIntensity: 0.4,
            title: "Legacy"
        )

        #expect(content.editorProject.schemaVersion == EditorProject.currentSchemaVersion)
        #expect(content.editorProject.tracks.count == 1)
        #expect(content.editorProject.tracks[0].kind == TrackKind.visual)
        #expect(content.editorProject.tracks[0].clips.count == 1)
        #expect(content.editorProject.tracks[0].clips[0].sourceRange.duration == 5)
        #expect(content.editorProject.tracks[0].clips[0].effectStack.effects.first?.kind == .sepia)
        #expect(content.editorProject.tracks[0].clips[0].effectStack.effects.first?.intensity.baseValue == 0.4)
    }

    @Test func legacyAudioContentAddsAudioTrackOnlyWhenNeeded() async throws {
        let clip = Clip(
            sourceURL: URL(fileURLWithPath: "/tmp/music.m4a"),
            startTime: 0,
            endTime: 3,
            mediaType: .audio
        )

        let content = ProjectContent(
            clips: [clip],
            keyframes: [],
            selectedEffect: .none,
            effectIntensity: 0,
            title: "Audio"
        )

        #expect(content.editorProject.tracks.count == 2)
        #expect(content.editorProject.tracks[0].kind == TrackKind.visual)
        #expect(content.editorProject.tracks[1].kind == TrackKind.audio)
        #expect(content.editorProject.tracks[1].clips.count == 1)
    }

    @Test func effectStackRoundTripsThroughProjectContent() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            mediaType: .video,
            originalDuration: 3
        )
        let clip = TimelineClip(
            name: "Shot",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3),
            effectStack: EffectStack(effects: [
                ClipEffect(kind: .vignette, intensity: AnimatableProperty(baseValue: 0.7))
            ])
        )
        let project = EditorProject(
            title: "Roundtrip",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.tracks[0].clips[0].effectStack.effects[0].kind == ClipEffectKind.vignette)
        #expect(decoded.editorProject.tracks[0].clips[0].effectStack.effects[0].intensity.baseValue == 0.7)
    }

    @MainActor
    @Test func placingVisualClipBeyondRowsCreatesVisualLayer() async throws {
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
        #expect(viewModel.project.tracks.contains { track in
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
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/destination.mov"), mediaType: .video, originalDuration: 4),
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
    @Test func placingClipIntoInsertionSlotCreatesLayerAtIndex() async throws {
        let movingID = UUID()
        let movingClip = TimelineClip(
            id: movingID,
            name: "Moving",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/moving.mov"), mediaType: .video, originalDuration: 3),
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
            title: "Insert layer",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [movingClip]),
                TimelineTrack(name: "Layer 2", kind: .visual, clips: [lowerClip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.placeClip(movingID, at: 1, proposedTrackIndex: 1, insertTrackAt: 1, rebuild: false)

        #expect(viewModel.project.tracks.count == 3)
        #expect(viewModel.project.tracks[1].clips.first?.id == movingID)
        #expect(viewModel.project.tracks[2].clips.first?.name == "Lower")
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
    @Test func selectedClipDeselectsWhenCurrentTimeLeavesClip() async throws {
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

        #expect(viewModel.selectedClipID == nil)
    }

    @MainActor
    @Test func originalRatioUsesSelectedVisualClipSizeAndPreservesFrameRate() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Landscape",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/landscape.mov"),
                mediaType: .video,
                originalDuration: 2,
                naturalSize: CGSizeValue(width: 1280, height: 720)
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Original Ratio",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 60),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.setCanvasToSelectedClipOriginalRatio()

        #expect(viewModel.project.renderSettings.width == 1280)
        #expect(viewModel.project.renderSettings.height == 720)
        #expect(viewModel.project.renderSettings.frameRate == 60)
    }

    @Test func emptyProjectCompositionIsValidAndVideoFree() async throws {
        let project = EditorProject.empty(title: "Empty")
        let rendered = try await CompositionRenderService().makeComposition(for: project)

        #expect(rendered.duration == 0)
        #expect(rendered.hasVideo == false)
        #expect(rendered.videoComposition == nil)
    }
}
