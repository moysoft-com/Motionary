// Domain interpolation, migration, and coding compatibility tests.

import Foundation
import Testing

@testable import Motionary

struct DomainModelTests {
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

    @Test func legacyTransformDefaultsFlipFlagsToFalse() async throws {
        let encoded = try JSONEncoder().encode(ClipTransform())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isFlippedHorizontally")
        object.removeValue(forKey: "isFlippedVertically")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipTransform.self, from: legacyData)

        #expect(decoded.isFlippedHorizontally == false)
        #expect(decoded.isFlippedVertically == false)
    }

    @Test func transformFlipFlagsRoundTrip() async throws {
        let transform = ClipTransform(
            isFlippedHorizontally: true,
            isFlippedVertically: true
        )

        let data = try JSONEncoder().encode(transform)
        let decoded = try JSONDecoder().decode(ClipTransform.self, from: data)

        #expect(decoded == transform)
    }

    @Test func legacyRenderSettingsDefaultToPureBlackCanvas() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "width": 1080,
            "height": 1920,
            "frameRate": 30
        ])

        let settings = try JSONDecoder().decode(RenderSettings.self, from: data)

        #expect(settings.backgroundColor == .black)
    }
}
