// Clip placement, duplication, movement, trimming, and timeline editing commands.

import Foundation

extension EditorViewModel {
    @discardableResult
    func splitSelectedTimelineItem() -> UUID? {
        splitSelectedClip()
    }

    @discardableResult
    func splitSelectedClip() -> UUID? {
        guard let targetID = selectedClipID,
            let location = project.itemLocation(id: targetID)
        else { return nil }
        let item = project.tracks[location.track].items[location.item]
        let offset = currentTime - item.timelineStart
        guard let split = item.split(at: offset) else { return nil }

        let trackID = project.tracks[location.track].id
        commit(
            AnyEditorCommand(
                SplitClipCommand(
                    trackID: trackID,
                    originalItem: item,
                    first: split.left,
                    second: split.right,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                )
            )
        )
        selectedClipID = split.right.id
        return split.right.id
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
            let location = project.clipLocation(id: selectedClipID)
        else { return }
        let track = project.tracks[location.track]
        let item = track.items[location.clip]

        if isRippleEditingEnabled {
            deleteSelectedClipWithRipple(
                selectedClipID,
                location: location,
                deletedRange: item.timelineStart..<item.timelineEnd
            )
            return
        }

        let before = project
        var after = project
        guard after.tracks.indices.contains(location.track),
            after.tracks[location.track].items.indices.contains(location.clip),
            after.tracks[location.track].items[location.clip].id == selectedClipID
        else { return }
        after.tracks[location.track].items.remove(at: location.clip)
        after.removeTrackIfEmptyUnlessLast(at: location.track)
        after.renumberTracks()
        after.synchronizeMediaLibrary()

        commit(
            after.historyCommand(
                from: before,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            )
        )
        self.selectedClipID = nil
        let replacementIndex = min(location.track, max(project.tracks.count - 1, 0))
        selectedTrackID = project.tracks.indices.contains(replacementIndex)
            ? project.tracks[replacementIndex].id
            : nil
    }

    private func deleteSelectedClipWithRipple(
        _ clipID: UUID,
        location: (track: Int, clip: Int),
        deletedRange: Range<Double>
    ) {
        let before = project
        var after = project
        var afterTracks = after.tracks
        guard afterTracks.indices.contains(location.track),
            afterTracks[location.track].items.indices.contains(location.clip),
            afterTracks[location.track].items[location.clip].id == clipID
        else { return }

        afterTracks[location.track].items.remove(at: location.clip)
        let removedDuration = deletedRange.upperBound - deletedRange.lowerBound
        for index in afterTracks[location.track].items.indices
        where afterTracks[location.track].items[index].timelineStart >= deletedRange.upperBound - 0.000_001 {
            afterTracks[location.track].items[index].timelineStart = max(
                0,
                afterTracks[location.track].items[index].timelineStart - removedDuration
            )
        }
        afterTracks[location.track].sortItems()
        after.tracks = afterTracks
        after.removeTrackIfEmptyUnlessLast(at: location.track)
        after.renumberTracks()
        after.synchronizeMediaLibrary()

        commit(
            after.historyCommand(
                from: before,
                invalidation: [
                    .previewFrame,
                    .compositionTopology,
                    .audioMix,
                    .timelineLayout,
                    .userInterface,
                    .persistence,
                ]
            )
        )

        self.selectedClipID = nil
        let replacementIndex = min(location.track, max(project.tracks.count - 1, 0))
        selectedTrackID = project.tracks.indices.contains(replacementIndex)
            ? project.tracks[replacementIndex].id
            : nil
    }

    func duplicateSelectedClip() {
        duplicateSelectedClip(toNewLayer: AppPreferences.duplicateClipsToNewLayer)
    }

    func duplicateSelectedClip(toNewLayer duplicatesToNewLayer: Bool) {
        guard let selectedClipID,
            let location = project.clipLocation(id: selectedClipID)
        else { return }
        let sourceItem = project.tracks[location.track].items[location.clip]

        if duplicatesToNewLayer {
            duplicate(sourceItem, toNewLayerAt: location.track)
            return
        }

        let copyStart = project.resolvedPlacementStart(
            proposedStart: sourceItem.timelineEnd + 0.15,
            duration: sourceItem.placementDuration,
            destinationTrackIndex: location.track,
            requiredKind: sourceItem.requiredTrackKind
        )
        let copy = sourceItem.duplicated(startingAt: copyStart)
        commit(
            AnyEditorCommand(
                DuplicateClipCommand(
                    trackID: project.tracks[location.track].id,
                    copy: copy,
                    insertIndex: location.clip + 1,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                )
            )
        )
        self.selectedClipID = copy.id
    }

    private func duplicate(_ sourceItem: TimelineItem, toNewLayerAt sourceTrackIndex: Int) {
        let beforeTracks = project.tracks
        var after = project
        let copy = sourceItem.duplicated(startingAt: sourceItem.timelineStart)
        let newTrack = TimelineTrack(
            name: "Layer",
            kind: sourceItem.requiredTrackKind,
            items: [copy]
        )
        let insertionIndex = min(max(sourceTrackIndex, 0), after.tracks.count)
        after.tracks.insert(newTrack, at: insertionIndex)
        after.renumberTracks()

        commit(
            EditorCommandFactory.trackStructure(
                before: beforeTracks,
                after: after.tracks,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            )
        )
        selectedTrackID = newTrack.id
        selectedClipID = copy.id
    }

    func duplicateSelectedTimelineItem() {
        duplicateSelectedClip()
    }

    func moveSelectedClip(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.itemLocation(id: selectedClipID) else { return }
            let beatAnchors = project.beatSnapAnchors(excluding: selectedClipID)
            var item = project.tracks[location.track].items.remove(at: location.item)
            let placement = project.resolvedPlacement(
                proposedStart: item.timelineStart + seconds,
                duration: item.placementDuration,
                destinationTrackIndex: location.track,
                requiredKind: item.requiredTrackKind,
                snapAnchors: [currentTime] + beatAnchors
            )
            item.timelineStart = placement.start
            project.tracks[location.track].items.append(item)
            project.tracks[location.track].sortItems()
        }
    }

    func moveSelectedTimelineItem(by seconds: Double) {
        moveSelectedClip(by: seconds)
    }

    @discardableResult
    func placeTimelineItem(
        _ itemID: UUID,
        at timelineStart: Double,
        proposedTrackIndex: Int,
        insertTrackAt insertionIndex: Int? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelinePlacementResult? {
        placeClip(
            itemID,
            at: timelineStart,
            proposedTrackIndex: proposedTrackIndex,
            insertTrackAt: insertionIndex,
            rebuild: rebuild,
            interactive: interactive
        )
    }

    @discardableResult
    func placeClip(
        _ clipID: UUID,
        at timelineStart: Double,
        proposedTrackIndex: Int,
        insertTrackAt insertionIndex: Int? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelinePlacementResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        var result: TimelinePlacementResult?
        mutateProject(
            rebuild: interactive ? false : rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            let proposedIndex = insertionIndex ?? proposedTrackIndex
            guard
                let placementSession = TimelinePlacementDragSession(
                    project: project,
                    itemID: clipID,
                    currentTime: currentTime
                )
            else { return }
            let placement = placementSession.resolve(
                proposedStart: timelineStart,
                proposedTrackIndex: proposedIndex
            )
            result = project.placeClip(clipID, using: placement)
            selectedClipID = clipID
            selectedTrackID = project.tracks.first(where: { $0.itemIndex(id: clipID) != nil })?.id
        }
        return result
    }

    @discardableResult
    func placeClip(
        _ clipID: UUID,
        using placement: TimelinePlacementResult,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelinePlacementResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        var result: TimelinePlacementResult?
        mutateProject(
            rebuild: interactive ? false : rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            result = project.placeClip(clipID, using: placement)
            selectedClipID = clipID
            selectedTrackID = project.tracks.first(where: { $0.itemIndex(id: clipID) != nil })?.id
        }
        return result
    }

    func resolveClipPlacement(
        _ clipID: UUID,
        at timelineStart: Double,
        proposedTrackIndex: Int
    ) -> TimelinePlacementResult? {
        makeClipPlacementDragSession(clipID)?.resolve(
            proposedStart: timelineStart,
            proposedTrackIndex: proposedTrackIndex
        )
    }

    func makeClipPlacementDragSession(
        _ clipID: UUID
    ) -> TimelinePlacementDragSession? {
        TimelinePlacementDragSession(
            project: project,
            itemID: clipID,
            currentTime: currentTime
        )
    }

    @discardableResult
    func trimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineItem? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        guard let location = project.itemLocation(id: clipID) else { return nil }
        let currentItem = project.tracks[location.track].items[location.item]
        let referenceStart = baseline?.timelineStart ?? currentItem.timelineStart
        let referenceRange = baseline?.sourceRange ?? currentItem.sourceRange
        let referenceDuration = baseline?.placementDuration ?? currentItem.placementDuration
        let previousEnd = project.neighborBounds(for: currentItem.id, in: location.track).previousEnd
        let maxForward = max(referenceDuration - 0.1, 0)
        let availableBefore = referenceStart - previousEnd
        let maxBackward: Double
        switch currentItem {
        case .media(let media):
            maxBackward = -min(
                referenceRange.start / media.speedMap.speed(at: 0),
                availableBefore
            )
        case .shape:
            maxBackward = -min(referenceRange.start, availableBefore)
        default:
            maxBackward = -availableBefore
        }
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = referenceStart + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentItem.id,
            requiredKind: currentItem.requiredTrackKind,
            snapAnchors: [currentTime] + project.beatSnapAnchors()
        )
        if snap.snapped {
            applied = min(max(snap.time - referenceStart, maxBackward), maxForward)
        }

        let item = currentItem.trimmingStart(by: applied)

        let result = TimelineTrimResult(
            edgeTime: item.timelineStart,
            appliedDelta: applied,
            snapped: snap.snapped && abs((referenceStart + applied) - snap.time) < 0.001
        )

        if interactive {
            mutateProject(
                rebuild: false,
                recordHistory: false,
                persistChanges: false,
                touchUpdatedAt: false,
                refreshTimeline: true
            ) { project in
                project.replaceItem(id: clipID, with: item)
                if let updatedLocation = project.itemLocation(id: clipID) {
                    project.tracks[updatedLocation.track].sortItems()
                }
            }
            selectedClipID = item.id
            return result
        }

        var invalidation: EditorInvalidation = [.timelineLayout, .userInterface, .persistence]
        if rebuild {
            invalidation.formUnion([.previewFrame, .compositionTopology, .audioMix])
        }
        commit(
            AnyEditorCommand(
                TrimClipCommand(
                    before: currentItem,
                    after: item,
                    invalidation: invalidation
                )
            )
        )
        selectedClipID = item.id
        return result
    }

    func previewTrimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineItem? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.itemLocation(id: clipID) else { return nil }
        let item = project.tracks[location.track].items[location.item]
        let referenceStart = baseline?.timelineStart ?? item.timelineStart
        let referenceRange = baseline?.sourceRange ?? item.sourceRange
        let referenceDuration = baseline?.placementDuration ?? item.placementDuration
        let previousEnd = project.neighborBounds(for: item.id, in: location.track).previousEnd
        let maxForward = max(referenceDuration - 0.1, 0)
        let availableBefore = referenceStart - previousEnd
        let maxBackward: Double
        switch item {
        case .media(let media):
            maxBackward = -min(
                referenceRange.start / media.speedMap.speed(at: 0),
                availableBefore
            )
        case .shape:
            maxBackward = -min(referenceRange.start, availableBefore)
        default:
            maxBackward = -availableBefore
        }
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = referenceStart + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: item.id,
            requiredKind: item.requiredTrackKind,
            snapAnchors: [currentTime] + project.beatSnapAnchors()
        )
        if snap.snapped {
            applied = min(max(snap.time - referenceStart, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: referenceStart + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((referenceStart + applied) - snap.time) < 0.001
        )
    }

    @discardableResult
    func trimTimelineItemStart(
        _ itemID: UUID,
        by seconds: Double,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        trimClipStart(itemID, by: seconds, rebuild: rebuild, interactive: interactive)
    }

    @discardableResult
    func trimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineItem? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        guard let location = project.itemLocation(id: clipID) else { return nil }
        let currentItem = project.tracks[location.track].items[location.item]
        let referenceRange = baseline?.sourceRange ?? currentItem.sourceRange
        let referenceEnd = baseline?.timelineEnd ?? currentItem.timelineEnd
        let referenceDuration = baseline?.placementDuration ?? currentItem.placementDuration
        let nextStart = project.neighborBounds(for: currentItem.id, in: location.track).nextStart
        let sourceForwardLimit = sourceForwardTrimLimit(for: currentItem, range: referenceRange)
        let maxForward = min(sourceForwardLimit, max(nextStart - referenceEnd, 0))
        let maxBackward = -max(referenceDuration - 0.1, 0)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = referenceEnd + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentItem.id,
            requiredKind: currentItem.requiredTrackKind,
            snapAnchors: [currentTime] + project.beatSnapAnchors()
        )
        if snap.snapped {
            applied = min(max(snap.time - referenceEnd, maxBackward), maxForward)
        }

        let item = currentItem.trimmingEnd(by: applied)

        let result = TimelineTrimResult(
            edgeTime: referenceEnd + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((referenceEnd + applied) - snap.time) < 0.001
        )

        if interactive {
            mutateProject(
                rebuild: false,
                recordHistory: false,
                persistChanges: false,
                touchUpdatedAt: false,
                refreshTimeline: true
            ) { project in
                project.replaceItem(id: clipID, with: item)
            }
            selectedClipID = item.id
            return result
        }

        var invalidation: EditorInvalidation = [.timelineLayout, .userInterface, .persistence]
        if rebuild {
            invalidation.formUnion([.previewFrame, .compositionTopology, .audioMix])
        }
        commit(
            AnyEditorCommand(
                TrimClipCommand(
                    before: currentItem,
                    after: item,
                    invalidation: invalidation
                )
            )
        )
        selectedClipID = item.id
        return result
    }

    func previewTrimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineItem? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.itemLocation(id: clipID) else { return nil }
        let item = project.tracks[location.track].items[location.item]
        let referenceRange = baseline?.sourceRange ?? item.sourceRange
        let referenceEnd = baseline?.timelineEnd ?? item.timelineEnd
        let referenceDuration = baseline?.placementDuration ?? item.placementDuration
        let nextStart = project.neighborBounds(for: item.id, in: location.track).nextStart
        let sourceForwardLimit = sourceForwardTrimLimit(for: item, range: referenceRange)
        let maxForward = min(sourceForwardLimit, max(nextStart - referenceEnd, 0))
        let maxBackward = -max(referenceDuration - 0.1, 0)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = referenceEnd + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: item.id,
            requiredKind: item.requiredTrackKind,
            snapAnchors: [currentTime] + project.beatSnapAnchors()
        )
        if snap.snapped {
            applied = min(max(snap.time - referenceEnd, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: referenceEnd + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((referenceEnd + applied) - snap.time) < 0.001
        )
    }

    @discardableResult
    func trimTimelineItemEnd(
        _ itemID: UUID,
        by seconds: Double,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        trimClipEnd(itemID, by: seconds, rebuild: rebuild, interactive: interactive)
    }

    private func sourceForwardTrimLimit(for item: TimelineItem, range: TimeRangeValue) -> Double {
        switch item {
        case .media(let media):
            if media.mediaType == .image { return Double.greatestFiniteMagnitude / 4 }
            let sourceDuration = max(
                (project.mediaLibrary[media.mediaID]?.originalDuration ?? range.end) - range.end,
                0
            )
            return sourceDuration / media.speedMap.speed(at: range.duration)
        case .shape, .text, .caption, .adjustment, .compound:
            return Double.greatestFiniteMagnitude / 4
        }
    }

    func deselectTimeline() {
        updateSelection(clipID: nil, trackID: nil)
    }
}
