// Cached timeline clip lookups to avoid rebuilding legacy clip bridges on every frame.

import Foundation

struct TimelineRenderSnapshot: Equatable {
    let revision: Int
    let tracks: [TimelineTrack]
    let clipsByTrackID: [UUID: [TimelineClip]]
    let selectedClipID: UUID?
    let duration: Double
    let keyframeTolerance: Double
}

extension EditorViewModel {
    /// Identity used by the UIKit timeline host. Selection is presentation state,
    /// so it must refresh the hosted SwiftUI tree without invalidating clip caches.
    var timelineHostingRevision: Int {
        var hasher = Hasher()
        hasher.combine(timelineContentRevision)
        hasher.combine(selectedClipID)
        return hasher.finalize()
    }

    var timelineRenderSnapshot: TimelineRenderSnapshot {
        let token = (timelineContentRevision, selectedClipID)
        if timelineSnapshotToken.revision != token.0 || timelineSnapshotToken.selectedClipID != token.1 {
            rebuildTimelineClipCache()
            timelineSnapshot = TimelineRenderSnapshot(
                revision: timelineContentRevision,
                tracks: project.tracks,
                clipsByTrackID: timelineClipCache,
                selectedClipID: selectedClipID,
                duration: duration,
                keyframeTolerance: keyframeTimeTolerance
            )
            timelineSnapshotToken = token
        }
        return timelineSnapshot
            ?? TimelineRenderSnapshot(
                revision: timelineContentRevision,
                tracks: project.tracks,
                clipsByTrackID: [:],
                selectedClipID: selectedClipID,
                duration: duration,
                keyframeTolerance: keyframeTimeTolerance
            )
    }

    func legacyClips(for track: TimelineTrack) -> [TimelineClip] {
        if timelineClipCacheRevision != timelineContentRevision {
            rebuildTimelineClipCache()
        }
        return timelineClipCache[track.id] ?? track.clips
    }

    private func rebuildTimelineClipCache() {
        timelineClipCache = Dictionary(
            uniqueKeysWithValues: project.tracks.map { track in
                (track.id, track.items.compactMap { $0.legacyClip() })
            }
        )
        timelineClipCacheRevision = timelineContentRevision
        timelineSnapshotToken = (-1, nil)
    }
}
