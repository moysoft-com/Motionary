// Granular timeline snapshots and indexed playback/scrubbing lookups.

import Foundation
import os

enum TimelinePerformanceSignposts {
    static let log = OSLog(
        subsystem: "com.moysoft.motionary",
        category: "TimelinePerformance"
    )
}

struct TimelineRenderItem: Equatable, Identifiable {
    let item: TimelineItem
    let legacyClip: TimelineClip?
    let keyframeTimes: [Double]

    var id: UUID { item.id }
    var timelineStart: Double { item.timelineStart }
    var timelineEnd: Double { item.timelineEnd }
}

struct TimelineRenderTrackSnapshot: Equatable {
    let sourceTrack: TimelineTrack
    let items: [TimelineRenderItem]
    let prefixMaximumTimelineEnds: [Double]
    private let itemIndexByID: [UUID: Int]

    init(track: TimelineTrack) {
        sourceTrack = track
        let renderItems = track.items
            .map { item in
                TimelineRenderItem(
                    item: item,
                    legacyClip: item.legacyClip(),
                    keyframeTimes: item.allKeyframeTimes
                )
            }
            .sorted { lhs, rhs in
                if lhs.timelineStart == rhs.timelineStart {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timelineStart < rhs.timelineStart
            }
        items = renderItems

        var indicesByID: [UUID: Int] = [:]
        indicesByID.reserveCapacity(renderItems.count)
        for (index, renderItem) in renderItems.enumerated() {
            indicesByID[renderItem.id] = index
        }
        itemIndexByID = indicesByID

        var maximumEnd = -Double.infinity
        prefixMaximumTimelineEnds = renderItems.map { renderItem in
            maximumEnd = max(maximumEnd, renderItem.timelineEnd)
            return maximumEnd
        }
    }

    func item(withID itemID: UUID) -> TimelineRenderItem? {
        guard let index = itemIndexByID[itemID] else { return nil }
        return items[index]
    }
}

struct TimelineRenderSnapshot: Equatable {
    let revision: Int
    let tracks: [TimelineTrack]
    let trackSnapshotsByID: [UUID: TimelineRenderTrackSnapshot]
    let selectedClipID: UUID?
    let duration: Double
    let keyframeTolerance: Double

    func items(
        in trackID: UUID,
        intersecting timeRange: ClosedRange<Double>,
        retaining retainedItemIDs: Set<UUID> = []
    ) -> [TimelineRenderItem] {
        guard let trackSnapshot = trackSnapshotsByID[trackID],
            !trackSnapshot.items.isEmpty
        else {
            return []
        }
        let allItems = trackSnapshot.items

        var lower = 0
        var upper = allItems.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if allItems[midpoint].timelineStart < timeRange.lowerBound {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }

        var overlapLower = 0
        var overlapUpper = lower
        while overlapLower < overlapUpper {
            let midpoint = (overlapLower + overlapUpper) / 2
            if trackSnapshot.prefixMaximumTimelineEnds[midpoint] >= timeRange.lowerBound {
                overlapUpper = midpoint
            } else {
                overlapLower = midpoint + 1
            }
        }

        var result: [TimelineRenderItem] = []
        result.reserveCapacity(min(allItems.count, 16))
        var index = overlapLower
        while index < allItems.count {
            let renderItem = allItems[index]
            if renderItem.timelineStart > timeRange.upperBound {
                break
            }
            if renderItem.timelineEnd >= timeRange.lowerBound {
                result.append(renderItem)
            }
            index += 1
        }

        if !retainedItemIDs.isEmpty {
            var includedIDs = Set(result.map(\.id))
            for retainedItemID in retainedItemIDs {
                guard !includedIDs.contains(retainedItemID),
                    let renderItem = trackSnapshot.item(withID: retainedItemID)
                else {
                    continue
                }
                result.append(renderItem)
                includedIDs.insert(retainedItemID)
            }
            result.sort { lhs, rhs in
                if lhs.timelineStart == rhs.timelineStart {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timelineStart < rhs.timelineStart
            }
        }
        return result
    }
}

struct TimelineEvaluationIndex {
    private struct CostSample {
        let time: Double
        let cost: Int
    }

    private let costSamples: [CostSample]
    private let globalNavigationPoints: [Double]
    private let beatNavigationPoints: [Double]
    private let itemNavigationPoints: [UUID: [Double]]

    var storedNavigationPointCount: Int {
        globalNavigationPoints.count
            + beatNavigationPoints.count
            + itemNavigationPoints.values.reduce(0) { $0 + $1.count }
    }

    init(project: EditorProject) {
        let signpostID = OSSignpostID(log: TimelinePerformanceSignposts.log)
        os_signpost(
            .begin,
            log: TimelinePerformanceSignposts.log,
            name: "Build Evaluation Index",
            signpostID: signpostID,
            "tracks=%d",
            project.tracks.count
        )
        defer {
            os_signpost(
                .end,
                log: TimelinePerformanceSignposts.log,
                name: "Build Evaluation Index",
                signpostID: signpostID
            )
        }

        let beatAnchors = Self.sortedUnique(project.beatSnapAnchors())
        var globalPoints = beatAnchors
        var pointsByItem: [UUID: [Double]] = [:]
        pointsByItem.reserveCapacity(project.tracks.reduce(0) { $0 + $1.items.count })
        var costEvents: [(time: Double, delta: Int)] = []

        for track in project.tracks {
            for item in track.items {
                let localKeyframeTimes = item.allKeyframeTimes
                let absoluteKeyframeTimes = localKeyframeTimes.map { item.timelineStart + $0 }
                globalPoints.append(item.timelineStart)
                globalPoints.append(item.timelineEnd)
                globalPoints.append(contentsOf: absoluteKeyframeTimes)
                pointsByItem[item.id] = Self.sortedUnique(
                    [item.timelineStart, item.timelineEnd]
                        + absoluteKeyframeTimes
                )

                guard !track.isMuted else { continue }
                switch track.kind {
                case .visual, .shape, .text:
                    break
                case .undefined, .audio:
                    continue
                }
                let cost = Self.previewCost(for: item, keyframeCount: localKeyframeTimes.count)
                guard cost > 0, item.timelineEnd > item.timelineStart else { continue }
                costEvents.append((item.timelineStart, cost))
                costEvents.append((item.timelineEnd, -cost))
            }
        }

        globalNavigationPoints = Self.sortedUnique(globalPoints)
        beatNavigationPoints = beatAnchors
        itemNavigationPoints = pointsByItem

        costEvents.sort {
            if $0.time == $1.time { return $0.delta < $1.delta }
            return $0.time < $1.time
        }
        var samples: [CostSample] = []
        samples.reserveCapacity(costEvents.count)
        var runningCost = 0
        var eventIndex = 0
        while eventIndex < costEvents.count {
            let time = costEvents[eventIndex].time
            var delta = 0
            while eventIndex < costEvents.count, costEvents[eventIndex].time == time {
                delta += costEvents[eventIndex].delta
                eventIndex += 1
            }
            runningCost = max(runningCost + delta, 0)
            samples.append(CostSample(time: time, cost: runningCost))
        }
        costSamples = samples
    }

    func generatedLayerCost(at time: Double) -> Int {
        guard !costSamples.isEmpty else { return 0 }
        var lower = 0
        var upper = costSamples.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if costSamples[midpoint].time <= time {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard lower > 0 else { return 0 }
        return costSamples[lower - 1].cost
    }

    func navigationPoints(for selectedItemID: UUID?) -> [Double] {
        guard let selectedItemID else { return globalNavigationPoints }
        guard let itemPoints = itemNavigationPoints[selectedItemID] else {
            return globalNavigationPoints
        }
        return Self.mergingSortedUnique(itemPoints, beatNavigationPoints)
    }

    func previousNavigationPoint(
        before time: Double,
        tolerance: Double,
        selectedItemID: UUID?
    ) -> Double? {
        let target = time - tolerance
        guard let selectedItemID,
            let itemPoints = itemNavigationPoints[selectedItemID]
        else {
            return Self.previousPoint(in: globalNavigationPoints, before: target)
        }

        let itemPoint = Self.previousPoint(in: itemPoints, before: target)
        let beatPoint = Self.previousPoint(in: beatNavigationPoints, before: target)
        return [itemPoint, beatPoint].compactMap { $0 }.max()
    }

    func nextNavigationPoint(
        after time: Double,
        tolerance: Double,
        selectedItemID: UUID?
    ) -> Double? {
        let target = time + tolerance
        guard let selectedItemID,
            let itemPoints = itemNavigationPoints[selectedItemID]
        else {
            return Self.nextPoint(in: globalNavigationPoints, after: target)
        }

        let itemPoint = Self.nextPoint(in: itemPoints, after: target)
        let beatPoint = Self.nextPoint(in: beatNavigationPoints, after: target)
        return [itemPoint, beatPoint].compactMap { $0 }.min()
    }

    private static func previousPoint(in points: [Double], before target: Double) -> Double? {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if points[midpoint] < target {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard lower > 0 else { return nil }
        return points[lower - 1]
    }

    private static func nextPoint(in points: [Double], after target: Double) -> Double? {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if points[midpoint] <= target {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard lower < points.count else { return nil }
        return points[lower]
    }

    private static func mergingSortedUnique(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0

        while lhsIndex < lhs.count || rhsIndex < rhs.count {
            let value: Double
            if rhsIndex >= rhs.count
                || (lhsIndex < lhs.count && lhs[lhsIndex] <= rhs[rhsIndex])
            {
                value = lhs[lhsIndex]
                lhsIndex += 1
            } else {
                value = rhs[rhsIndex]
                rhsIndex += 1
            }
            if result.last.map({
                abs($0 - value) > KeyframeMergeSupport.timeTolerance
            }) ?? true {
                result.append(value)
            }
        }
        return result
    }

    private static func sortedUnique(_ values: [Double]) -> [Double] {
        values
            .filter(\.isFinite)
            .map { max($0, 0) }
            .sorted()
            .reduce(into: [Double]()) { result, value in
                if result.last.map({ abs($0 - value) > KeyframeMergeSupport.timeTolerance }) ?? true {
                    result.append(value)
                }
            }
    }

    private static func previewCost(for item: TimelineItem, keyframeCount: Int) -> Int {
        let visuals = item.editableVisuals
        let effectCost =
            visuals?.effectStack.effects.reduce(0) { partial, effect in
                partial + (effect.isEnabled ? 2 + min(effect.parameters.count, 3) : 0)
            } ?? 0
        let maskCost = visuals?.mask == nil ? 0 : 2
        let backgroundRemovalCost = visuals?.backgroundRemoval == nil ? 0 : 3
        let animationCost = min(keyframeCount, 8)

        switch item {
        case .media:
            return 1 + effectCost + maskCost + backgroundRemovalCost + animationCost
        case .shape:
            return 3 + effectCost + maskCost + animationCost
        case .text(let text):
            let textAnimationCost =
                (text.animations.entrance == nil ? 0 : 2)
                + (text.animations.loop == nil ? 0 : 2)
                + (text.animations.exit == nil ? 0 : 2)
            return 3 + textAnimationCost + effectCost + maskCost + animationCost
        case .adjustment:
            return 2 + effectCost + maskCost + animationCost
        case .compound:
            return 2 + effectCost + maskCost + animationCost
        case .caption:
            return 1
        }
    }
}

extension TimelineInvalidationScope {
    static func comparing(
        previous: [TimelineTrack],
        current: [TimelineTrack]
    ) -> TimelineInvalidationScope {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let allTrackIDs = Set(previousByID.keys).union(currentByID.keys)
        let affectedTrackIDs = Set(allTrackIDs.filter { previousByID[$0] != currentByID[$0] })
        let isStructural =
            previous.map(\.id) != current.map(\.id)
            || affectedTrackIDs.contains { previousByID[$0]?.kind != currentByID[$0]?.kind }

        guard !affectedTrackIDs.isEmpty || isStructural else {
            return .tracks([])
        }

        let affectedItems = affectedTrackIDs.flatMap { trackID -> [TimelineItem] in
            let previousTrack = previousByID[trackID]
            let currentTrack = currentByID[trackID]
            guard let previousTrack, let currentTrack else {
                return (previousTrack?.items ?? []) + (currentTrack?.items ?? [])
            }

            let previousItems = Dictionary(
                uniqueKeysWithValues: previousTrack.items.map { ($0.id, $0) }
            )
            let currentItems = Dictionary(
                uniqueKeysWithValues: currentTrack.items.map { ($0.id, $0) }
            )
            let changedItemIDs = Set(previousItems.keys)
                .union(currentItems.keys)
                .filter { previousItems[$0] != currentItems[$0] }
            return changedItemIDs.flatMap { itemID in
                [previousItems[itemID], currentItems[itemID]].compactMap { $0 }
            }
        }
        let lowerBound = affectedItems.map(\.timelineStart).min()
        let upperBound = affectedItems.map(\.timelineEnd).max()
        let range = lowerBound.flatMap { lower in
            upperBound.map { upper in lower...max(lower, upper) }
        }
        return .tracks(
            affectedTrackIDs,
            timeRange: range,
            structural: isStructural
        )
    }
}

extension EditorViewModel {
    /// Identity used by the UIKit timeline host. Selection is presentation state,
    /// so it refreshes the hosted tree without rebuilding track-derived caches.
    var timelineHostingRevision: Int {
        var hasher = Hasher()
        hasher.combine(timelineContentRevision)
        hasher.combine(selectedClipID)
        return hasher.finalize()
    }

    var timelineRenderSnapshot: TimelineRenderSnapshot {
        if timelineSnapshotRevision != timelineContentRevision || timelineSnapshot == nil {
            let signpostID = OSSignpostID(log: TimelinePerformanceSignposts.log)
            os_signpost(
                .begin,
                log: TimelinePerformanceSignposts.log,
                name: "Build Render Snapshot",
                signpostID: signpostID,
                "revision=%d tracks=%d",
                timelineContentRevision,
                project.tracks.count
            )

            var snapshotsByID: [UUID: TimelineRenderTrackSnapshot] = [:]
            snapshotsByID.reserveCapacity(project.tracks.count)
            for track in project.tracks {
                if let cached = timelineTrackSnapshotCache[track.id],
                    cached.sourceTrack == track
                {
                    snapshotsByID[track.id] = cached
                } else {
                    let snapshot = TimelineRenderTrackSnapshot(track: track)
                    timelineTrackSnapshotCache[track.id] = snapshot
                    snapshotsByID[track.id] = snapshot
                }
            }
            timelineTrackSnapshotCache = timelineTrackSnapshotCache.filter {
                snapshotsByID[$0.key] != nil
            }
            timelineSnapshot = TimelineRenderSnapshot(
                revision: timelineContentRevision,
                tracks: project.tracks,
                trackSnapshotsByID: snapshotsByID,
                selectedClipID: selectedClipID,
                duration: duration,
                keyframeTolerance: keyframeTimeTolerance
            )
            timelineSnapshotRevision = timelineContentRevision
            os_signpost(
                .end,
                log: TimelinePerformanceSignposts.log,
                name: "Build Render Snapshot",
                signpostID: signpostID
            )
        } else if timelineSnapshot?.selectedClipID != selectedClipID,
            let snapshot = timelineSnapshot
        {
            timelineSnapshot = TimelineRenderSnapshot(
                revision: snapshot.revision,
                tracks: snapshot.tracks,
                trackSnapshotsByID: snapshot.trackSnapshotsByID,
                selectedClipID: selectedClipID,
                duration: snapshot.duration,
                keyframeTolerance: snapshot.keyframeTolerance
            )
        }

        guard let timelineSnapshot else {
            preconditionFailure("Timeline snapshot construction must produce a snapshot")
        }
        return timelineSnapshot
    }

    func legacyClips(for track: TimelineTrack) -> [TimelineClip] {
        if timelineClipCacheRevision != timelineContentRevision {
            rebuildTimelineClipCache()
        }
        return timelineClipCache[track.id] ?? track.clips
    }

    func markTimelineEvaluationChanged() {
        guard timelineEvaluationIndexGeneration == timelineEvaluationGeneration else {
            return
        }
        timelineEvaluationGeneration &+= 1
    }

    func invalidatePreviewCanvasIfNeeded(
        _ scope: TimelineInvalidationScope,
        previousTracks: [TimelineTrack],
        currentTracks: [TimelineTrack]
    ) {
        let isPreviewTrack: (TimelineTrack) -> Bool = {
            $0.kind != .audio
        }
        let affectsPreview: Bool
        if scope.invalidatesAllTracks {
            affectsPreview =
                previousTracks.contains(where: isPreviewTrack)
                || currentTracks.contains(where: isPreviewTrack)
        } else {
            affectsPreview = scope.affectedTrackIDs.contains { trackID in
                previousTracks.first(where: { $0.id == trackID }).map(isPreviewTrack)
                    ?? currentTracks.first(where: { $0.id == trackID }).map(isPreviewTrack)
                    ?? false
            }
        }
        guard affectsPreview else { return }
        previewCanvasState.invalidateVisualGeometry()
    }

    func cachedTimelineEvaluationIndex(allowStale: Bool = false) -> TimelineEvaluationIndex {
        if allowStale, let timelineEvaluationIndex {
            return timelineEvaluationIndex
        }
        if timelineEvaluationIndexGeneration != timelineEvaluationGeneration
            || timelineEvaluationIndex == nil
        {
            timelineEvaluationIndex = TimelineEvaluationIndex(project: project)
            timelineEvaluationIndexGeneration = timelineEvaluationGeneration
        }
        return timelineEvaluationIndex!
    }

    func invalidateTimelineContent(_ scope: TimelineInvalidationScope) {
        invalidateTimelineCaches(scope)
        timelineState.invalidate(scope)
    }

    /// Marks value caches dirty without publishing a timeline-layout update.
    /// Inspector-only mutations still need fresh snapshots when queried, even
    /// when their UI intentionally leaves track layout untouched.
    func invalidateTimelineCaches(_ scope: TimelineInvalidationScope) {
        if scope.invalidatesAllTracks || scope.isStructural {
            timelineTrackSnapshotCache.removeAll(keepingCapacity: true)
        } else {
            for trackID in scope.affectedTrackIDs {
                timelineTrackSnapshotCache[trackID] = nil
            }
        }
        timelineSnapshotRevision = -1
        timelineClipCacheRevision = -1
    }

    func deferTimelineContentInvalidation(_ scope: TimelineInvalidationScope) {
        guard !scope.affectedTrackIDs.isEmpty || scope.isStructural || scope.invalidatesAllTracks else {
            return
        }
        if pendingTimelineInvalidationScope == nil {
            pendingTimelineInvalidationScope = scope
        } else {
            pendingTimelineInvalidationScope?.formUnion(scope)
        }
    }

    func flushPendingTimelineContentInvalidation() {
        guard let scope = pendingTimelineInvalidationScope else { return }
        pendingTimelineInvalidationScope = nil
        invalidateTimelineContent(scope)
    }

    private func rebuildTimelineClipCache() {
        timelineClipCache = Dictionary(
            uniqueKeysWithValues: project.tracks.map { track in
                let cachedItems = timelineTrackSnapshotCache[track.id]?.sourceTrack == track
                    ? timelineTrackSnapshotCache[track.id]?.items
                    : nil
                return (
                    track.id,
                    cachedItems?.compactMap(\.legacyClip)
                        ?? track.items.compactMap { $0.legacyClip() }
                )
            }
        )
        timelineClipCacheRevision = timelineContentRevision
    }
}
