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

    @Test func repositoryReconcilesDashboardTitleBeforeOpeningEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let projectID = UUID()
        try await repository.save(
            ProjectContent(editorProject: EditorProject.empty(title: "Project #1")),
            projectID: projectID
        )

        let reconciled = try await repository.load(
            projectID: projectID,
            preferredTitle: "Renamed project"
        )
        let reopened = try await repository.load(projectID: projectID)

        #expect(reconciled.content.editorProject.title == "Renamed project")
        #expect(reopened.content.editorProject.title == "Renamed project")
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

    @Test func legacyTimelineTrackEmbeddedSourcePopulatesMissingMediaLibrary() throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/legacy-track-source.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let clip = TimelineClip(
            name: "Legacy Shot",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let encodedClip = try JSONEncoder().encode(clip)
        var clipObject = try #require(
            JSONSerialization.jsonObject(with: encodedClip)
                as? [String: Any]
        )
        clipObject["source"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)
        )
        let legacyContent = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 5,
            "editorProject": [
                "schemaVersion": 5,
                "title": "Legacy Track",
                "tracks": [
                    [
                        "id": UUID().uuidString,
                        "name": "Layer 1",
                        "kind": "visual",
                        "clips": [clipObject],
                        "isMuted": false,
                        "isLocked": false
                    ]
                ]
            ]
        ])

        let decoded = try JSONDecoder().decode(ProjectContent.self, from: legacyContent)
        let migratedClip = try #require(decoded.editorProject.tracks.first?.clips.first)

        #expect(decoded.editorProject.mediaLibrary.count == 1)
        #expect(decoded.editorProject.mediaURL(for: migratedClip) == source.url)
        #expect(decoded.editorProject.originalDuration(for: migratedClip) == 4)
    }

    @Test func rootLegacyProjectContentPreservesClipSourceURL() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/root-legacy-source.mov")
        let legacyClip = Clip(
            sourceURL: sourceURL,
            startTime: 1,
            endTime: 6,
            mediaType: .video
        )
        let clipsObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([legacyClip])
        )
        let legacyContent = try JSONSerialization.data(withJSONObject: [
            "clips": clipsObject,
            "keyframes": [],
            "selectedEffect": VideoEffect.none.rawValue,
            "effectIntensity": 0.6
        ])

        let decoded = try JSONDecoder().decode(ProjectContent.self, from: legacyContent)
        let migratedClip = try #require(decoded.editorProject.tracks.first?.clips.first)

        #expect(decoded.editorProject.mediaLibrary.count == 1)
        #expect(decoded.editorProject.mediaURL(for: migratedClip) == sourceURL)
        #expect(decoded.editorProject.originalDuration(for: migratedClip) == 6)
    }

    @Test func textItemsRoundTripOnTheirOwnTrackKind() async throws {
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

        #expect(decoded.editorProject.schemaVersion == EditorProject.currentSchemaVersion)
        let textTrack = try #require(decoded.editorProject.tracks.first { $0.kind == .text })
        let visualTrack = try #require(decoded.editorProject.tracks.first { $0.kind == .visual })
        #expect(textTrack.items.count == 1)
        #expect(textTrack.items.allSatisfy { $0.kind == .text })
        #expect(visualTrack.clips.count == 1)
    }

    @Test func textTypeAndStyleKeyframesResolveAndPersist() throws {
        var item = TextTimelineItem(text: "Animated", timelineStart: 0, duration: 2)
        item.propertyAnimations.fontSize.keyframes = [
            Keyframe(time: 0, value: 40),
            Keyframe(time: 2, value: 80),
        ]
        item.propertyAnimations.fillColor.keyframes = [
            Keyframe(time: 0, value: .white),
            Keyframe(time: 2, value: .black),
        ]

        let decoded = try JSONDecoder().decode(
            TextTimelineItem.self,
            from: JSONEncoder().encode(item)
        )
        let midpoint = decoded.resolved(at: 1)

        #expect(midpoint.style.fontSize == 60)
        #expect(midpoint.style.color == RGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(decoded.keyframeTimes(in: .textType) == [0, 2])
        #expect(decoded.keyframeTimes(in: .textStyle) == [0, 2])
    }

    @Test func staticSpeedMapRoundTripsTimelineTime() async throws {
        let speedMap = SpeedMap.constant(speed: 2)
        let duration = speedMap.timelineDuration(sourceDuration: 4)
        #expect(abs(duration - 2) < 0.000_001)
        for sourceTime in stride(from: 0.0, through: 4.0, by: 0.125) {
            let timelineTime = speedMap.timelineTime(at: sourceTime, sourceDuration: 4)
            #expect(abs(speedMap.sourceTime(at: timelineTime, sourceDuration: 4) - sourceTime) < 0.000_001)
        }
    }

    @Test func mediaItemsCollapseLegacySpeedRampsToStaticSpeed() {
        let item = MediaTimelineItem(
            name: "Legacy ramp",
            mediaID: MediaID(),
            mediaType: .audio,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4),
            speedMap: SpeedMap(
                keyframes: [
                    SpeedKeyframe(time: 0, speed: 1.5),
                    SpeedKeyframe(time: 2, speed: 0.5),
                ]
            )
        )

        #expect(item.speedMap == .constant(speed: 1.5))
        #expect(abs(item.timelineDuration - (4 / 1.5)) < 0.000_001)
    }

    @Test func maskDecodingCanonicalizesPersistedValues() throws {
        let data = Data(
            #"{"shape":"ellipse","insetX":0.9,"insetY":-1,"feather":0.7}"#.utf8
        )
        let mask = try JSONDecoder().decode(ItemMask.self, from: data)

        #expect(mask.shape == .ellipse)
        #expect(mask.insetX == 0.48)
        #expect(mask.insetY == 0)
        #expect(mask.feather == 0.25)
    }
}
