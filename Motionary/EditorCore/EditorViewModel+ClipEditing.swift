// Clip placement, duplication, movement, trimming, and timeline editing commands.

import Foundation

extension EditorViewModel {
    @discardableResult
    func splitSelectedClip() -> UUID? {
        guard let targetID = selectedClipID,
            let location = project.clipLocation(id: targetID)
        else { return nil }
        let clip = project.tracks[location.track].clips[location.clip]
        let offset = currentTime - clip.timelineStart
        guard offset > 0.08, offset < clip.sourceRange.duration - 0.08 else { return nil }

        let animationSplit = clip.splittingAnimations(at: offset)
        var first = animationSplit.left
        first.sourceRange = TimeRangeValue(start: clip.sourceRange.start, duration: offset)

        var second = animationSplit.right
        second.id = UUID()
        second.name = "\(clip.name) split"
        second.timelineStart = currentTime
        second.sourceRange = TimeRangeValue(
            start: clip.sourceRange.start + offset,
            duration: clip.sourceRange.duration - offset
        )

        let trackID = project.tracks[location.track].id
        commit(
            AnyEditorCommand(
                SplitClipCommand(
                    trackID: trackID,
                    originalClip: clip,
                    first: first,
                    second: second,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                )
            )
        )
        selectedClipID = second.id
        return second.id
    }

    func deleteSelectedClip() {
        guard let selectedClipID,
            let location = project.clipLocation(id: selectedClipID)
        else { return }
        let track = project.tracks[location.track]
        guard let clip = track.items[location.clip].legacyClip() else { return }

        if isRippleEditingEnabled {
            deleteSelectedClipWithRipple(
                selectedClipID,
                location: location,
                deletedRange: clip.timelineStart..<clip.timelineEnd
            )
            return
        }

        let removedTrack = track.items.count == 1 ? track : nil
        let item = track.items[location.clip]
        commit(
            AnyEditorCommand(
                RemoveClipCommand(
                    removedTrack: removedTrack,
                    trackIndex: location.track,
                    itemIndex: location.clip,
                    item: item,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                )
            )
        )
        self.selectedClipID = nil
        if removedTrack != nil {
            let replacementIndex = min(location.track, max(project.tracks.count - 1, 0))
            selectedTrackID =
                project.tracks.indices.contains(replacementIndex)
                ? project.tracks[replacementIndex].id
                : nil
        } else if project.tracks.indices.contains(location.track) {
            selectedTrackID = project.tracks[location.track].id
        }
    }

    private func deleteSelectedClipWithRipple(
        _ clipID: UUID,
        location: (track: Int, clip: Int),
        deletedRange: Range<Double>
    ) {
        let beforeTracks = project.tracks
        var afterTracks = beforeTracks
        guard afterTracks.indices.contains(location.track),
            afterTracks[location.track].items.indices.contains(location.clip),
            afterTracks[location.track].items[location.clip].id == clipID
        else { return }

        afterTracks[location.track].items.remove(at: location.clip)
        if afterTracks[location.track].items.isEmpty {
            afterTracks.remove(at: location.track)
        } else {
            let removedDuration = deletedRange.upperBound - deletedRange.lowerBound
            for index in afterTracks[location.track].items.indices
            where afterTracks[location.track].items[index].timelineStart >= deletedRange.upperBound - 0.000_001 {
                afterTracks[location.track].items[index].timelineStart = max(
                    0,
                    afterTracks[location.track].items[index].timelineStart - removedDuration
                )
            }
            afterTracks[location.track].sortItems()
        }

        commit(
            EditorCommandFactory.trackStructure(
                before: beforeTracks,
                after: afterTracks,
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
        guard let selectedClipID,
            let location = project.clipLocation(id: selectedClipID)
        else { return }
        let sourceClip = project.tracks[location.track].clips[location.clip]
        var copy = sourceClip
        copy.id = UUID()
        copy.name = "\(sourceClip.name) copy"
        copy.timelineStart = project.resolvedPlacementStart(
            proposedStart: sourceClip.timelineEnd + 0.15,
            duration: sourceClip.sourceRange.duration,
            destinationTrackIndex: location.track,
            requiredKind: sourceClip.requiredTrackKind
        )
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

    func moveSelectedClip(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            guard let clip = project.tracks[location.track].items.remove(at: location.clip).legacyClip() else {
                return
            }
            let placement = project.resolvedPlacement(
                proposedStart: clip.timelineStart + seconds,
                duration: clip.sourceRange.duration,
                destinationTrackIndex: location.track,
                requiredKind: clip.requiredTrackKind
            )
            var movedClip = clip
            movedClip.timelineStart = placement.start
            project.tracks[location.track].appendLegacyClip(movedClip)
        }
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
            var preview = project
            guard
                let placement = preview.resolveClipPlacement(
                    clipID,
                    proposedStart: timelineStart,
                    proposedTrackIndex: proposedIndex,
                    currentTime: currentTime
                )
            else { return }
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
        var previewProject = project
        return previewProject.resolveClipPlacement(
            clipID,
            proposedStart: timelineStart,
            proposedTrackIndex: proposedTrackIndex,
            currentTime: currentTime
        )
    }

    @discardableResult
    func trimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let previousEnd = project.neighborBounds(for: currentClip.id, in: location.track).previousEnd
        let maxForward = max(reference.sourceRange.duration - 0.1, 0)
        let maxBackward = -min(reference.sourceRange.start, reference.timelineStart - previousEnd)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineStart + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineStart, maxBackward), maxForward)
        }

        var clip = currentClip
        clip.timelineStart = reference.timelineStart + applied
        clip.sourceRange = TimeRangeValue(
            start: reference.sourceRange.start + applied,
            duration: reference.sourceRange.duration - applied
        )
        clip.trimAnimationsAtStart(
            by: applied,
            oldDuration: reference.sourceRange.duration
        )

        let result = TimelineTrimResult(
            edgeTime: clip.timelineStart,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineStart + applied) - snap.time) < 0.001
        )

        if interactive {
            project.replaceClip(id: clipID, with: clip)
            project.tracks[location.track].sortItems()
            incrementTimelineContentRevision()
            selectedClipID = clip.id
            return result
        }

        var invalidation: EditorInvalidation = [.timelineLayout, .userInterface, .persistence]
        if rebuild {
            invalidation.formUnion(EditorProject.renderInvalidation(before: currentClip, after: clip))
        }
        commit(
            AnyEditorCommand(
                TrimClipCommand(
                    before: currentClip,
                    after: clip,
                    invalidation: invalidation
                )
            )
        )
        selectedClipID = clip.id
        return result
    }

    func previewTrimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let previousEnd = project.neighborBounds(for: currentClip.id, in: location.track).previousEnd
        let maxForward = max(reference.sourceRange.duration - 0.1, 0)
        let maxBackward = -min(reference.sourceRange.start, reference.timelineStart - previousEnd)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineStart + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineStart, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: reference.timelineStart + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineStart + applied) - snap.time) < 0.001
        )
    }

    @discardableResult
    func trimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
            setPreviewQualityForInteraction(true)
        }

        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let nextStart = project.neighborBounds(for: currentClip.id, in: location.track).nextStart
        let sourceForwardLimit =
            reference.mediaType == .image
            ? Double.greatestFiniteMagnitude / 4
            : max(project.originalDuration(for: reference) - reference.sourceRange.end, 0)
        let maxForward = min(sourceForwardLimit, max(nextStart - reference.timelineEnd, 0))
        let maxBackward = -max(reference.sourceRange.duration - 0.1, 0)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineEnd + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineEnd, maxBackward), maxForward)
        }

        var clip = currentClip
        clip.timelineStart = reference.timelineStart
        clip.sourceRange = TimeRangeValue(
            start: reference.sourceRange.start,
            duration: reference.sourceRange.duration + applied
        )
        clip.trimAnimationsAtEnd(
            newDuration: clip.sourceRange.duration,
            oldDuration: reference.sourceRange.duration
        )

        let result = TimelineTrimResult(
            edgeTime: clip.timelineEnd,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineEnd + applied) - snap.time) < 0.001
        )

        if interactive {
            project.replaceClip(id: clipID, with: clip)
            incrementTimelineContentRevision()
            selectedClipID = clip.id
            return result
        }

        var invalidation: EditorInvalidation = [.timelineLayout, .userInterface, .persistence]
        if rebuild {
            invalidation.formUnion(EditorProject.renderInvalidation(before: currentClip, after: clip))
        }
        commit(
            AnyEditorCommand(
                TrimClipCommand(
                    before: currentClip,
                    after: clip,
                    invalidation: invalidation
                )
            )
        )
        selectedClipID = clip.id
        return result
    }

    func previewTrimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let nextStart = project.neighborBounds(for: currentClip.id, in: location.track).nextStart
        let sourceForwardLimit =
            reference.mediaType == .image
            ? Double.greatestFiniteMagnitude / 4
            : max(project.originalDuration(for: reference) - reference.sourceRange.end, 0)
        let maxForward = min(sourceForwardLimit, max(nextStart - reference.timelineEnd, 0))
        let maxBackward = -max(reference.sourceRange.duration - 0.1, 0)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineEnd + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineEnd, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: reference.timelineEnd + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineEnd + applied) - snap.time) < 0.001
        )
    }

    func deselectTimeline() {
        updateSelection(clipID: nil, trackID: nil)
    }
}
