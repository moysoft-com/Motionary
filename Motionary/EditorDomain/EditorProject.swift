// Aggregate editor project and legacy migration entry point.

import CoreGraphics
import Foundation

/// Persisted aggregate containing canvas settings, tracks, clips, and migration metadata.
struct EditorProject: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 4

    var id: UUID
    var schemaVersion: Int
    var title: String
    var renderSettings: RenderSettings
    var tracks: [TimelineTrack]
    var createdAt: Date
    var updatedAt: Date

    var duration: Double {
        tracks
            .flatMap(\.clips)
            .map(\.timelineEnd)
            .max() ?? 0
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = EditorProject.currentSchemaVersion,
        title: String,
        renderSettings: RenderSettings = RenderSettings(),
        tracks: [TimelineTrack] = EditorProject.defaultTracks(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.renderSettings = renderSettings
        self.tracks = tracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func empty(title: String) -> EditorProject {
        EditorProject(title: title)
    }

    static func defaultTracks() -> [TimelineTrack] {
        [
            TimelineTrack(name: "Layer 1", kind: .visual)
        ]
    }

    static func migratingLegacy(
        title: String, clips: [Clip], keyframes: [Keyframe<Double>], selectedEffect: VideoEffect,
        effectIntensity: Double
    ) -> EditorProject {
        var timelineStart = 0.0
        var visualClips: [TimelineClip] = []
        var audioClips: [TimelineClip] = []

        for legacyClip in clips {
            let duration = max(legacyClip.endTime - legacyClip.startTime, 0)
            let mediaType: ClipMediaType = legacyClip.mediaType == .audio ? .audio : .video
            let source = ClipSource(
                url: legacyClip.sourceURL,
                mediaType: mediaType,
                originalDuration: legacyClip.endTime,
                naturalSize: nil
            )

            var stack = EffectStack()
            if mediaType != .audio, let kind = selectedEffect.effectKind {
                let localKeyframes =
                    keyframes
                    .filter { $0.time >= timelineStart && $0.time <= timelineStart + duration }
                    .map { Keyframe<Double>(id: $0.id, time: $0.time - timelineStart, value: $0.value) }
                stack.effects = [
                    ClipEffect(
                        kind: kind, intensity: AnimatableProperty(baseValue: effectIntensity, keyframes: localKeyframes)
                    )
                ]
            }

            let clip = TimelineClip(
                name: legacyClip.sourceURL.deletingPathExtension().lastPathComponent,
                source: source,
                timelineStart: mediaType == .audio ? 0 : timelineStart,
                sourceRange: TimeRangeValue(start: legacyClip.startTime, duration: duration),
                effectStack: stack
            )

            if mediaType == .audio {
                audioClips.append(clip)
            } else {
                visualClips.append(clip)
                timelineStart += duration
            }
        }

        var tracks = [TimelineTrack(name: "Layer 1", kind: .visual, clips: visualClips)]
        if !audioClips.isEmpty {
            tracks.append(TimelineTrack(name: "Audio 1", kind: .audio, clips: audioClips))
        }

        return EditorProject(title: title, tracks: tracks)
    }
}
