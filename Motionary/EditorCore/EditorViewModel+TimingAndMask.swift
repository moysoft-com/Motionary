// Speed and mask editing for typed timeline items.

import Foundation

struct SpeedEditSession: Equatable {
    fileprivate let itemID: UUID
}

struct TimeRemapEditSession {
    fileprivate let itemID: UUID
    fileprivate let localTime: Double
}

extension EditorViewModel {
    func beginSelectedSpeedEditAtPlayhead() -> SpeedEditSession? {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .video || item.mediaType == .audio,
            item.speedMap.timeRemap == nil,
            currentTime >= item.timelineStart, currentTime < item.timelineEnd
        else { return nil }
        beginInteractiveSpeedEdit()
        return SpeedEditSession(itemID: item.id)
    }

    private func beginInteractiveSpeedEdit() {
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

    func setSelectedTimeRemapEnabled(_ enabled: Bool) {
        updateSelectedSpeedMap(preserveSourceTime: enabled) { item in
            if enabled {
                guard item.speedMap.timeRemap == nil else { return item.speedMap }
                var map = item.speedMap
                map.timeRemap = TimeRemap(
                    sourceDuration: item.sourceRange.duration,
                    timelineDuration: item.timelineDuration
                )
                return map
            }
            guard item.speedMap.timeRemap != nil else { return item.speedMap }
            return .constant(speed: item.speedMap.constantSpeed)
        }
    }

    func beginSelectedTimeRemapEdit(itemID: UUID) -> TimeRemapEditSession? {
        guard let (item, time) = selectedTimeRemapContext, item.id == itemID else { return nil }
        beginInteractiveSpeedEdit()
        let keyframeTime = item.timelineStart + time
        if abs(currentTime - keyframeTime) > 0.000_001 {
            seek(to: keyframeTime)
        }
        return TimeRemapEditSession(itemID: itemID, localTime: time)
    }

    func setSelectedRemappedSourceTime(_ time: Double, in session: TimeRemapEditSession) {
        updateSelectedSpeedMap(itemID: session.itemID, interactive: true, preserveSourceTime: false) { item in
            var map = item.speedMap
            map.timeRemap?.setSourceTime(time, at: session.localTime, tolerance: keyframeTimeTolerance)
            return map
        }
    }

    func toggleSelectedTimeRemapKeyframe() {
        guard let (item, time) = selectedTimeRemapContext else { return }
        updateSelectedSpeedMap(itemID: item.id, preserveSourceTime: false) { item in
            var map = item.speedMap
            map.timeRemap?.toggleKeyframe(at: time, tolerance: keyframeTimeTolerance)
            return map
        }
    }

    func setSelectedTimeRemapInterpolation(
        _ interpolation: KeyframeInterpolation,
        startTime: Double,
        interactive: Bool
    ) {
        updateSelectedSpeedMap(interactive: interactive, preserveSourceTime: false) { item in
            var map = item.speedMap
            map.timeRemap?.setInterpolation(interpolation, at: startTime)
            return map
        }
    }

    func timeRemapGraphSegment(for item: MediaTimelineItem) -> KeyframeSegment? {
        let time = currentTime - item.timelineStart
        guard let remap = item.speedMap.timeRemap, remap.keyframes.count >= 2,
            time >= -keyframeTimeTolerance, time <= remap.duration + keyframeTimeTolerance
        else { return nil }
        let index = remap.graphIndex(at: time, tolerance: keyframeTimeTolerance)
        return KeyframeSegment(
            clipID: item.id,
            section: .speed,
            effectID: nil,
            startTime: remap.keyframes[index].time,
            endTime: remap.keyframes[index + 1].time,
            interpolation: remap.keyframes[index].interpolation
        )
    }

    func timeRemapEditTime(at localTime: Double, in remap: TimeRemap) -> Double {
        if let index = remap.keyframeIndex(at: localTime, tolerance: keyframeTimeTolerance) {
            return remap.keyframes[index].time
        }
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        return min(max((localTime * frameRate).rounded() / frameRate, 0), remap.duration)
    }

    private var selectedTimeRemapContext: (MediaTimelineItem, Double)? {
        guard case .media(let item) = selectedTimelineItem,
            let remap = item.speedMap.timeRemap,
            currentTime >= item.timelineStart - keyframeTimeTolerance,
            currentTime <= item.timelineEnd + keyframeTimeTolerance
        else { return nil }
        return (item, timeRemapEditTime(at: currentTime - item.timelineStart, in: remap))
    }

    func setSelectedPitchFollowsSpeed(_ followsSpeed: Bool) {
        applyTimingAndMaskMutation { project in
            guard let selectedTimelineItemID = self.selectedTimelineItemID,
                let location = project.itemLocation(id: selectedTimelineItemID),
                !project.tracks[location.track].isLocked,
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
        preserveSourceTime: Bool = true,
        _ speedMap: (MediaTimelineItem) -> SpeedMap
    ) -> Bool {
        guard let itemID = requestedItemID ?? selectedTimelineItemID,
            selectedTimelineItemID == itemID,
            let location = project.itemLocation(id: itemID),
            !project.tracks[location.track].isLocked,
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
        if preserveSourceTime, currentTime >= currentItem.timelineStart,
            currentTime <= currentItem.timelineEnd
        {
            anchoredSourceTime = currentItem.speedMap.sourceTime(
                at: currentTime - currentItem.timelineStart,
                sourceDuration: currentItem.sourceRange.duration
            )
        } else {
            anchoredSourceTime = nil
        }

        var updatedItem = currentItem
        updatedItem.speedMap = speedMap(currentItem)
        let durationDelta = updatedItem.timelineDuration - currentItem.timelineDuration
        guard abs(durationDelta) > 0.000_001 || updatedItem.speedMap != currentItem.speedMap else {
            clearSpeedEditErrorIfNeeded()
            return true
        }

        if !isRippleEditingEnabled, durationDelta > 0,
            let nextStart = nextClipStart(after: currentItem, in: location.track),
            updatedItem.timelineEnd > nextStart + 0.000_001
        {
            if interactive {
                clearSpeedEditErrorIfNeeded()
            } else {
                errorMessage =
                    "This speed would overlap the next clip. Enable ripple editing or leave more room."
            }
            return false
        }

        let retimingChanged = abs(durationDelta) > 0.000_001
            || updatedItem.speedMap.topologySignature != currentItem.speedMap.topologySignature
        applyTimingAndMaskMutation(interactive: interactive) { project in
            guard let currentLocation = project.itemLocation(id: itemID) else { return }
            project.tracks[currentLocation.track].items[currentLocation.item] = .media(updatedItem)
            if self.isRippleEditingEnabled, abs(durationDelta) > 0.000_001 {
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
        if let anchoredSourceTime, retimingChanged {
            let anchoredTime = updatedItem.timelineStart
                + updatedItem.speedMap.timelineTime(
                    at: anchoredSourceTime,
                    sourceDuration: updatedItem.sourceRange.duration
                )
            updateCurrentTime(clampedTimelineTime(anchoredTime))
        }
        if interactive, retimingChanged,
            updatedItem.mediaType == .video, updatedItem.speedMap.timeRemap != nil
        {
            renderService.livePreviewState.setSpeedMap(updatedItem.speedMap, for: itemID)
            pendingLiveVisualOverrideItemIDs.insert(itemID)
            scheduleLivePreviewFrameRefresh()
        } else if interactive, retimingChanged, updatedItem.speedMap.timeRemap == nil {
            scheduleInteractivePreviewRebuild(
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        } else if !interactive, anchoredSourceTime != nil, retimingChanged {
            schedulePreviewRebuild(
                seekTo: currentTime,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        }
        if !interactive, graphSegment?.section == .speed {
            refreshGraphSegment()
        }
        clearSpeedEditErrorIfNeeded()
        return true
    }

    private func nextClipStart(after item: MediaTimelineItem, in trackIndex: Int) -> Double? {
        project.tracks[trackIndex].items.lazy
            .filter { $0.id != item.id && $0.timelineStart >= item.timelineEnd - 0.000_001 }
            .map(\.timelineStart)
            .min()
    }

    private func clearSpeedEditErrorIfNeeded() {
        guard errorMessage != nil else { return }
        errorMessage = nil
    }

    func setSelectedMask(_ mask: ItemMask?) {
        updateSelectedVisuals { visuals in
            visuals.mask = mask
        }
    }

    func setSelectedMaskSize(
        widthScale: Double? = nil,
        heightScale: Double? = nil,
        featherScale: Double? = nil,
        interactive: Bool = false
    ) {
        updateSelectedVisuals(interactive: interactive) { visuals in
            var mask = visuals.mask ?? ItemMask()
            if let widthScale, widthScale.isFinite { mask.widthScale = min(max(widthScale, 0), 1) }
            if let heightScale, heightScale.isFinite { mask.heightScale = min(max(heightScale, 0), 1) }
            if let featherScale, featherScale.isFinite { mask.featherScale = min(max(featherScale, 0), 1) }
            visuals.mask = mask
        }
    }

    func setSelectedMaskGeometry(
        roundnessScale: Double? = nil,
        rotationDegrees: Double? = nil,
        offsetScale: Double? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil,
        isInverted: Bool? = nil,
        interactive: Bool = false
    ) {
        updateSelectedVisuals(interactive: interactive) { visuals in
            var mask = visuals.mask ?? ItemMask()
            if let roundnessScale, roundnessScale.isFinite {
                mask.roundnessScale = min(max(roundnessScale, 0), 1)
            }
            if let rotationDegrees, rotationDegrees.isFinite {
                mask.rotationDegrees = rotationDegrees
            }
            if let offsetScale, offsetScale.isFinite {
                mask.offsetScale = min(max(offsetScale, -1), 1)
            }
            if let offsetX, offsetX.isFinite { mask.offsetX = min(max(offsetX, -1), 1) }
            if let offsetY, offsetY.isFinite { mask.offsetY = min(max(offsetY, -1), 1) }
            if let isInverted { mask.isInverted = isInverted }
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
}
