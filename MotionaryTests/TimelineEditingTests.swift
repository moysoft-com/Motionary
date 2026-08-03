// Timeline trimming and selection-visibility tests.

import Combine
import Foundation
import Testing

@testable import Motionary

struct TimelineEditingTests {
    @MainActor
    @Test func timelineViewportOverscanClampsToProjectDuration() async throws {
        let state = TimelineViewportState()
        state.update(
            contentOffset: CGPoint(x: 200, y: 0),
            viewportSize: CGSize(width: 390, height: 180),
            pixelsPerSecond: 100,
            configuration: TimelineVirtualizationConfiguration(
                centerPadding: 195,
                trackOriginY: 38,
                rowStride: 51,
                trackCount: 3,
                duration: 2
            ),
            force: true
        )

        #expect(state.window.timeRange.lowerBound >= 0)
        #expect(state.window.timeRange.upperBound == 2)
    }

    @MainActor
    @Test func timelineItemEditingPreservesRichPropertiesThroughUndo() async throws {
        let itemID = UUID()
        let speedMap = SpeedMap.constant(speed: 1.5)
        let mask = ItemMask(shape: .ellipse, insetX: 0.1, insetY: 0.2, feather: 0.3)
        let backgroundRemoval = BackgroundRemovalSettings(edgeRefinement: 0.2, feather: 0.15)
        let beats = AudioBeatAnalysis(
            bpm: 120,
            confidence: 0.9,
            markers: [AudioBeatMarker(sourceTime: 1, strength: 0.8)],
            sourceFingerprint: "fingerprint"
        )
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Rich item",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4),
                visuals: TimelineItemVisuals(
                    blendMode: .screen,
                    blendIntensity: 0.35,
                    mask: mask,
                    backgroundRemoval: backgroundRemoval
                ),
                speedMap: speedMap,
                pitchFollowsSpeed: true,
                beatAnalysis: beats
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
        #expect(moved.visuals.blendIntensity == 0.35)
        #expect(moved.visuals.mask == mask)
        #expect(moved.visuals.backgroundRemoval == backgroundRemoval)
        #expect(moved.beatAnalysis == beats)
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
        #expect(duplicate.visuals.blendIntensity == 0.35)
        #expect(duplicate.visuals.mask == mask)
        #expect(duplicate.visuals.backgroundRemoval == backgroundRemoval)
        #expect(duplicate.beatAnalysis == beats)

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
        #expect(restored.visuals.blendIntensity == 0.35)
        #expect(restored.visuals.mask == mask)
        #expect(restored.visuals.backgroundRemoval == backgroundRemoval)
        #expect(restored.beatAnalysis == beats)
    }

    @MainActor
    @Test func splitAndTrimOperateOnTimelineItemWithoutDroppingProperties() async throws {
        let itemID = UUID()
        let speedMap = SpeedMap(keyframes: [SpeedKeyframe(time: 0, speed: 1.25)])
        let mask = ItemMask(shape: .rectangle, feather: 0.2)
        let backgroundRemoval = BackgroundRemovalSettings(edgeRefinement: -0.1, feather: 0.25)
        let beats = AudioBeatAnalysis(
            bpm: 98,
            confidence: 0.7,
            markers: [AudioBeatMarker(sourceTime: 2.5, strength: 0.9)],
            sourceFingerprint: "split-source"
        )
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Editable",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 5),
                visuals: TimelineItemVisuals(
                    blendMode: .multiply,
                    blendIntensity: 0.42,
                    mask: mask,
                    backgroundRemoval: backgroundRemoval
                ),
                speedMap: speedMap,
                beatAnalysis: beats
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
        #expect(right.visuals.blendIntensity == 0.42)
        #expect(right.visuals.mask == mask)
        #expect(right.visuals.backgroundRemoval == backgroundRemoval)
        #expect(right.beatAnalysis == beats)

        viewModel.trimTimelineItemEnd(rightID, by: -0.2, rebuild: false)
        guard case .media(let trimmed) = try #require(viewModel.project.item(id: rightID)) else {
            Issue.record("Expected trimmed media item")
            return
        }
        #expect(trimmed.speedMap == speedMap)
        #expect(trimmed.visuals.blendMode == .multiply)
        #expect(trimmed.visuals.blendIntensity == 0.42)
        #expect(trimmed.visuals.mask == mask)
        #expect(trimmed.visuals.backgroundRemoval == backgroundRemoval)
        #expect(trimmed.beatAnalysis == beats)

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
    @Test func repeatedInteractiveSpeedSamplesClearAStaleErrorOnlyOnce() throws {
        let itemID = UUID()
        let item = TimelineItem.media(
            MediaTimelineItem(
                id: itemID,
                name: "Static speed",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 4)
            )
        )
        let project = EditorProject(
            title: "Speed error publication",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, items: [item])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(itemID, trackID: project.tracks[0].id)
        viewModel.errorMessage = "Stale error"
        let session = try #require(viewModel.beginSelectedSpeedEditAtPlayhead())

        var errorPublicationCount = 0
        let cancellable = viewModel.$errorMessage
            .dropFirst()
            .sink { _ in errorPublicationCount += 1 }

        let firstResult = viewModel.setSelectedSpeed(1, in: session, interactive: true)
        let secondResult = viewModel.setSelectedSpeed(1, in: session, interactive: true)

        #expect(firstResult)
        #expect(secondResult)
        #expect(viewModel.errorMessage == nil)
        #expect(errorPublicationCount == 1)

        viewModel.finishInteractiveEdit(rebuild: false)
        withExtendedLifetime(cancellable) {}
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

    @Test func selectedItemNavigationSharesBeatStorageWithoutCartesianDuplication() throws {
        let selectedID = UUID()
        let visualItems: [TimelineItem] = (0..<40).map { index in
            .media(
                MediaTimelineItem(
                    id: index == 0 ? selectedID : UUID(),
                    name: "Visual \(index)",
                    mediaID: MediaID(),
                    mediaType: .video,
                    timelineStart: Double(index * 2),
                    sourceRange: TimeRangeValue(start: 0, duration: 1)
                )
            )
        }
        let beatMarkers = (1...80).map { index in
            AudioBeatMarker(sourceTime: Double(index) * 0.25, strength: 1)
        }
        let audioItem = TimelineItem.media(
            MediaTimelineItem(
                name: "Beat source",
                mediaID: MediaID(),
                mediaType: .audio,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 100),
                beatAnalysis: AudioBeatAnalysis(
                    bpm: 240,
                    confidence: 1,
                    markers: beatMarkers,
                    sourceFingerprint: "shared-beat-storage"
                )
            )
        )
        let project = EditorProject(
            title: "Shared beats",
            tracks: [
                TimelineTrack(name: "Visual", kind: .visual, items: visualItems),
                TimelineTrack(name: "Audio", kind: .audio, items: [audioItem])
            ]
        )

        let index = TimelineEvaluationIndex(project: project)
        let selectedPoints = index.navigationPoints(for: selectedID)

        #expect(selectedPoints.contains(0.25))
        #expect(selectedPoints.contains(1))
        #expect(index.storedNavigationPointCount < 500)
        #expect(
            index.previousNavigationPoint(
                before: 0.76,
                tolerance: 0,
                selectedItemID: selectedID
            ) == 0.75
        )
        #expect(
            index.nextNavigationPoint(
                after: 0.76,
                tolerance: 0,
                selectedItemID: selectedID
            ) == 1
        )
    }

    @Test func generatedLayerCostUsesOnlyActiveVisualTracks() {
        let video = TimelineItem.media(
            MediaTimelineItem(
                name: "Video",
                mediaID: MediaID(),
                mediaType: .video,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 2)
            )
        )
        let shape = TimelineItem.shape(
            ShapeTimelineItem(
                name: "Shape",
                mediaID: MediaID(),
                shape: ClipShape(kind: .rectangle, color: .white, width: 100, height: 100),
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 2)
            )
        )
        let audio = TimelineItem.media(
            MediaTimelineItem(
                name: "Audio",
                mediaID: MediaID(),
                mediaType: .audio,
                timelineStart: 0,
                sourceRange: TimeRangeValue(start: 0, duration: 20),
                visuals: TimelineItemVisuals(
                    transform: ClipTransform(
                        positionX: AnimatableProperty(
                            baseValue: 0,
                            keyframes: (0..<20).map {
                                Keyframe(time: Double($0), value: Double($0))
                            }
                        )
                    )
                )
            )
        )
        let project = EditorProject(
            title: "Layer cost",
            tracks: [
                TimelineTrack(name: "Video", kind: .visual, items: [video]),
                TimelineTrack(name: "Shape", kind: .shape, items: [shape]),
                TimelineTrack(name: "Audio", kind: .audio, items: [audio])
            ]
        )

        let index = TimelineEvaluationIndex(project: project)

        #expect(index.generatedLayerCost(at: 0.5) == 4)
        #expect(index.generatedLayerCost(at: 2) == 0)
        #expect(index.generatedLayerCost(at: 10) == 0)
    }

    @Test func timelineSnapshotFindsLongOverlapsBehindEndedItems() {
        let longItem = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                name: "Long",
                timelineStart: 0,
                duration: 100
            )
        )
        let endedItem = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                name: "Ended",
                timelineStart: 50,
                duration: 1
            )
        )
        let track = TimelineTrack(
            name: "Overlaps",
            kind: .visual,
            items: [longItem, endedItem]
        )
        let trackSnapshot = TimelineRenderTrackSnapshot(track: track)
        let snapshot = TimelineRenderSnapshot(
            revision: 0,
            tracks: [track],
            trackSnapshotsByID: [track.id: trackSnapshot],
            selectedClipID: nil,
            duration: 100,
            keyframeTolerance: 0.001
        )

        let visible = snapshot.items(in: track.id, intersecting: 70...71)

        #expect(visible.map(\.id) == [longItem.id])
    }

    @Test func timelineSnapshotRetainsOffscreenItemsThroughTrackIndex() {
        let visibleItem = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                name: "Visible",
                timelineStart: 0,
                duration: 1
            )
        )
        let retainedItem = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                name: "Retained",
                timelineStart: 100,
                duration: 1
            )
        )
        let foreignItem = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                name: "Foreign",
                timelineStart: 200,
                duration: 1
            )
        )
        let track = TimelineTrack(
            name: "Indexed",
            kind: .visual,
            items: [retainedItem, visibleItem]
        )
        let foreignTrack = TimelineTrack(
            name: "Foreign",
            kind: .visual,
            items: [foreignItem]
        )
        let trackSnapshot = TimelineRenderTrackSnapshot(track: track)
        let foreignTrackSnapshot = TimelineRenderTrackSnapshot(track: foreignTrack)
        let snapshot = TimelineRenderSnapshot(
            revision: 0,
            tracks: [track, foreignTrack],
            trackSnapshotsByID: [
                track.id: trackSnapshot,
                foreignTrack.id: foreignTrackSnapshot
            ],
            selectedClipID: retainedItem.id,
            duration: 201,
            keyframeTolerance: 0.001
        )

        #expect(trackSnapshot.item(withID: retainedItem.id)?.id == retainedItem.id)
        #expect(trackSnapshot.item(withID: foreignItem.id) == nil)

        let visible = snapshot.items(
            in: track.id,
            intersecting: 0...1,
            retaining: [visibleItem.id, retainedItem.id, foreignItem.id]
        )

        #expect(visible.map(\.id) == [visibleItem.id, retainedItem.id])
    }

    @Test func timelineInvalidationRangeCoversOnlyChangedItems() {
        let changed = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                timelineStart: 0,
                duration: 1
            )
        )
        let untouched = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                timelineStart: 100,
                duration: 10
            )
        )
        let previousTrack = TimelineTrack(
            name: "Adjustment",
            kind: .visual,
            items: [changed, untouched]
        )
        var currentTrack = previousTrack
        currentTrack.items[0].timelineStart = 2

        let scope = TimelineInvalidationScope.comparing(
            previous: [previousTrack],
            current: [currentTrack]
        )

        #expect(scope.affectedTrackIDs == [previousTrack.id])
        #expect(scope.affectedTimeRange == 0...3)
        #expect(!scope.isStructural)
    }

    @Test func layoutSynchronizationNeverOverridesPlaybackOrGestures() {
        #expect(
            TimelineScrollSynchronizationPolicy.shouldSynchronizeOnLayout(
                isPlaying: false,
                isUserInteracting: false
            )
        )
        #expect(
            !TimelineScrollSynchronizationPolicy.shouldSynchronizeOnLayout(
                isPlaying: true,
                isUserInteracting: false
            )
        )
        #expect(
            !TimelineScrollSynchronizationPolicy.shouldSynchronizeOnLayout(
                isPlaying: false,
                isUserInteracting: true
            )
        )
    }

    @MainActor
    @Test func unchangedKeyframeSelectionDoesNotRepublishRootEditorState() {
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject.empty(title: "State fan-out")
            )
        )
        var publicationCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            publicationCount += 1
        }

        viewModel.activeKeyframeTarget = .positionX
        let afterTargetSelection = publicationCount
        viewModel.activeKeyframeTarget = .positionX
        #expect(publicationCount == afterTargetSelection)

        let keyframeID = UUID()
        viewModel.selectedKeyframeID = keyframeID
        let afterKeyframeSelection = publicationCount
        viewModel.selectedKeyframeID = keyframeID
        #expect(publicationCount == afterKeyframeSelection)

        let segment = KeyframeSegment(
            clipID: UUID(),
            section: .transform,
            effectID: nil,
            startTime: 0,
            endTime: 1,
            interpolation: .linear
        )
        viewModel.graphSegment = segment
        let afterGraphSelection = publicationCount
        viewModel.graphSegment = segment
        #expect(publicationCount == afterGraphSelection)

        viewModel.displayedGraphSegment = segment
        let afterDisplayedGraphSelection = publicationCount
        viewModel.displayedGraphSegment = segment
        #expect(publicationCount == afterDisplayedGraphSelection)

        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    @Test func interactiveTrimInvalidatesNavigationIndexAndTimelineSnapshot() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Interactive trim",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/interactive-trim.mov"),
                mediaType: .video,
                originalDuration: 8
            ),
            timelineStart: 2,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let project = EditorProject(
            title: "Interactive trim invalidation",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)
        let initialRevision = viewModel.timelineRenderSnapshot.revision
        #expect(viewModel.navigationPoints == [2, 6])

        let result = viewModel.trimClipStart(
            clipID,
            by: 1,
            rebuild: false,
            interactive: true
        )
        viewModel.finishInteractiveEdit(rebuild: false)

        #expect(result?.edgeTime == 3)
        #expect(viewModel.navigationPoints == [3, 6])
        #expect(viewModel.timelineRenderSnapshot.revision > initialRevision)
        let committedTimelineStart = viewModel.timelineRenderSnapshot
            .trackSnapshotsByID[project.tracks[0].id]?
            .items.first?.timelineStart
        #expect(committedTimelineStart == 3)
    }

    @MainActor
    @Test func inspectorSamplesPublishOnlyPreviewCanvasLeafState() {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Canvas leaf",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/canvas-leaf.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Canvas leaf",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer {
            viewModel.cancelInteractivePreviewRebuild()
            viewModel.finishInteractiveEdit(rebuild: false)
        }
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)
        viewModel.activeKeyframeTarget = .opacity

        var rootPublicationCount = 0
        var canvasPublicationCount = 0
        let rootCancellable = viewModel.objectWillChange.sink {
            rootPublicationCount += 1
        }
        let canvasCancellable = viewModel.previewCanvasState.objectWillChange.sink {
            canvasPublicationCount += 1
        }
        let initialCanvasRevision = viewModel.previewCanvasState.visualRevision

        viewModel.setSelectedKeyframeValue(
            0.7,
            target: .opacity,
            interactive: true
        )
        viewModel.setSelectedKeyframeValue(
            0.4,
            target: .opacity,
            interactive: true
        )

        #expect(rootPublicationCount == 0)
        #expect(canvasPublicationCount == 2)
        #expect(viewModel.previewCanvasState.visualRevision == initialCanvasRevision + 2)
        withExtendedLifetime((rootCancellable, canvasCancellable)) {}
    }

    @MainActor
    @Test func silentInspectorMutationStillRefreshesTimelineValueSnapshot() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Silent snapshot",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/silent-snapshot.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Silent snapshot",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        let timelineRevision = viewModel.timelineContentRevision
        _ = viewModel.timelineRenderSnapshot

        viewModel.mutateProject(
            rebuild: false,
            recordHistory: false,
            persistChanges: false,
            touchUpdatedAt: false,
            refreshTimeline: false
        ) { project in
            var item = project.item(id: clipID)
            var visuals = item?.editableVisuals
            visuals?.blendIntensity = 0.23
            item?.editableVisuals = visuals
            if let item {
                project.replaceItem(id: clipID, with: item)
            }
        }

        let refreshedItem = try #require(
            viewModel.timelineRenderSnapshot.tracks.first?.items.first
        )
        #expect(refreshedItem.editableVisuals?.blendIntensity == 0.23)
        #expect(viewModel.timelineContentRevision == timelineRevision)
    }

    @MainActor
    @Test func transientTrackMutationInvalidatesOnceAndRepeatedSampleIsANoOp() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Scoped dirty track",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/scoped-dirty-track.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Scoped dirty track",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer { viewModel.stop() }
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)
        viewModel.beginInteractiveEdit()

        var rootPublicationCount = 0
        var canvasPublicationCount = 0
        let rootCancellable = viewModel.objectWillChange.sink {
            rootPublicationCount += 1
        }
        let canvasCancellable = viewModel.previewCanvasState.objectWillChange.sink {
            canvasPublicationCount += 1
        }

        func applyBlendIntensitySample() {
            viewModel.mutateProject(
                rebuild: false,
                recordHistory: false,
                persistChanges: false,
                touchUpdatedAt: false,
                refreshTimeline: false
            ) { project in
                guard var item = project.item(id: clipID),
                    var visuals = item.editableVisuals
                else { return }
                visuals.blendIntensity = 0.4
                item.editableVisuals = visuals
                project.replaceItem(id: clipID, with: item)
            }
        }

        applyBlendIntensitySample()
        applyBlendIntensitySample()

        #expect(rootPublicationCount == 0)
        #expect(canvasPublicationCount == 1)
        #expect(
            viewModel.project.item(id: clipID)?.editableVisuals?.blendIntensity
                == 0.4
        )

        viewModel.finishInteractiveEdit(rebuild: false)
        #expect(viewModel.undoStack.count == 1)
        withExtendedLifetime((rootCancellable, canvasCancellable)) {}
    }

    @MainActor
    @Test func transientMetadataOnlyMutationPreservesDirtyAndUndoSemantics() {
        let originalTitle = "Metadata before"
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject.empty(title: originalTitle)
            )
        )
        defer { viewModel.stop() }
        viewModel.beginInteractiveEdit()
        let initialCanvasRevision = viewModel.previewCanvasState.visualRevision

        var rootPublicationCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            rootPublicationCount += 1
        }

        viewModel.mutateProject(
            rebuild: false,
            recordHistory: false,
            persistChanges: false,
            touchUpdatedAt: false,
            refreshTimeline: false
        ) { project in
            project.title = "Metadata after"
        }

        #expect(viewModel.project.title == "Metadata after")
        #expect(rootPublicationCount == 0)
        #expect(viewModel.previewCanvasState.visualRevision == initialCanvasRevision)

        viewModel.finishInteractiveEdit(rebuild: false)
        #expect(viewModel.undoStack.count == 1)
        viewModel.undo()
        #expect(viewModel.project.title == originalTitle)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    @Test func externalCommandClosesInteractiveUndoBoundary() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Undo boundary",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/undo-boundary.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let originalTitle = "Undo boundary"
        let project = EditorProject(
            title: originalTitle,
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)

        viewModel.setSelectedKeyframeValue(
            0.35,
            target: .opacity,
            interactive: true
        )
        viewModel.mutateProject(rebuild: false) {
            $0.title = "External command"
        }

        #expect(viewModel.undoStack.count == 2)
        viewModel.undo()
        #expect(viewModel.project.title == originalTitle)
        #expect(viewModel.project.item(id: clipID)?.editableVisuals?.transform.opacity.baseValue == 0.35)

        viewModel.undo()
        #expect(viewModel.project.item(id: clipID)?.editableVisuals?.transform.opacity.baseValue == 1)
    }

    @MainActor
    @Test func undoDuringGestureCommitsThenRevertsOnlyThatGesture() {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Gesture undo",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/gesture-undo.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Gesture undo",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)
        viewModel.setSelectedKeyframeValue(
            0.3,
            target: .opacity,
            interactive: true
        )

        viewModel.undo()

        #expect(viewModel.interactiveEditSnapshot == nil)
        #expect(viewModel.project.item(id: clipID)?.editableVisuals?.transform.opacity.baseValue == 1)
        #expect(viewModel.undoStack.isEmpty)
        #expect(viewModel.redoStack.count == 1)

        viewModel.finishInteractiveEdit(rebuild: false)
        #expect(viewModel.redoStack.count == 1)
    }

    @MainActor
    @Test func derivedDataRebasesInteractiveUndoSnapshot() {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Derived rebase",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/derived-rebase.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Before derived data",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: project.tracks[0].id)
        viewModel.setSelectedKeyframeValue(
            0.45,
            target: .opacity,
            interactive: true
        )

        viewModel.mutateDerivedProjectData(persistChanges: false) {
            $0.title = "Derived data"
        }
        viewModel.finishInteractiveEdit(rebuild: false)
        viewModel.undo()

        #expect(viewModel.project.title == "Derived data")
        #expect(viewModel.project.item(id: clipID)?.editableVisuals?.transform.opacity.baseValue == 1)
    }

    @MainActor
    @Test func undoClampsPlayheadSynchronouslyToRestoredDuration() {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Duration",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/duration.mov"),
                mediaType: .video,
                originalDuration: 10
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Duration clamp",
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        defer { viewModel.stop() }

        viewModel.mutateProject(rebuild: false) { project in
            guard case .media(var item) = project.item(id: clipID) else { return }
            item.sourceRange.duration = 8
            project.replaceItem(id: clipID, with: .media(item))
        }
        viewModel.seek(to: 7)
        #expect(viewModel.currentTime == 7)

        viewModel.undo()

        #expect(viewModel.duration == 2)
        #expect(viewModel.currentTime == 2)
    }
}
