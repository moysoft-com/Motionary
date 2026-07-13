import Foundation
import Testing

@testable import Motionary

@Suite(.serialized)
struct PreviewRebuildTests {
    @Test func renderInvalidationDetectsVisualOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/visual.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.5)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.previewFrame))
        #expect(!invalidation.contains(.compositionTopology))
        #expect(!invalidation.contains(.audioMix))
    }

    @Test func renderInvalidationDetectsAudioOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/audio.mov"),
            mediaType: .video,
            originalDuration: 3
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        var after = before
        after.volume = AnimatableProperty(baseValue: 0.25)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.audioMix))
        #expect(!invalidation.contains(.compositionTopology))
    }

    @Test func replaceClipCommandUsesCompactUndoPayload() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/compact.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.4)
        let command = EditorCommandFactory.replaceClip(
            before: before,
            after: after,
            invalidation: [.previewFrame]
        )
        var project = EditorProject(
            title: "Compact",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [before])]
        )
        project.registerMedia(from: source, mediaID: before.mediaID)

        command.apply(to: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 0.4)

        command.undo(on: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 1)
    }

    @Test func timelineClipEncodesWithoutEmbeddedSource() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/encode.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let clip = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var project = EditorProject(
            title: "Encode",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        project.registerMedia(from: source, mediaID: clip.mediaID)
        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("\"source\""))
        #expect(json.contains("\"mediaID\""))
    }
}
