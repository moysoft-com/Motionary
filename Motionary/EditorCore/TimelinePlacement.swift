// Pure project-level operations for locating, placing, snapping, and ordering timeline content.

import Foundation

/// Immutable indexes for one timeline-item drag. Building this once at gesture
/// start keeps project copying, item sorting, snap-anchor scans, and gap
/// construction out of the per-frame drag path.
struct TimelinePlacementDragSession {
    let itemID: UUID
    let sourceTrackIndex: Int

    private enum SnappedEdge: Int {
        case start
        case end
    }

    private struct SnapAnchor {
        let value: Double
        let ordinal: Int
    }

    private struct SnapCandidate {
        let anchor: SnapAnchor
        let edge: SnappedEdge
        let distance: Double
        let start: Double
    }

    private struct FreeRange {
        let start: Double
        let end: Double
    }

    private let duration: Double
    private let trackCount: Int
    private let compatibleTrackIndices: [Int]
    private let snapAnchors: [SnapAnchor]
    private let freeRangesByTrack: [[FreeRange]]
    private let snapTargetTracks: [Int64: [Int]]

    init?(
        project: EditorProject,
        itemID: UUID,
        currentTime: Double
    ) {
        guard let location = project.itemLocation(id: itemID) else { return nil }

        var tracks = project.tracks
        guard tracks.indices.contains(location.track),
            tracks[location.track].items.indices.contains(location.item)
        else { return nil }
        let item = tracks[location.track].items.remove(at: location.item)
        let safeDuration = max(item.placementDuration, 0.001)

        self.itemID = itemID
        sourceTrackIndex = location.track
        duration = safeDuration
        trackCount = tracks.count
        compatibleTrackIndices = tracks.indices.filter {
            tracks[$0].canAcceptItem(item)
        }
        freeRangesByTrack = tracks.map {
            Self.freeRanges(duration: safeDuration, items: $0.items)
        }

        var valuesWithOrdinal: [(value: Double, ordinal: Int)] = []
        valuesWithOrdinal.reserveCapacity(
            1 + project.tracks.reduce(0) { $0 + $1.items.count * 2 }
        )
        var ordinal = 0
        func appendAnchor(_ value: Double) {
            guard value.isFinite else { return }
            valuesWithOrdinal.append((value, ordinal))
            ordinal += 1
        }

        appendAnchor(currentTime)
        for beat in project.beatSnapAnchors(excluding: itemID) {
            appendAnchor(beat)
        }

        var targetTracks: [Int64: Set<Int>] = [:]
        for (trackIndex, track) in tracks.enumerated() {
            for remainingItem in track.items {
                appendAnchor(remainingItem.timelineStart)
                appendAnchor(remainingItem.timelineEnd)
                targetTracks[
                    Self.quantizedTime(remainingItem.timelineStart),
                    default: []
                ].insert(trackIndex)
                targetTracks[
                    Self.quantizedTime(remainingItem.timelineEnd),
                    default: []
                ].insert(trackIndex)
            }
        }

        var earliestOrdinalByValue: [Double: Int] = [:]
        for entry in valuesWithOrdinal {
            earliestOrdinalByValue[entry.value] = min(
                earliestOrdinalByValue[entry.value] ?? entry.ordinal,
                entry.ordinal
            )
        }
        snapAnchors = earliestOrdinalByValue
            .map { SnapAnchor(value: $0.key, ordinal: $0.value) }
            .sorted {
                if $0.value != $1.value {
                    return $0.value < $1.value
                }
                return $0.ordinal < $1.ordinal
            }
        snapTargetTracks = targetTracks.mapValues { $0.sorted() }
    }

    func resolve(
        proposedStart: Double,
        proposedTrackIndex: Int,
        snapThreshold: Double = 0.16
    ) -> TimelinePlacementResult {
        let destinationTrackIndex = compatibleTrackIndex(
            proposedIndex: proposedTrackIndex
        )
        let baseStart = max(0, proposedStart)
        let baseEnd = baseStart + duration
        let snapCandidate = bestSnapCandidate(
            baseStart: baseStart,
            baseEnd: baseEnd,
            threshold: snapThreshold
        )
        let candidateStart = snapCandidate?.start ?? baseStart
        let nonOverlappingStart = nearestAvailableStart(
            proposedStart: candidateStart,
            trackIndex: destinationTrackIndex
        )
        let alignedSnapTime = snapCandidate.flatMap { candidate -> Double? in
            let finalEnd = nonOverlappingStart + duration
            return abs(nonOverlappingStart - candidate.anchor.value) < 0.001
                    || abs(finalEnd - candidate.anchor.value) < 0.001
                ? candidate.anchor.value
                : nil
        }

        return TimelinePlacementResult(
            start: nonOverlappingStart,
            trackIndex: destinationTrackIndex,
            snapped: alignedSnapTime != nil
                || abs(nonOverlappingStart - candidateStart) > 0.001,
            snapTime: alignedSnapTime
        )
    }

    func trackIndices(alignedAt time: Double) -> [Int] {
        snapTargetTracks[Self.quantizedTime(time)] ?? []
    }

    private func compatibleTrackIndex(proposedIndex: Int) -> Int {
        guard !compatibleTrackIndices.isEmpty else {
            return min(max(proposedIndex, 0), max(trackCount - 1, 0))
        }
        if compatibleTrackIndices.binarySearch(proposedIndex) != nil {
            return proposedIndex
        }

        let insertion = compatibleTrackIndices.lowerBoundIndex(for: proposedIndex)
        var candidates: [Int] = []
        if compatibleTrackIndices.indices.contains(insertion) {
            candidates.append(compatibleTrackIndices[insertion])
        }
        if insertion > compatibleTrackIndices.startIndex {
            candidates.append(compatibleTrackIndices[insertion - 1])
        }
        return candidates.min { left, right in
            let leftDistance = abs(left - proposedIndex)
            let rightDistance = abs(right - proposedIndex)
            guard leftDistance == rightDistance else {
                return leftDistance < rightDistance
            }

            let direction = proposedIndex - sourceTrackIndex
            if direction > 0 {
                if (left > sourceTrackIndex) != (right > sourceTrackIndex) {
                    return left > sourceTrackIndex
                }
            } else if direction < 0 {
                if (left < sourceTrackIndex) != (right < sourceTrackIndex) {
                    return left < sourceTrackIndex
                }
            }
            return abs(left - sourceTrackIndex) < abs(right - sourceTrackIndex)
        } ?? min(max(proposedIndex, 0), max(trackCount - 1, 0))
    }

    private func bestSnapCandidate(
        baseStart: Double,
        baseEnd: Double,
        threshold: Double
    ) -> SnapCandidate? {
        let candidates = [
            nearestAnchor(to: baseStart).map {
                SnapCandidate(
                    anchor: $0,
                    edge: .start,
                    distance: abs(baseStart - $0.value),
                    start: max(0, $0.value)
                )
            },
            nearestAnchor(to: baseEnd).map {
                SnapCandidate(
                    anchor: $0,
                    edge: .end,
                    distance: abs(baseEnd - $0.value),
                    start: max(0, $0.value - duration)
                )
            },
        ]
        .compactMap { $0 }
        .filter { $0.distance < threshold }

        return candidates.min {
            if $0.distance != $1.distance {
                return $0.distance < $1.distance
            }
            if $0.anchor.ordinal != $1.anchor.ordinal {
                return $0.anchor.ordinal < $1.anchor.ordinal
            }
            return $0.edge.rawValue < $1.edge.rawValue
        }
    }

    private func nearestAnchor(to value: Double) -> SnapAnchor? {
        guard !snapAnchors.isEmpty else { return nil }
        let insertion = snapAnchors.lowerBoundIndex(for: value, by: \.value)
        var candidates: [SnapAnchor] = []
        if snapAnchors.indices.contains(insertion) {
            candidates.append(snapAnchors[insertion])
        }
        if insertion > snapAnchors.startIndex {
            candidates.append(snapAnchors[insertion - 1])
        }
        return candidates.min {
            let leftDistance = abs($0.value - value)
            let rightDistance = abs($1.value - value)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            return $0.ordinal < $1.ordinal
        }
    }

    private func nearestAvailableStart(
        proposedStart: Double,
        trackIndex: Int
    ) -> Double {
        guard freeRangesByTrack.indices.contains(trackIndex),
            !freeRangesByTrack[trackIndex].isEmpty
        else { return max(0, proposedStart) }

        let ranges = freeRangesByTrack[trackIndex]
        let boundedStart = max(0, proposedStart)
        let insertion = ranges.lowerBoundIndex(for: boundedStart, by: \.end)
        guard ranges.indices.contains(insertion) else {
            return boundedStart
        }
        let next = ranges[insertion]
        if boundedStart >= next.start {
            return boundedStart
        }
        guard insertion > ranges.startIndex else {
            return next.start
        }
        let previous = ranges[insertion - 1]
        return abs(previous.end - boundedStart) <= abs(next.start - boundedStart)
            ? previous.end
            : next.start
    }

    private static func freeRanges(
        duration: Double,
        items: [TimelineItem]
    ) -> [FreeRange] {
        guard !items.isEmpty else {
            return [FreeRange(start: 0, end: Double.greatestFiniteMagnitude / 4)]
        }

        var result: [FreeRange] = []
        result.reserveCapacity(items.count + 1)
        var cursor = 0.0
        for item in items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if item.timelineStart - cursor >= duration {
                result.append(
                    FreeRange(
                        start: cursor,
                        end: item.timelineStart - duration
                    )
                )
            }
            cursor = max(cursor, item.timelineEnd)
        }
        result.append(
            FreeRange(
                start: cursor,
                end: Double.greatestFiniteMagnitude / 4
            )
        )
        return result
    }

    private static func quantizedTime(_ value: Double) -> Int64 {
        Int64((value * 1_000_000).rounded())
    }
}

private extension RandomAccessCollection where Element == Int, Index == Int {
    func binarySearch(_ value: Int) -> Int? {
        let index = lowerBoundIndex(for: value)
        guard indices.contains(index), self[index] == value else { return nil }
        return index
    }

    func lowerBoundIndex(for value: Int) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + distance(from: lower, to: upper) / 2
            if self[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

private extension RandomAccessCollection where Index == Int {
    func lowerBoundIndex<Value: Comparable>(
        for value: Value,
        by keyPath: KeyPath<Element, Value>
    ) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + distance(from: lower, to: upper) / 2
            if self[middle][keyPath: keyPath] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

extension EditorProject {
    func clip(id: UUID) -> TimelineClip? {
        item(id: id)?.legacyClip()
    }

    func clipLocation(id: UUID) -> (track: Int, clip: Int)? {
        guard let location = itemLocation(id: id) else { return nil }
        return (location.track, location.item)
    }

    mutating func resolveClipPlacement(
        _ clipID: UUID,
        proposedStart: Double,
        proposedTrackIndex: Int,
        currentTime: Double
    ) -> TimelinePlacementResult? {
        guard let location = clipLocation(id: clipID) else { return nil }
        let beatAnchors = beatSnapAnchors(excluding: clipID)
        let item = tracks[location.track].items.remove(at: location.clip)
        let requiredKind = item.requiredTrackKind
        let destinationIndex = compatibleTrackIndex(
            proposedIndex: proposedTrackIndex,
            item: item,
            sourceIndex: location.track
        )
        adoptTrackKindIfNeeded(at: destinationIndex, requiredKind: requiredKind)
        let placement = resolvedPlacement(
            proposedStart: proposedStart,
            duration: item.placementDuration,
            destinationTrackIndex: destinationIndex,
            requiredKind: requiredKind,
            snapAnchors: [currentTime] + beatAnchors
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
        let sourceTrackID = tracks[location.track].id
        var item = tracks[location.track].items.remove(at: location.clip)
        let requiredKind = item.requiredTrackKind
        let destinationIndex = compatibleTrackIndex(
            proposedIndex: placement.trackIndex,
            item: item,
            sourceIndex: location.track
        )
        adoptTrackKindIfNeeded(at: destinationIndex, requiredKind: requiredKind)
        let destinationTrackID = tracks[destinationIndex].id
        item.timelineStart = placement.start
        tracks[destinationIndex].items.append(item)
        tracks[destinationIndex].sortItems()

        if sourceTrackID != destinationTrackID,
            let sourceIndex = tracks.firstIndex(where: { $0.id == sourceTrackID })
        {
            removeTrackIfEmptyUnlessLast(at: sourceIndex)
        }
        renumberTracks()
        return TimelinePlacementResult(
            start: item.timelineStart,
            trackIndex: clipLocation(id: item.id)?.track ?? destinationIndex,
            snapped: placement.snapped,
            snapTime: placement.snapTime
        )
    }

    mutating func insertFreshTrack(kind: TrackKind) -> Int {
        if kind != .undefined,
            let undefinedIndex = tracks.firstIndex(where: { $0.kind == .undefined && $0.items.isEmpty })
        {
            tracks[undefinedIndex].kind = kind
            return undefinedIndex
        }

        let hasClipsInKind = tracks.contains { $0.kind == kind && !$0.items.isEmpty }
        if !hasClipsInKind, let emptyIndex = tracks.firstIndex(where: { $0.kind == kind && $0.items.isEmpty }) {
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
        case .shape:
            let insertionIndex = tracks.firstIndex(where: { $0.kind == .visual || $0.kind == .shape }) ?? 0
            tracks.insert(TimelineTrack(name: nextTrackName(for: kind), kind: kind), at: insertionIndex)
            return insertionIndex
        case .text:
            let insertionIndex = tracks.firstIndex(where: {
                $0.kind == .text || $0.kind == .shape || $0.kind == .visual
            }) ?? 0
            tracks.insert(TimelineTrack(name: nextTrackName(for: kind), kind: kind), at: insertionIndex)
            return insertionIndex
        case .audio:
            tracks.append(TimelineTrack(name: nextTrackName(for: kind), kind: kind))
            return tracks.count - 1
        }
    }

    func topAvailableTrackIndex(
        kind: TrackKind,
        start: Double,
        duration: Double
    ) -> Int? {
        let rangeStart = max(0, start)
        let rangeEnd = rangeStart + max(duration, 0.001)

        return tracks.firstIndex { track in
            guard track.kind == kind else { return false }
            if kind == .visual, track.items.contains(where: \.isAdjustmentLayer) {
                return false
            }
            return track.items.allSatisfy { item in
                item.timelineEnd <= rangeStart || item.timelineStart >= rangeEnd
            }
        }
    }

    func topAvailableAdjustmentTrackIndex(
        start: Double,
        duration: Double
    ) -> Int? {
        let rangeStart = max(0, start)
        let rangeEnd = rangeStart + max(duration, 0.001)
        return tracks.firstIndex { track in
            guard track.kind == .visual,
                track.items.allSatisfy(\.isAdjustmentLayer)
            else { return false }
            return track.items.allSatisfy { item in
                item.timelineEnd <= rangeStart || item.timelineStart >= rangeEnd
            }
        }
    }

    mutating func compatibleTrackIndex(
        proposedIndex: Int,
        item: TimelineItem,
        sourceIndex: Int? = nil
    ) -> Int {
        if tracks.indices.contains(proposedIndex),
            tracks[proposedIndex].canAcceptItem(item)
        {
            return proposedIndex
        }

        let matching = tracks.indices.filter { tracks[$0].canAcceptItem(item) }
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

    mutating func removeTrackIfEmptyUnlessLast(at index: Int) {
        guard tracks.indices.contains(index), tracks[index].items.isEmpty else { return }
        if tracks.count > 1 {
            tracks.remove(at: index)
            return
        }
        tracks[index].kind = .undefined
        tracks[index].isMuted = false
        tracks[index].isLocked = false
    }

    mutating func renumberTracks() {
        var visualIndex = 1
        var adjustmentIndex = 1
        var shapeIndex = 1
        var textIndex = 1
        var audioIndex = 1
        for index in tracks.indices {
            switch tracks[index].kind {
            case .undefined:
                tracks[index].name = "Layer"
            case .visual:
                if !tracks[index].items.isEmpty,
                    tracks[index].items.allSatisfy(\.isAdjustmentLayer)
                {
                    tracks[index].name = "Adjustment \(adjustmentIndex)"
                    adjustmentIndex += 1
                } else {
                    tracks[index].name = "Layer \(visualIndex)"
                    visualIndex += 1
                }
            case .shape:
                tracks[index].name = "Shape \(shapeIndex)"
                shapeIndex += 1
            case .text:
                tracks[index].name = "Text \(textIndex)"
                textIndex += 1
            case .audio:
                tracks[index].name = "Audio \(audioIndex)"
                audioIndex += 1
            }
        }
    }

    private func nextTrackName(for kind: TrackKind) -> String {
        guard kind != .undefined else { return "Layer" }
        let count = tracks.filter { $0.kind == kind }.count + 1
        switch kind {
        case .undefined: return "Layer"
        case .visual: return "Layer \(count)"
        case .shape: return "Shape \(count)"
        case .text: return "Text \(count)"
        case .audio: return "Audio \(count)"
        }
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

        let compatibleItems = tracks.flatMap(\.items)

        var bestDistance = snapThreshold
        let anchors = (snapAnchors + compatibleItems.flatMap { [$0.timelineStart, $0.timelineEnd] })
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

        let itemsInDestination = tracks[destinationTrackIndex].items
        let nonOverlappingStart = nearestNonOverlappingStart(
            proposedStart: candidate,
            duration: safeDuration,
            items: itemsInDestination
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
        let otherItems = tracks.flatMap(\.items).filter { $0.id != clipID }
        let otherDuration = otherItems.map(\.timelineEnd).max() ?? 0
        let anchors = ([0, otherDuration] + snapAnchors + otherItems.flatMap { [$0.timelineStart, $0.timelineEnd] })
            .filter { $0.isFinite }

        guard let best = anchors.min(by: { abs($0 - boundedEdge) < abs($1 - boundedEdge) }),
            abs(best - boundedEdge) < snapThreshold
        else {
            return (boundedEdge, false)
        }

        return (max(0, best), true)
    }

    func beatSnapAnchors(excluding itemID: UUID? = nil) -> [Double] {
        tracks.flatMap(\.items).compactMap { item -> MediaTimelineItem? in
            guard item.id != itemID,
                case .media(let media) = item,
                media.mediaType == .audio,
                media.beatAnalysis != nil
            else { return nil }
            return media
        }
        .flatMap { item in
            item.visibleBeatMarkers.map { item.timelineStart + $0.localTimelineTime }
        }
        .filter(\.isFinite)
    }

    private func nearestNonOverlappingStart(proposedStart: Double, duration: Double, items: [TimelineItem]) -> Double {
        guard !items.isEmpty else { return max(0, proposedStart) }

        var ranges: [(start: Double, end: Double)] = []
        var cursor = 0.0

        for item in items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if item.timelineStart - cursor >= duration {
                ranges.append((cursor, item.timelineStart - duration))
            }
            cursor = max(cursor, item.timelineEnd)
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
            let item = tracks[trackIndex].items.first(where: { $0.id == clipID })
        else {
            return (0, Double.greatestFiniteMagnitude / 4)
        }

        let items = tracks[trackIndex].items.filter { $0.id != clipID }
        let previousEnd =
            items
            .filter { $0.timelineEnd <= item.timelineStart + 0.001 }
            .map(\.timelineEnd)
            .max() ?? 0
        let nextStart =
            items
            .filter { $0.timelineStart >= item.timelineEnd - 0.001 }
            .map(\.timelineStart)
            .min() ?? Double.greatestFiniteMagnitude / 4

        return (previousEnd, nextStart)
    }
}
