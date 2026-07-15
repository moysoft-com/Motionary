// Speed and mask editing for typed timeline items.

import Foundation

struct SpeedEditSession: Equatable {
    fileprivate let itemID: UUID
}

extension EditorViewModel {
    var selectedSpeedAtPlayhead: Double? {
        guard let context = selectedSpeedContext else { return nil }
        return context.item.speedMap.speed(at: 0)
    }

    func beginSelectedSpeedEditAtPlayhead() -> SpeedEditSession? {
        guard let context = selectedSpeedContext else { return nil }
        beginInteractiveSpeedEdit()
        return SpeedEditSession(
            itemID: context.item.id
        )
    }

    func beginInteractiveSpeedEdit() {
        player?.pause()
        isPlaying = false
        beginInteractiveEdit()
    }

    @discardableResult
    func setSelectedSpeed(
        _ speed: Double,
        in session: SpeedEditSession,
        interactive: Bool = false
    ) -> Bool {
        guard selectedTimelineItemID == session.itemID else { return false }
        return updateSelectedSpeedMap(itemID: session.itemID, interactive: interactive) { _ in
            .constant(speed: speed)
        }
    }

    @discardableResult
    func setSelectedConstantSpeed(_ speed: Double, interactive: Bool = false) -> Bool {
        updateSelectedSpeedMap(interactive: interactive) { _ in
            .constant(speed: speed)
        }
    }

    @discardableResult
    func setSelectedSpeedAtPlayhead(_ speed: Double, interactive: Bool = false) -> Bool {
        setSelectedConstantSpeed(speed, interactive: interactive)
    }

    @discardableResult
    func setSelectedSpeedKeyframe(
        atSourceTime sourceTime: Double,
        speed: Double,
        interactive: Bool = false
    ) -> Bool {
        setSelectedConstantSpeed(speed, interactive: interactive)
    }

    func setSelectedPitchFollowsSpeed(_ followsSpeed: Bool) {
        applyTimingAndMaskMutation { project in
            guard let selectedTimelineItemID = self.selectedTimelineItemID,
                let location = project.itemLocation(id: selectedTimelineItemID),
                case .media(var item) = project.tracks[location.track].items[location.item],
                item.mediaType == .video || item.mediaType == .audio
            else { return }
            item.pitchFollowsSpeed = followsSpeed
            project.tracks[location.track].items[location.item] = .media(item)
        }
    }

    @discardableResult
    private func updateSelectedSpeedMap(
        itemID requestedItemID: UUID? = nil,
        interactive: Bool = false,
        _ speedMap: (MediaTimelineItem) -> SpeedMap
    ) -> Bool {
        guard let itemID = requestedItemID ?? selectedTimelineItemID,
            selectedTimelineItemID == itemID,
            let location = project.itemLocation(id: itemID),
            case .media(let currentItem) = project.tracks[location.track].items[location.item],
            currentItem.mediaType == .video || currentItem.mediaType == .audio
        else { return false }

        if isPlaying {
            player?.pause()
            isPlaying = false
        }
        if interactive {
            beginInteractiveEdit()
        }

        let anchoredSourceTime: Double?
        if currentTime >= currentItem.timelineStart,
            currentTime < currentItem.timelineEnd
        {
            anchoredSourceTime = currentItem.speedMap.sourceTime(
                at: currentTime - currentItem.timelineStart,
                sourceDuration: currentItem.sourceRange.duration
            )
        } else {
            anchoredSourceTime = nil
        }

        var updatedItem = currentItem
        updatedItem.speedMap = .constant(speed: speedMap(currentItem).speed(at: 0))
        let durationDelta = updatedItem.timelineDuration - currentItem.timelineDuration
        guard abs(durationDelta) > 0.000_001 || updatedItem.speedMap != currentItem.speedMap else {
            errorMessage = nil
            return true
        }

        if !isRippleEditingEnabled, durationDelta > 0,
            let nextStart = project.tracks[location.track].items
                .filter({ $0.id != currentItem.id && $0.timelineStart >= currentItem.timelineEnd - 0.000_001 })
                .map(\.timelineStart)
                .min(),
            updatedItem.timelineEnd > nextStart + 0.000_001
        {
            errorMessage = interactive
                ? nil
                : "This speed would overlap the next clip. Enable ripple editing or leave more room."
            return false
        }

        applyTimingAndMaskMutation(interactive: interactive) { project in
            guard let currentLocation = project.itemLocation(id: itemID) else { return }
            project.tracks[currentLocation.track].items[currentLocation.item] = .media(updatedItem)
            if self.isRippleEditingEnabled {
                for index in project.tracks[currentLocation.track].items.indices
                where project.tracks[currentLocation.track].items[index].id != itemID
                    && project.tracks[currentLocation.track].items[index].timelineStart
                        >= currentItem.timelineEnd - 0.000_001
                {
                    project.tracks[currentLocation.track].items[index].timelineStart = max(
                        project.tracks[currentLocation.track].items[index].timelineStart + durationDelta,
                        updatedItem.timelineEnd
                    )
                }
                project.tracks[currentLocation.track].sortItems()
            }
        }
        if let anchoredSourceTime {
            let anchoredTime = updatedItem.timelineStart
                + updatedItem.speedMap.timelineTime(
                    at: anchoredSourceTime,
                    sourceDuration: updatedItem.sourceRange.duration
                )
            updateCurrentTime(clampedTimelineTime(anchoredTime))
        }
        if interactive {
            scheduleInteractivePreviewRebuild(
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        } else if anchoredSourceTime != nil {
            schedulePreviewRebuild(
                seekTo: currentTime,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        }
        if graphSegment?.section == .speed {
            refreshGraphSegment()
        }
        errorMessage = nil
        return true
    }

    func setSelectedMaskEnabled(_ isEnabled: Bool) {
        updateSelectedVisuals { visuals in
            visuals.mask = isEnabled ? (visuals.mask ?? ItemMask()) : nil
        }
    }

    func setSelectedMaskShape(_ shape: ItemMask.Shape) {
        updateSelectedVisuals { visuals in
            var mask = visuals.mask ?? ItemMask()
            mask.shape = shape
            visuals.mask = mask
        }
    }

    func setSelectedMaskInsets(
        horizontal: Double? = nil,
        vertical: Double? = nil,
        feather: Double? = nil,
        interactive: Bool = false
    ) {
        updateSelectedVisuals(interactive: interactive) { visuals in
            var mask = visuals.mask ?? ItemMask()
            if let horizontal { mask.insetX = min(max(horizontal, 0), 0.48) }
            if let vertical { mask.insetY = min(max(vertical, 0), 0.48) }
            if let feather { mask.feather = min(max(feather, 0), 0.25) }
            visuals.mask = mask
        }
    }

    private func updateSelectedVisuals(
        interactive: Bool = false,
        _ update: @escaping (inout TimelineItemVisuals) -> Void
    ) {
        applyTimingAndMaskMutation(interactive: interactive) { project in
            guard let selectedTimelineItemID = self.selectedTimelineItemID,
                var item = project.item(id: selectedTimelineItemID),
                var visuals = item.editableVisuals
            else { return }
            update(&visuals)
            item.editableVisuals = visuals
            project.replaceItem(id: selectedTimelineItemID, with: item)
        }
        if interactive {
            scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        }
    }

    private func applyTimingAndMaskMutation(
        interactive: Bool = false,
        _ mutation: @escaping (inout EditorProject) -> Void
    ) {
        mutateProject(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            mutation
        )
        if interactive {
            updateCurrentTime(clampedTimelineTime(currentTime))
        }
    }

    private var selectedSpeedContext: (
        item: MediaTimelineItem,
        sourceTime: Double
    )? {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .video || item.mediaType == .audio,
            currentTime >= item.timelineStart,
            currentTime < item.timelineEnd
        else { return nil }
        let localTimelineTime = min(
            max(currentTime - item.timelineStart, 0),
            item.timelineDuration
        )
        let sourceTime = item.speedMap.sourceTime(
            at: localTimelineTime,
            sourceDuration: item.sourceRange.duration
        )
        return (item, sourceTime)
    }
}
