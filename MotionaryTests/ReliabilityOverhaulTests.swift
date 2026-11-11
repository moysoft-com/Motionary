// Source-time, animation-continuity, and stale-preview regression rules.

import AVFoundation
import Combine
import CoreImage
import Testing
import UIKit

@testable import Motionary

@Suite(.serialized)
struct ReliabilityOverhaulTests {
    @Test func compositorFallbackCannotMasqueradeAsAnotherSourceTime() throws {
        var buffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                nil, 16, 16, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        let session = UUID(), time = CMTime(value: 60, timescale: 30), size = CGSize(width: 16, height: 16)
        let fallback = MotionaryVideoCompositor.LastGoodFrame(
            pixelBuffer: frame, sessionID: session, revision: 2, time: time)
        #expect(fallback.frame(sessionID: session, revision: 2, time: time, size: size) === frame)
        #expect(
            fallback.frame(sessionID: session, revision: 2, time: CMTime(value: 61, timescale: 30), size: size) == nil)
        #expect(fallback.frame(sessionID: session, revision: 3, time: time, size: size) == nil)
        #expect(fallback.frame(sessionID: UUID(), revision: 2, time: time, size: size) == nil)
    }

    @MainActor
    @Test func scrollSamplesPublishOnlyChangedValues() {
        let state = TimelineScrollPresentationState()
        var publications = 0
        let token = state.objectWillChange.sink { publications += 1 }
        state.update(horizontalOffset: 20)
        let initial = publications
        for _ in 0..<120 { state.update(horizontalOffset: 20) }
        #expect(publications == initial)
        state.update(horizontalOffset: 21)
        #expect(publications == initial + 1)
        withExtendedLifetime(token) {}
    }

    @MainActor
    @Test func lastPlayableTimeIncludesAPartialFinalFrame() {
        for duration in [3.0, 3.01, 3.05] {
            let project = EditorProject(
                title: "Partial frame",
                tracks: [
                    TimelineTrack(
                        name: "Text", kind: .text,
                        items: [.text(TextTimelineItem(text: "A", timelineStart: 0, duration: duration))])
                ])
            let model = EditorViewModel(
                projectID: UUID(), projectStore: ProjectStore(),
                initialContent: ProjectContent(editorProject: project))
            defer { model.stop() }
            #expect(model.lastPlayableTime < duration)
            #expect(model.lastPlayableTime + 1 / 30.0 >= duration - 0.000001)
            #expect(abs(model.lastPlayableTime * 30 - (model.lastPlayableTime * 30).rounded()) < 0.000001)
        }
    }
    @Test func scrubFallbackNeverCrossesAnEditRevision() throws {
        var buffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                nil, 16, 16, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        let state = LivePreviewRenderState()
        let session = UUID()
        state.cacheFrame(frame, at: 2, sessionID: session, revision: state.snapshot().revision)
        #expect(state.cachedFrameNear(at: 2, sessionID: session, window: 1 / 30)?.frame === frame)
        state.invalidateComposedFrames()
        #expect(state.cachedFrameNear(at: 2, sessionID: session, window: 1 / 30) == nil)
        // Late GPU completions from the old edit must not repopulate either lookup.
        state.cacheFrame(frame, at: 2, sessionID: session, revision: state.snapshot().revision - 1)
        #expect(state.cachedFrame(at: 2, sessionID: session) == nil)
    }

    @MainActor
    @Test func zeroPlayheadRequestsTheFirstFrame() {
        let project = EditorProject(
            title: "Frame zero",
            tracks: [
                TimelineTrack(
                    name: "Text", kind: .text,
                    items: [.text(TextTimelineItem(text: "A", timelineStart: 0, duration: 3))])
            ])
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        #expect(model.livePreviewPresentationTime(0) == 0)
    }

    @MainActor
    @Test func trimSamplesAreMeasuredFromTheGestureBaseline() throws {
        let clip = TimelineClip(
            name: "Trim",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/trim-baseline.mov"),
                mediaType: .video, originalDuration: 30), timelineStart: 3,
            sourceRange: TimeRangeValue(start: 4, duration: 12))
        let project = EditorProject(
            title: "Trim baseline", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.selectTimelineItem(clip.id, trackID: project.tracks[0].id)
        let baseline = try #require(model.project.item(id: clip.id))
        for delta in [0.5, 1.0, 0.25] {
            _ = model.trimClipStart(
                clip.id, by: delta, baseline: baseline, snapThreshold: 0,
                rebuild: false, interactive: true)
            let actual = try #require(model.project.item(id: clip.id))
            #expect(abs(actual.timelineStart - (3 + delta)) < 0.000001)
            #expect(abs(actual.sourceRange.start - (4 + delta)) < 0.000001)
            #expect(abs(actual.timelineEnd - 15) < 0.000001)
        }
        model.finishInteractiveEdit(rebuild: false)
        model.undo()
        #expect(model.project.item(id: clip.id) == baseline)
        model.redo()
        #expect(model.project.item(id: clip.id)?.sourceRange.start == 4.25)

        let endBaseline = try #require(model.project.item(id: clip.id))
        for delta in [-0.5, -1.0, -0.25] {
            _ = model.trimClipEnd(
                clip.id, by: delta, baseline: endBaseline, snapThreshold: 0,
                rebuild: false, interactive: true)
            let actual = try #require(model.project.item(id: clip.id))
            #expect(abs(actual.timelineEnd - (15 + delta)) < 0.000001)
            #expect(actual.sourceRange.start == endBaseline.sourceRange.start)
        }
        model.finishInteractiveEdit(rebuild: false)
    }

    @Test func trimmedCurvesKeepEveryRetainedSample() {
        for interpolation in KeyframeCurvePreset.allCases.map(\.interpolation) + [
            .cubicBezier(
                control1: KeyframeControlPoint(x: 0.2, y: 0.1),
                control2: KeyframeControlPoint(x: 0.7, y: 0.95))
        ] {
            let property = AnimatableProperty(
                baseValue: 0.0,
                keyframes: [
                    Keyframe(time: 0, value: 0, interpolation: interpolation), Keyframe(time: 4, value: 1)
                ])
            let parameter = EffectParameterState(scalar: property)
            let start = property.trimmedStart(by: 1, oldDuration: 4)
            let end = property.trimmedEnd(newDuration: 3, oldDuration: 4)
            let parameterStart = parameter.trimmedStart(by: 1, oldDuration: 4)
            let parameterEnd = parameter.trimmedEnd(newDuration: 3, oldDuration: 4)
            for index in 0...60 {
                let time = Double(index) / 20
                #expect(abs(start.value(at: time) - property.value(at: time + 1)) < 0.00001)
                #expect(abs(end.value(at: time) - property.value(at: time)) < 0.00001)
                #expect(
                    abs(
                        (parameterStart.scalarProperty()?.value(at: time) ?? -1)
                            - property.value(at: time + 1)) < 0.00001)
                #expect(
                    abs(
                        (parameterEnd.scalarProperty()?.value(at: time) ?? -1)
                            - property.value(at: time)) < 0.00001)
            }
        }
    }

    @MainActor
    @Test func splitRippleDeletePreservesSourceMappingAndHistory() throws {
        for speed in [0.5, 1.0, 2.0] {
            let clip = TimelineClip(
                name: "Long source",
                source: ClipSource(
                    url: URL(fileURLWithPath: "/tmp/long-source.mov"),
                    mediaType: .video, originalDuration: 3600), timelineStart: 120,
                sourceRange: TimeRangeValue(start: 900, duration: 600))
            var project = EditorProject(
                title: "Long ripple", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
            guard case .media(var original) = project.tracks[0].items[0] else { return }
            original.speedMap = .constant(speed: speed)
            project.tracks[0].items[0] = .media(original)
            let model = EditorViewModel(
                projectID: UUID(), projectStore: ProjectStore(),
                initialContent: ProjectContent(editorProject: project))
            defer { model.stop() }
            model.selectTimelineItem(clip.id, trackID: project.tracks[0].id)
            model.seek(to: 180)
            let rightID = try #require(model.splitSelectedTimelineItem())
            let right = try #require(model.project.item(id: rightID))
            let sourceStart = 900 + 60 * speed
            #expect(right.sourceRange.start == sourceStart)
            model.isRippleEditingEnabled = true
            model.selectTimelineItem(clip.id, trackID: project.tracks[0].id)
            model.deleteSelectedClip()
            let moved = try #require(model.project.item(id: rightID))
            #expect(moved.timelineStart == 120)
            #expect(moved.sourceRange == right.sourceRange)
            #expect(moved.placementDuration == right.placementDuration)
            model.undo()
            #expect(model.project.item(id: rightID) == right)
            model.redo()
            #expect(model.project.item(id: rightID) == moved)
        }
    }
}
