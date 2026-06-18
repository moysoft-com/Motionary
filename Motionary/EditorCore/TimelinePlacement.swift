// Pure project-level operations for locating, placing, snapping, and ordering timeline content.

import Foundation

extension EditorProject {
    func clip(id: UUID) -> TimelineClip? {
        tracks.flatMap(\.clips).first { $0.id == id }
    }

    func clipLocation(id: UUID) -> (track: Int, clip: Int)? {
        for trackIndex in tracks.indices {
            if let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    mutating func resolveClipPlacement(
        _ clipID: UUID,
        proposedStart: Double,
        proposedTrackIndex: Int,
        currentTime: Double
    ) -> TimelinePlacementResult? {
        guard let location = clipLocation(id: clipID) else { return nil }
        let clip = tracks[location.track].clips.remove(at: location.clip)
        let requiredKind = clip.requiredTrackKind
        let destinationIndex = compatibleTrackIndex(
            proposedIndex: proposedTrackIndex,
            requiredKind: requiredKind,
            sourceIndex: location.track
        )
        adoptTrackKindIfNeeded(at: destinationIndex, requiredKind: requiredKind)
        let placement = resolvedPlacement(
            proposedStart: proposedStart,
            duration: clip.sourceRange.duration,
            destinationTrackIndex: destinationIndex,
            requiredKind: requiredKind,
            snapAnchors: [currentTime]
        )
        return TimelinePlacementResult(
            start: placement.start,
            trackIndex: destinationIndex,
            snapped: placement.snapped,
            snapTime: placement.snapTime
        )
    }

    mutating func placeClip(
        _ clipID: UUID,
        using placement: TimelinePlacementResult
    ) -> TimelinePlacementResult? {
        guard let location = clipLocation(id: clipID) else { return nil }
        var clip = tracks[location.track].clips.remove(at: location.clip)
        let requiredKind = clip.requiredTrackKind
        let destinationIndex = compatibleTrackIndex(
            proposedIndex: placement.trackIndex,
            requiredKind: requiredKind,
            sourceIndex: location.track
        )
        adoptTrackKindIfNeeded(at: destinationIndex, requiredKind: requiredKind)
        clip.timelineStart = placement.start
        tracks[destinationIndex].clips.append(clip)
        tracks[destinationIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        renumberTracks()
        return TimelinePlacementResult(
            start: clip.timelineStart,
            trackIndex: clipLocation(id: clip.id)?.track ?? destinationIndex,
            snapped: placement.snapped,
            snapTime: placement.snapTime
        )
    }

    mutating func insertFreshTrack(kind: TrackKind) -> Int {
        if kind != .undefined,
            let undefinedIndex = tracks.firstIndex(where: { $0.kind == .undefined && $0.clips.isEmpty })
        {
            tracks[undefinedIndex].kind = kind
            return undefinedIndex
        }

        let hasClipsInKind = tracks.contains { $0.kind == kind && !$0.clips.isEmpty }
        if !hasClipsInKind, let emptyIndex = tracks.firstIndex(where: { $0.kind == kind && $0.clips.isEmpty }) {
            return emptyIndex
        }

        switch kind {
        case .undefined:
            tracks.insert(TimelineTrack(name: "Layer", kind: .undefined), at: 0)
            return 0
        case .visual:
            let insertionIndex = tracks.firstIndex(where: { $0.kind == .visual }) ?? 0
            tracks.insert(TimelineTrack(name: nextTrackName(for: kind), kind: kind), at: insertionIndex)
            return insertionIndex
        case .audio:
            tracks.append(TimelineTrack(name: nextTrackName(for: kind), kind: kind))
            return tracks.count - 1
        }
    }

    mutating func compatibleTrackIndex(
        proposedIndex: Int,
        requiredKind: TrackKind,
        sourceIndex: Int? = nil
    ) -> Int {
        if tracks.indices.contains(proposedIndex),
            tracks[proposedIndex].canAcceptClipKind(requiredKind)
        {
            return proposedIndex
        }

        let matching = tracks.indices.filter { tracks[$0].canAcceptClipKind(requiredKind) }
        if let nearest = matching.min(by: { left, right in
            let leftDistance = abs(left - proposedIndex)
            let rightDistance = abs(right - proposedIndex)
            guard leftDistance == rightDistance, let sourceIndex else {
                return leftDistance < rightDistance
            }

            let direction = proposedIndex - sourceIndex
            if direction > 0 {
                return left > sourceIndex && right <= sourceIndex
            }
            if direction < 0 {
                return left < sourceIndex && right >= sourceIndex
            }
            return abs(left - sourceIndex) < abs(right - sourceIndex)
        }) {
            return nearest
        }

        return min(max(proposedIndex, 0), max(tracks.count - 1, 0))
    }

    mutating func adoptTrackKindIfNeeded(at index: Int, requiredKind: TrackKind) {
        guard tracks.indices.contains(index), tracks[index].kind == .undefined else { return }
        tracks[index].kind = requiredKind
    }

    mutating func renumberTracks() {
        var visualIndex = 1
        var audioIndex = 1
        for index in tracks.indices {
            switch tracks[index].kind {
            case .undefined:
                tracks[index].name = "Layer"
            case .visual:
                tracks[index].name = "Layer \(visualIndex)"
                visualIndex += 1
            case .audio:
                tracks[index].name = "Audio \(audioIndex)"
                audioIndex += 1
            }
        }
    }

    private func nextTrackName(for kind: TrackKind) -> String {
        guard kind != .undefined else { return "Layer" }
        let count = tracks.filter { $0.kind == kind }.count + 1
        return kind == .visual ? "Layer \(count)" : "Audio \(count)"
    }

    func resolvedPlacementStart(
        proposedStart: Double,
        duration: Double,
        destinationTrackIndex: Int,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> Double {
        resolvedPlacement(
            proposedStart: proposedStart,
            duration: duration,
            destinationTrackIndex: destinationTrackIndex,
            requiredKind: requiredKind,
            snapThreshold: snapThreshold,
            snapAnchors: snapAnchors
        ).start
    }

    func resolvedPlacement(
        proposedStart: Double,
        duration: Double,
        destinationTrackIndex: Int,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> (start: Double, snapped: Bool, snapTime: Double?) {
        let safeDuration = max(duration, 0.001)
        let baseStart = max(0, proposedStart)
        let baseEnd = baseStart + safeDuration
        var candidate = baseStart
        var snapped = false
        var snapTime: Double?

        let compatibleClips = tracks.flatMap(\.clips)

        var bestDistance = snapThreshold
        let anchors = (snapAnchors + compatibleClips.flatMap { [$0.timelineStart, $0.timelineEnd] })
            .filter { $0.isFinite }

        for anchor in anchors {
            let startDistance = abs(baseStart - anchor)
            if startDistance < bestDistance {
                bestDistance = startDistance
                candidate = max(0, anchor)
                snapped = true
                snapTime = anchor
            }

            let endDistance = abs(baseEnd - anchor)
            if endDistance < bestDistance {
                bestDistance = endDistance
                candidate = max(0, anchor - safeDuration)
                snapped = true
                snapTime = anchor
            }
        }

        guard tracks.indices.contains(destinationTrackIndex) else {
            return (candidate, snapped, snapTime)
        }

        let clipsInDestination = tracks[destinationTrackIndex].clips
            .sorted { $0.timelineStart < $1.timelineStart }
        let nonOverlappingStart = nearestNonOverlappingStart(
            proposedStart: candidate,
            duration: safeDuration,
            clips: clipsInDestination
        )
        let alignedSnapTime = snapTime.flatMap { anchor in
            let finalEnd = nonOverlappingStart + safeDuration
            return abs(nonOverlappingStart - anchor) < 0.001 || abs(finalEnd - anchor) < 0.001
                ? anchor
                : nil
        }
        return (
            nonOverlappingStart,
            alignedSnapTime != nil || abs(nonOverlappingStart - candidate) > 0.001,
            alignedSnapTime
        )
    }

    func snappedTimelineEdge(
        _ proposedEdge: Double,
        excluding clipID: UUID,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> (time: Double, snapped: Bool) {
        let boundedEdge = max(0, proposedEdge)
        let otherClips =
            tracks
            .flatMap(\.clips)
            .filter { $0.id != clipID }
        let otherDuration = otherClips.map(\.timelineEnd).max() ?? 0
        let anchors = ([0, otherDuration] + snapAnchors + otherClips.flatMap { [$0.timelineStart, $0.timelineEnd] })
            .filter { $0.isFinite }

        guard let best = anchors.min(by: { abs($0 - boundedEdge) < abs($1 - boundedEdge) }),
            abs(best - boundedEdge) < snapThreshold
        else {
            return (boundedEdge, false)
        }

        return (max(0, best), true)
    }

    private func nearestNonOverlappingStart(proposedStart: Double, duration: Double, clips: [TimelineClip]) -> Double {
        guard !clips.isEmpty else { return max(0, proposedStart) }

        var ranges: [(start: Double, end: Double)] = []
        var cursor = 0.0

        for clip in clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if clip.timelineStart - cursor >= duration {
                ranges.append((cursor, clip.timelineStart - duration))
            }
            cursor = max(cursor, clip.timelineEnd)
        }
        ranges.append((cursor, Double.greatestFiniteMagnitude / 4))

        let boundedStart = max(0, proposedStart)
        let best =
            ranges
            .map { range -> Double in
                min(max(boundedStart, range.start), range.end)
            }
            .min { abs($0 - boundedStart) < abs($1 - boundedStart) }

        return max(0, best ?? boundedStart)
    }

    func neighborBounds(for clipID: UUID, in trackIndex: Int) -> (previousEnd: Double, nextStart: Double) {
        guard tracks.indices.contains(trackIndex),
            let clip = tracks[trackIndex].clips.first(where: { $0.id == clipID })
        else {
            return (0, Double.greatestFiniteMagnitude / 4)
        }

        let clips = tracks[trackIndex].clips.filter { $0.id != clipID }
        let previousEnd =
            clips
            .filter { $0.timelineEnd <= clip.timelineStart + 0.001 }
            .map(\.timelineEnd)
            .max() ?? 0
        let nextStart =
            clips
            .filter { $0.timelineStart >= clip.timelineEnd - 0.001 }
            .map(\.timelineStart)
            .min() ?? Double.greatestFiniteMagnitude / 4

        return (previousEnd, nextStart)
    }
}
