// Aggregate editor project and legacy migration entry point.

import CoreGraphics
import Foundation

/// Persisted aggregate containing canvas settings, tracks, clips, and migration metadata.
struct EditorProject: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 9

    var id: UUID
    var schemaVersion: Int
    var title: String
    var renderSettings: RenderSettings
    var mediaLibrary: [MediaID: MediaAsset]
    var tracks: [TimelineTrack]
    var sequences: [UUID: CompoundSequence]
    var itemLinks: [ItemLink]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case title
        case renderSettings
        case mediaLibrary
        case tracks
        case sequences
        case itemLinks
        case createdAt
        case updatedAt
    }

    var duration: Double {
        tracks
            .flatMap(\.items)
            .map(\.timelineEnd)
            .max() ?? 0
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = EditorProject.currentSchemaVersion,
        title: String,
        renderSettings: RenderSettings = RenderSettings(),
        mediaLibrary: [MediaID: MediaAsset] = [:],
        tracks: [TimelineTrack] = EditorProject.defaultTracks(),
        sequences: [UUID: CompoundSequence] = [:],
        itemLinks: [ItemLink] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.renderSettings = renderSettings
        self.mediaLibrary = mediaLibrary
        self.tracks = tracks
        self.sequences = sequences
        self.itemLinks = itemLinks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        synchronizeMediaLibrary()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        title = try container.decode(String.self, forKey: .title)
        renderSettings = try container.decodeIfPresent(RenderSettings.self, forKey: .renderSettings)
            ?? RenderSettings()
        mediaLibrary = try container.decodeIfPresent([MediaID: MediaAsset].self, forKey: .mediaLibrary) ?? [:]
        tracks = try container.decodeIfPresent([TimelineTrack].self, forKey: .tracks) ?? Self.defaultTracks()
        sequences = try container.decodeIfPresent([UUID: CompoundSequence].self, forKey: .sequences) ?? [:]
        itemLinks = try container.decodeIfPresent([ItemLink].self, forKey: .itemLinks) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        synchronizeMediaLibrary()
    }

    static func empty(title: String) -> EditorProject {
        EditorProject(title: title)
    }

    static func defaultTracks() -> [TimelineTrack] {
        [
            TimelineTrack(name: "Layer 1", kind: .visual)
        ]
    }

    mutating func synchronizeMediaLibrary() {
        separateTextTracks()

        var referencedIDs = Set<MediaID>()
        for trackIndex in tracks.indices {
            let migrationSources = tracks[trackIndex].consumePendingMigrationSources()
            for itemIndex in tracks[trackIndex].items.indices {
                guard var clip = tracks[trackIndex].items[itemIndex].legacyClip() else { continue }
                let mediaID = clip.mediaID
                var shouldRewriteItem = false

                if let migrationSource = migrationSources[mediaID] {
                    mediaLibrary[mediaID] = MediaAsset(id: mediaID, source: migrationSource)
                    clip.mediaType = migrationSource.mediaType
                    shouldRewriteItem = true
                } else if mediaLibrary[mediaID] == nil {
                    mediaLibrary[mediaID] = MediaAsset(
                        id: mediaID,
                        source: ClipSource(
                            url: URL(fileURLWithPath: clip.name),
                            mediaType: clip.mediaType,
                            originalDuration: clip.sourceRange.duration
                        )
                    )
                }

                if let asset = mediaLibrary[mediaID], clip.mediaType != asset.mediaType {
                    clip.mediaType = asset.mediaType
                    shouldRewriteItem = true
                }

                if shouldRewriteItem {
                    tracks[trackIndex].items[itemIndex] = TimelineItem.fromLegacyClip(clip)
                }
                referencedIDs.insert(mediaID)
            }
        }

        let prunedLibrary = mediaLibrary.filter { referencedIDs.contains($0.key) }
        if prunedLibrary != mediaLibrary {
            mediaLibrary = prunedLibrary
        }
        if schemaVersion != Self.currentSchemaVersion {
            schemaVersion = Self.currentSchemaVersion
        }
    }

    /// Text has its own compositing track category. Older projects could place
    /// text beside visual overlays, so split those mixed tracks while loading.
    private mutating func separateTextTracks() {
        let normalized = Self.tracksWithSeparatedText(from: tracks)
        if normalized != tracks {
            tracks = normalized
            renumberTracks()
        }

        for sequenceID in Array(sequences.keys) {
            guard var sequence = sequences[sequenceID] else { continue }
            sequence.tracks = Self.tracksWithSeparatedText(from: sequence.tracks)
            sequences[sequenceID] = sequence
        }
    }

    private static func tracksWithSeparatedText(from tracks: [TimelineTrack]) -> [TimelineTrack] {
        tracks.flatMap { originalTrack -> [TimelineTrack] in
            var track = originalTrack
            let textItems = track.items.filter {
                if case .text = $0 { return true }
                return false
            }
            guard !textItems.isEmpty else { return [track] }

            let otherItems = track.items.filter {
                if case .text = $0 { return false }
                return true
            }
            if otherItems.isEmpty {
                track.kind = .text
                return [track]
            }

            track.items = otherItems
            let textTrack = TimelineTrack(
                name: "Text",
                kind: .text,
                items: textItems,
                isMuted: originalTrack.isMuted,
                isLocked: originalTrack.isLocked
            )
            return [textTrack, track]
        }
    }

    mutating func updateMediaAsset(_ mediaID: MediaID, source: ClipSource) {
        mediaLibrary[mediaID] = MediaAsset(id: mediaID, source: source)
        for trackIndex in tracks.indices {
            for itemIndex in tracks[trackIndex].items.indices {
                guard var clip = tracks[trackIndex].items[itemIndex].legacyClip(),
                    clip.mediaID == mediaID
                else { continue }
                clip.mediaType = source.mediaType
                tracks[trackIndex].items[itemIndex] = TimelineItem.fromLegacyClip(clip)
            }
        }
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
