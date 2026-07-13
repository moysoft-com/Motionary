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

    @Test func mediaLibraryRemainsAuthoritativeForSharedClips() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/original.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let first = TimelineClip(
            name: "First",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var second = first
        second.id = UUID()
        second.name = "Second"
        second.timelineStart = 2
        var project = EditorProject(
            title: "Shared",
            tracks: [TimelineTrack(name: "Layer", kind: .visual, clips: [first, second])]
        )

        var relinked = source
        relinked.url = URL(fileURLWithPath: "/tmp/relinked.mov")
        project.updateMediaAsset(first.mediaID, source: relinked)
        project.synchronizeMediaLibrary()

        #expect(project.tracks[0].clips.allSatisfy { project.mediaURL(for: $0) == relinked.url })
        #expect(project.mediaLibrary[first.mediaID]?.url == relinked.url)
    }

    @Test func projectDeltaRestoresStructuralChangesWithoutProjectSnapshots() async throws {
        let before = EditorProject.empty(title: "Before")
        var after = before
        after.tracks.append(TimelineTrack(name: "Audio 1", kind: .audio))
        let command = ProjectDeltaCommand(
            delta: ProjectDelta(from: before, to: after),
            invalidation: [.compositionTopology]
        )
        var project = before

        command.apply(to: &project)
        #expect(project.tracks.count == 2)

        command.undo(on: &project)
        #expect(project.tracks == before.tracks)
    }

    @Test func repositoryFallsBackToLastValidBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let projectID = UUID()
        let first = ProjectContent(editorProject: EditorProject.empty(title: "First"))
        let second = ProjectContent(editorProject: EditorProject.empty(title: "Second"))

        try await repository.save(first, projectID: projectID)
        try await repository.save(second, projectID: projectID)
        let primaryURL = root
            .appendingPathComponent("project_\(projectID.uuidString)")
            .appendingPathComponent("content.json")
        try Data("invalid".utf8).write(to: primaryURL, options: [.atomic])

        let result = try await repository.load(projectID: projectID)

        #expect(result.source == .backup)
        #expect(result.content.editorProject.title == "First")
    }

    @Test func timelineTrackMigratesLegacyClipsIntoItems() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let clip = TimelineClip(
            name: "Shot",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let legacyTrackJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Layer 1",
            "kind": "visual",
            "clips": \(String(data: try JSONEncoder().encode([clip]), encoding: .utf8)!),
            "isMuted": false,
            "isLocked": false
        }
        """
        let track = try JSONDecoder().decode(
            TimelineTrack.self,
            from: Data(legacyTrackJSON.utf8)
        )

        #expect(track.items.count == 1)
        #expect(track.items[0].kind == .media)
        #expect(track.clips[0].name == "Shot")
    }

    @Test func typedItemsRoundTripThroughProjectContent() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            mediaType: .video,
            originalDuration: 3
        )
        let clip = TimelineClip(
            name: "Shot",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        var project = EditorProject(
            title: "Typed",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        _ = project.appendTextItem("Hello", at: 1, duration: 2)

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.schemaVersion == 6)
        #expect(decoded.editorProject.tracks[0].items.count == 2)
        #expect(decoded.editorProject.tracks[0].items.contains { $0.kind == .text })
        #expect(decoded.editorProject.tracks[0].clips.count == 1)
    }

    @Test func speedMapStretchesTimelineDuration() async throws {
        let speedMap = SpeedMap(keyframes: [
            SpeedKeyframe(time: 0, speed: 2),
            SpeedKeyframe(time: 4, speed: 2)
        ])
        let duration = speedMap.timelineDuration(sourceDuration: 4)
        #expect(abs(duration - 2) < 0.2)
    }
}
