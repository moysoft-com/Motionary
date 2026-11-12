import Foundation
import Testing

@testable import Motionary

struct TimeRemapTests {
    @Test func addingAnAnchorAndSlicingPreserveAnEasedCurve() throws {
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 2))
        remap.setInterpolation(KeyframeCurvePreset.easeInOut.interpolation, at: 0)
        let original = remap
        remap.toggleKeyframe(at: 0.7, tolerance: 0.001)

        let sourceStart = remap.sourceTime(at: 0.3)
        let sourceEnd = remap.sourceTime(at: 1.4)
        let slice = remap.sliced(fromTimelineTime: 0.3, duration: 1.1)
        #expect(abs(slice.duration - 1.1) < 0.000_01)
        #expect(abs((slice.keyframes.first?.value ?? 0) - sourceStart) < 0.000_01)
        #expect(abs((slice.keyframes.last?.value ?? 0) - sourceEnd) < 0.000_01)
        for time in stride(from: 0.35, to: 1.4, by: 0.05) {
            let expected = original.sourceTime(at: time)
            #expect(abs(remap.sourceTime(at: time) - expected) < 0.000_01)
            #expect(abs(remap.timelineTime(at: expected) - time) < 0.000_01)
            #expect(abs(slice.sourceTime(at: time - 0.3) - expected) < 0.000_01)
        }
    }

    @Test func remapPersistsAndLegacyPayloadsStayConstant() throws {
        let oldData = Data(#"{"keyframes":[{"time":0,"speed":2},{"time":1,"speed":0.5}]}"#.utf8)
        var map = try JSONDecoder().decode(SpeedMap.self, from: oldData)
        #expect(map == .constant(speed: 2))

        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 2))
        remap.setSourceTime(2.5, at: 0.8, tolerance: 0.01)
        remap.setInterpolation(KeyframeCurvePreset.easeIn.interpolation, at: 0.8)
        map.timeRemap = remap
        let decoded = try JSONDecoder().decode(SpeedMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(decoded.sourceTime(at: 0.8, sourceDuration: 4) == 2.5)
    }

    @MainActor
    @Test func modeSwitchCarriesSpeedAndSourceTimeEditsKeepTimelinePlacement() throws {
        let clip = MediaTimelineItem(
            name: "Retimed", mediaID: MediaID(), mediaType: .audio, timelineStart: 1,
            sourceRange: TimeRangeValue(start: 0.5, duration: 4),
            speedMap: .constant(speed: 2), pitchFollowsSpeed: true)
        let next = MediaTimelineItem(
            name: "Next", mediaID: MediaID(), mediaType: .audio, timelineStart: 3.5,
            sourceRange: TimeRangeValue(start: 0, duration: 1))
        let track = TimelineTrack(name: "Audio", kind: .audio, items: [.media(clip), .media(next)])
        let project = EditorProject(title: "Remap", tracks: [track])
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(), initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.selectTimelineItem(clip.id, trackID: track.id)
        model.seek(to: 2)
        model.setSelectedTimeRemapEnabled(true)

        let seeded = try #require(model.selectedTimelineItem)
        #expect(seeded.keyframeTimes(in: .speed) == [0, 2])
        #expect(seeded.timelineEnd == clip.timelineEnd)
        #expect(model.currentTime == 2)
        let sourceEdit = try #require(model.beginSelectedTimeRemapEdit(itemID: clip.id))
        model.setSelectedRemappedSourceTime(3, in: sourceEdit)
        model.finishInteractiveEdit()
        #expect(model.selectedTimelineItem?.keyframeTimes(in: .speed) == [0, 1, 2])
        #expect(model.currentTime == 2)
        let graph = try #require(model.candidateGraphSegment(in: .speed))
        #expect(graph.startTime == 1)
        model.openCandidateGraphSegment(in: .speed)
        let curve = KeyframeCurvePreset.easeOut.interpolation
        model.setInterpolation(curve, section: .speed, startTime: graph.startTime, interactive: true)
        model.finishInteractiveEdit()
        model.refreshGraphSegment()
        #expect(model.graphSegment?.interpolation == curve)

        model.isRippleEditingEnabled = true
        model.seek(to: 1)
        let reverse = try #require(model.beginSelectedTimeRemapEdit(itemID: clip.id))
        model.setSelectedRemappedSourceTime(4, in: reverse)
        model.finishInteractiveEdit()
        #expect(model.selectedTimelineItem?.timelineEnd == 3)
        #expect(model.project.item(id: next.id)?.timelineStart == 3.5)
        guard case .media(let reversed) = model.selectedTimelineItem else {
            Issue.record("Expected reversed media")
            return
        }
        #expect(reversed.speedMap.timeRemap?.hasReverse == true)
        model.undo()
        #expect(model.selectedTimelineItem?.timelineEnd == 3)
        #expect(model.project.item(id: next.id)?.timelineStart == 3.5)
        model.setSelectedTimeRemapEnabled(false)
        guard case .media(let constant) = model.selectedTimelineItem else {
            Issue.record("Expected a media clip")
            return
        }
        #expect(constant.pitchFollowsSpeed)
        #expect(constant.timelineEnd == 3)
        #expect(constant.speedMap.timeRemap == nil)
    }
    @Test func reversedAndHeldFramesSurviveSplittingAndTrimming() throws {
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 2))
        remap.setSourceTime(4, at: 0, tolerance: 0.001)
        remap.setSourceTime(1, at: 1, tolerance: 0.001)
        remap.setSourceTime(1, at: 2, tolerance: 0.001)
        #expect(remap.sourceTime(at: 0.5) == 2.5)
        #expect(remap.sourceTime(at: 1.5) == 1)
        let slice = remap.sliced(fromTimelineTime: 0.5, duration: 1)
        #expect(slice.sourceTime(at: 0) == 2.5)
        #expect(slice.sourceTime(at: 0.5) == 1)
        #expect(slice.sourceTime(at: 1) == 1)
        let extended = remap.sliced(fromTimelineTime: -0.5, duration: 3)
        #expect(extended.sourceTime(at: 0.25) == 4)
        #expect(extended.sourceTime(at: 1) == 2.5)
        #expect(extended.sourceTime(at: 2.75) == 1)
    }

    @MainActor
    @Test func timelineScrubCanLandOnAuthoredEndWithoutRequestingAnInvalidFrame() {
        let item = MediaTimelineItem(
            name: "Clip", mediaID: MediaID(), mediaType: .video, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2))
        let project = EditorProject(
            title: "End",
            tracks: [
                TimelineTrack(name: "Video", kind: .visual, items: [.media(item)])
            ])
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(), initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.beginScrub()
        model.updateScrub(to: model.duration)
        #expect(model.currentTime == model.duration)
        #expect(model.currentScrubPresentationTime() == model.lastPlayableTime)
        model.endScrub(at: model.duration)
        #expect(model.currentTime == model.duration)
        #expect(!model.isScrubbing)
    }

    @Test func removingBothAnchorsKeepsAFrameAndAllowsExtension() throws {
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 2))
        remap.toggleKeyframe(at: 0, tolerance: 0.001)
        #expect(remap.keyframes.count == 1)
        #expect(remap.sourceTime(at: 0.5) == 4)
        remap.toggleKeyframe(at: 2, tolerance: 0.001)
        #expect(remap.keyframes.isEmpty)
        remap.setSourceTime(1.5, at: 1, tolerance: 0.001)
        #expect(remap.sourceTime(at: 0) == 1.5)
        let extended = remap.sliced(fromTimelineTime: 0, duration: 10)
        #expect(extended.duration == 10)
        #expect(extended.keyframes.isEmpty)
        #expect(extended.sourceTime(at: 9) == 1.5)
        let decoded = try JSONDecoder().decode(TimeRemap.self, from: JSONEncoder().encode(extended))
        #expect(decoded == extended)
        remap.toggleKeyframe(at: 1, tolerance: 0.001)
        #expect(remap.keyframes.count == 1)
        #expect(remap.sourceTime(at: 0) == 1.5)
    }

    @MainActor
    @Test func disablingRemapRestoresOriginalSpeedAfterExtension() throws {
        let clip = MediaTimelineItem(
            name: "Clip", mediaID: MediaID(), mediaType: .video, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4), speedMap: .constant(speed: 2))
        let track = TimelineTrack(name: "Video", kind: .visual, items: [.media(clip)])
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(title: "Remap", tracks: [track])))
        defer { model.stop() }
        model.selectTimelineItem(clip.id, trackID: track.id)
        model.setSelectedTimeRemapEnabled(true)
        _ = model.trimClipEnd(clip.id, by: 3, snapThreshold: 0)
        #expect(model.selectedTimelineItem?.placementDuration == 5)
        model.setSelectedTimeRemapEnabled(false)
        #expect(model.selectedTimelineItem?.placementDuration == 2)
        guard case .media(let restored) = model.selectedTimelineItem else {
            Issue.record("Expected media")
            return
        }
        #expect(restored.speedMap.constantSpeed == 2)
        model.undo()
        #expect(model.selectedTimelineItem?.placementDuration == 5)
    }

}
