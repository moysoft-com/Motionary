// Timeline trimming and selection-visibility tests.

import Foundation
import Testing

@testable import Motionary

struct TimelineEditingTests {
    @MainActor
    @Test func timelineItemEditingPreservesRichPropertiesThroughUndo() async throws {
        let itemID = UUID()
        let speedMap = SpeedMap.constant(speed: 1.5)
        let mask = ItemMask(shape: .ellipse, insetX: 0.1, insetY: 0.2, feather: 0.3)
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Rich item",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4),
                visuals: TimelineItemVisuals(blendMode: .screen, mask: mask),
                speedMap: speedMap,
                pitchFollowsSpeed: true
            )
        )
        let project = EditorProject(
            title: "Typed editing",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)

        viewModel.moveSelectedTimelineItem(by: 1)
        guard case .media(let moved) = try #require(viewModel.project.item(id: itemID)) else {
            Issue.record("Expected moved media item")
            return
        }
        #expect(moved.timelineStart == 1)
        #expect(moved.speedMap == speedMap)
        #expect(moved.pitchFollowsSpeed)
        #expect(moved.visuals.blendMode == .screen)
        #expect(moved.visuals.mask == mask)
        viewModel.undo()

        viewModel.duplicateSelectedClip(toNewLayer: true)
        let duplicateID = try #require(viewModel.selectedTimelineItemID)
        let duplicateLocation = try #require(viewModel.project.itemLocation(id: duplicateID))
        let originalLocation = try #require(viewModel.project.itemLocation(id: itemID))
        guard case .media(let duplicate) = try #require(viewModel.project.item(id: duplicateID)) else {
            Issue.record("Expected duplicated media item")
            return
        }
        #expect(viewModel.project.tracks.count == 2)
        #expect(duplicateLocation.track != originalLocation.track)
        #expect(duplicate.timelineStart == 0)
        #expect(duplicate.speedMap == speedMap)
        #expect(duplicate.pitchFollowsSpeed)
        #expect(duplicate.visuals.blendMode == .screen)
        #expect(duplicate.visuals.mask == mask)

        viewModel.undo()
        #expect(viewModel.project.item(id: duplicateID) == nil)
        #expect(viewModel.project.tracks.count == 1)
        guard case .media(let restored) = try #require(viewModel.project.item(id: itemID)) else {
            Issue.record("Expected original media item")
            return
        }
        #expect(restored.speedMap == speedMap)
        #expect(restored.pitchFollowsSpeed)
        #expect(restored.visuals.blendMode == .screen)
        #expect(restored.visuals.mask == mask)
    }

    @MainActor
    @Test func splitAndTrimOperateOnTimelineItemWithoutDroppingProperties() async throws {
        let itemID = UUID()
        let speedMap = SpeedMap(keyframes: [SpeedKeyframe(time: 0, speed: 1.25)])
        let mask = ItemMask(shape: .rectangle, feather: 0.2)
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Editable",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 5),
                visuals: TimelineItemVisuals(blendMode: .multiply, mask: mask),
                speedMap: speedMap
            )
        )
        let project = EditorProject(
            title: "Split typed item",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)
        viewModel.seek(to: 2)

        let rightID = try #require(viewModel.splitSelectedTimelineItem())
        guard case .media(let right) = try #require(viewModel.project.item(id: rightID)) else {
            Issue.record("Expected right media item")
            return
        }
        #expect(right.speedMap == speedMap)
        #expect(right.visuals.blendMode == .multiply)
        #expect(right.visuals.mask == mask)

        viewModel.trimTimelineItemEnd(rightID, by: -0.2, rebuild: false)
        guard case .media(let trimmed) = try #require(viewModel.project.item(id: rightID)) else {
            Issue.record("Expected trimmed media item")
            return
        }
        #expect(trimmed.speedMap == speedMap)
        #expect(trimmed.visuals.blendMode == .multiply)
        #expect(trimmed.visuals.mask == mask)

        viewModel.undo()
        viewModel.undo()
        #expect(viewModel.project.tracks.flatMap(\.items) == [item])
    }

    @MainActor
    @Test func constantSpeedUsesRippleAndUndoRestoresTiming() async throws {
        let firstID = UUID()
        let first = TimelineItem.media(
            MediaTimelineItem(
                id: firstID,
                name: "First",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4)
            )
        )
        let second = TimelineItem.media(
            MediaTimelineItem(
                name: "Second",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 4,
                sourceRange: TimeRangeValue(start: 0, duration: 2)
            )
        )
        let project = EditorProject(
            title: "Speed",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [first, second])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.isRippleEditingEnabled = true
        viewModel.selectTimelineItem(firstID, trackID: project.tracks[0].id)

        #expect(viewModel.setSelectedConstantSpeed(0.5))
        #expect(viewModel.project.tracks[0].items.map(\.timelineStart) == [0, 8])
        #expect(viewModel.project.item(id: firstID)?.placementDuration == 8)

        viewModel.undo()
        #expect(viewModel.project.tracks[0].items == [first, second])
    }

    @MainActor
    @Test func staticAudioSpeedAndPitchAreUndoable() async throws {
        let itemID = UUID()
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Audio",
                mediaID: MediaID(),
                mediaType: .audio,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4)
            )
        )
        let project = EditorProject(
            title: "Audio speed",
            tracks: [TimelineTrack(name: "Audio 1", kind: .audio, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)
        viewModel.seek(to: 2)

        #expect(viewModel.setSelectedSpeedAtPlayhead(2))
        viewModel.setSelectedPitchFollowsSpeed(true)

        guard case .media(let edited) = try #require(viewModel.project.item(id: itemID)) else {
            Issue.record("Expected edited media item")
            return
        }
        #expect(edited.speedMap.keyframes.count == 1)
        #expect(edited.speedMap.speed(at: 1) == 2)
        #expect(edited.speedMap.speed(at: 2) == 2)
        #expect(abs(edited.timelineDuration - 2) < 0.000_001)
        #expect(edited.pitchFollowsSpeed)

        viewModel.undo()
        viewModel.undo()
        #expect(viewModel.project.item(id: itemID) == item)
    }

    @MainActor
    @Test func speedDoesNotExposeAKeyframeGraph() async throws {
        let itemID = UUID()
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Constant",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4)
            )
        )
        let project = EditorProject(
            title: "Constant speed graph",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)

        #expect(viewModel.candidateGraphSegment(in: .speed) == nil)
    }

    @MainActor
    @Test func interactiveConstantSpeedEditKeepsTheSourceFrameAndIsOneUndoStep() async throws {
        let itemID = UUID()
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Anchored",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4)
            )
        )
        let project = EditorProject(
            title: "Anchored speed edit",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)
        viewModel.seek(to: 2)

        let session = try #require(viewModel.beginSelectedSpeedEditAtPlayhead())
        #expect(viewModel.setSelectedSpeed(0.5, in: session, interactive: true))
        #expect(abs(viewModel.currentTime - 4) < 0.000_001)
        #expect(viewModel.setSelectedSpeed(2, in: session, interactive: true))
        #expect(abs(viewModel.currentTime - 1) < 0.000_001)
        viewModel.finishInteractiveEdit()

        guard case .media(let edited) = try #require(viewModel.project.item(id: itemID)) else {
            Issue.record("Expected edited media item")
            return
        }
        #expect(edited.speedMap.keyframes.count == 1)
        #expect(edited.speedMap.speed(at: 0) == 2)

        viewModel.undo()
        #expect(viewModel.project.item(id: itemID) == item)
    }

    @MainActor
    @Test func interactiveSpeedAlwaysRemainsStatic() async throws {
        let itemID = UUID()
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Variable",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4),
                speedMap: SpeedMap(
                    keyframes: [
                        SpeedKeyframe(time: 0, speed: 1),
                        SpeedKeyframe(time: 2, speed: 0.5),
                    ]
                )
            )
        )
        let project = EditorProject(
            title: "Variable speed edit",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)
        viewModel.seek(to: 2)

        let session = try #require(viewModel.beginSelectedSpeedEditAtPlayhead())
        #expect(viewModel.setSelectedSpeed(0.25, in: session, interactive: true))
        #expect(viewModel.setSelectedSpeed(4, in: session, interactive: true))
        viewModel.finishInteractiveEdit()

        guard case .media(let edited) = try #require(viewModel.project.item(id: itemID)) else {
            Issue.record("Expected edited media item")
            return
        }
        #expect(edited.speedMap.keyframes.count == 1)
        #expect(edited.speedMap == .constant(speed: 4))
    }

    @MainActor
    @Test func rippleDeleteClosesGapAndUndoRestoresTrack() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/first.mov")
        let first = TimelineClip(
            name: "First",
            source: ClipSource(url: firstURL, mediaType: .video, originalDuration: 2),
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
        #expect(viewModel.project.mediaAsset(for: viewModel.project.tracks[0].clips[0])?.url == firstURL)
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
