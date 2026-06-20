// Clip placement, duplication, movement, trimming, and timeline editing commands.

import Foundation

extension EditorViewModel {
    @discardableResult
    func splitSelectedClip() -> UUID? {
        guard let targetID = selectedClipID else { return nil }
        var splitClipID: UUID?

        mutateProject { project in
            guard let location = project.clipLocation(id: targetID) else { return }
            let clip = project.tracks[location.track].clips[location.clip]
            let offset = currentTime - clip.timelineStart
            guard offset > 0.08, offset < clip.sourceRange.duration - 0.08 else { return }

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

            project.tracks[location.track].clips[location.clip] = first
            project.tracks[location.track].clips.insert(second, at: location.clip + 1)
            selectedClipID = second.id
            splitClipID = second.id
        }
        return splitClipID
    }

    func deleteSelectedClip() {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            project.tracks[location.track].clips.remove(at: location.clip)
            self.selectedClipID = nil

            if project.tracks[location.track].clips.isEmpty {
                project.tracks.remove(at: location.track)
                let replacementIndex = min(location.track, max(project.tracks.count - 1, 0))
                self.selectedTrackID =
                    project.tracks.indices.contains(replacementIndex)
                    ? project.tracks[replacementIndex].id
                    : nil
            } else {
                self.selectedTrackID = project.tracks[location.track].id
            }
        }
    }

    func duplicateSelectedClip() {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
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
            project.tracks[location.track].clips.insert(copy, at: location.clip + 1)
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
            self.selectedClipID = copy.id
        }
    }

    func moveSelectedClip(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips.remove(at: location.clip)
            let placement = project.resolvedPlacement(
                proposedStart: clip.timelineStart + seconds,
                duration: clip.sourceRange.duration,
                destinationTrackIndex: location.track,
                requiredKind: clip.requiredTrackKind
            )
            clip.timelineStart = placement.start
            project.tracks[location.track].clips.append(clip)
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
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
        }

        var result: TimelinePlacementResult?
        mutateProject(
            rebuild: interactive ? false : rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            let proposedIndex = insertionIndex ?? proposedTrackIndex
            var previewProject = project
            guard
                let placement = previewProject.resolveClipPlacement(
                    clipID,
                    proposedStart: timelineStart,
                    proposedTrackIndex: proposedIndex,
                    currentTime: currentTime
                )
            else { return }
            result = project.placeClip(clipID, using: placement)
            selectedClipID = clipID
            selectedTrackID = project.tracks.first(where: { $0.clips.contains { $0.id == clipID } })?.id
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
            selectedTrackID = project.tracks.first(where: { $0.clips.contains { $0.id == clipID } })?.id
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
        }

        var result: TimelineTrimResult?
        mutateProject(
            rebuild: !interactive && rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            guard let location = project.clipLocation(id: clipID) else { return }
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
            project.tracks[location.track].clips[location.clip] = clip
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
            selectedClipID = clip.id
            result = TimelineTrimResult(
                edgeTime: clip.timelineStart,
                appliedDelta: applied,
                snapped: snap.snapped && abs((reference.timelineStart + applied) - snap.time) < 0.001
            )
        }
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
        }

        var result: TimelineTrimResult?
        mutateProject(
            rebuild: !interactive && rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            guard let location = project.clipLocation(id: clipID) else { return }
            let currentClip = project.tracks[location.track].clips[location.clip]
            let reference = baseline ?? currentClip
            let nextStart = project.neighborBounds(for: currentClip.id, in: location.track).nextStart
            let sourceForwardLimit =
                reference.mediaType == .image
                ? Double.greatestFiniteMagnitude / 4
                : max(reference.source.originalDuration - reference.sourceRange.end, 0)
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
            project.tracks[location.track].clips[location.clip] = clip
            selectedClipID = clip.id
            result = TimelineTrimResult(
                edgeTime: clip.timelineEnd,
                appliedDelta: applied,
                snapped: snap.snapped && abs((reference.timelineEnd + applied) - snap.time) < 0.001
            )
        }
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
            : max(reference.source.originalDuration - reference.sourceRange.end, 0)
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
