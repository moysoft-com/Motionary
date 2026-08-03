// Canvas sizing, clip transforms, effects, and keyframe editing.

import Foundation

extension EditorViewModel {
    func setCanvasPreset(_ preset: CanvasRatioPreset) {
        let before = project.renderSettings
        let after = preset.settings(
            frameRate: before.frameRate,
            backgroundColor: before.backgroundColor
        )
        commit(
            EditorCommandFactory.setRenderSettings(
                before: before,
                after: after,
                invalidation: [.previewFrame, .compositionTopology, .persistence, .userInterface]
            )
        )
    }

    func setCanvasBackgroundColor(_ color: RGBAColor) {
        let before = project.renderSettings
        var after = before
        after.backgroundColor = color
        commit(
            EditorCommandFactory.setRenderSettings(
                before: before,
                after: after,
                invalidation: [.previewFrame, .persistence]
            ),
            refreshTimeline: false
        )
    }

    func setSelectedShape(
        color: RGBAColor? = nil
    ) {
        updateSelectedClip { clip in
            guard var shape = clip.shape else { return }
            if let color { shape.color = color }
            clip.shape = shape
        }
    }

    var canApplySelectedClipOriginalRatio: Bool {
        guard let clip = selectedClip, clip.mediaType != .audio else { return false }
        return project.naturalSize(for: clip) != nil
    }

    func setCanvasToSelectedClipOriginalRatio() {
        guard let clip = selectedClip,
            clip.mediaType != .audio,
            let naturalSize = project.naturalSize(for: clip)?.displaySafeSize
        else { return }

        let before = project.renderSettings
        let after = RenderSettings(
            size: naturalSize,
            frameRate: before.frameRate,
            backgroundColor: before.backgroundColor
        )
        commit(
            EditorCommandFactory.setRenderSettings(
                before: before,
                after: after,
                invalidation: [.previewFrame, .compositionTopology, .persistence, .userInterface]
            )
        )
    }

    func updateSelectedClip(
        rebuild: Bool = true,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        _ update: (inout TimelineClip) -> Void
    ) {
        guard let selectedClipID else { return }
        guard let location = project.clipLocation(id: selectedClipID) else { return }
        let beforeItem = project.tracks[location.track].items[location.clip]
        guard var updatedClip = beforeItem.visualEditingClip() else { return }
        let beforeClip = updatedClip
        update(&updatedClip)
        guard updatedClip != beforeClip else { return }
        let afterItem = beforeItem.mergingVisualEditingClip(updatedClip)
        var invalidation: EditorInvalidation = [.userInterface, .persistence]
        if rebuild {
            invalidation.formUnion(EditorProject.renderInvalidation(before: beforeClip, after: updatedClip))
        }
        if refreshTimeline {
            invalidation.insert(.timelineLayout)
        }
        perform(
            AnyEditorCommand(
                ReplaceClipCommand(
                    before: beforeItem,
                    after: afterItem,
                    invalidation: invalidation
                )
            ),
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        )
    }

    func setSelectedTransform(
        positionX: Double? = nil,
        positionY: Double? = nil,
        scale: Double? = nil,
        rotationDegrees: Double? = nil,
        opacity: Double? = nil,
        isFlippedHorizontally: Bool? = nil,
        isFlippedVertically: Bool? = nil,
        interactive: Bool = false
    ) {
        if let positionX {
            setSelectedKeyframeValue(positionX, target: .positionX, interactive: interactive)
        }
        if let positionY {
            setSelectedKeyframeValue(positionY, target: .positionY, interactive: interactive)
        }
        if let scale {
            setSelectedKeyframeValue(scale, target: .scale, interactive: interactive)
        }
        if let rotationDegrees {
            setSelectedKeyframeValue(rotationDegrees, target: .rotation, interactive: interactive)
        }
        if let opacity {
            setSelectedKeyframeValue(opacity, target: .opacity, interactive: interactive)
        }

        if isFlippedHorizontally != nil || isFlippedVertically != nil {
            if interactive {
                beginInteractiveEdit()
            }
            updateSelectedClip(
                rebuild: !interactive,
                recordHistory: !interactive,
                persistChanges: !interactive,
                touchUpdatedAt: !interactive,
                refreshTimeline: false
            ) { clip in
                if let isFlippedHorizontally {
                    clip.transform.isFlippedHorizontally = isFlippedHorizontally
                }
                if let isFlippedVertically {
                    clip.transform.isFlippedVertically = isFlippedVertically
                }
            }
        }
    }

    func setSelectedAdjustmentTransform(
        positionX: Double? = nil,
        positionY: Double? = nil,
        scale: ScaleValue? = nil,
        rotationDegrees: Double? = nil,
        interactive: Bool = false
    ) {
        guard case .adjustment = selectedTimelineItem,
            let itemID = selectedTimelineItemID
        else { return }
        if interactive {
            beginInteractiveEdit()
        }

        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        let tolerance = keyframeTimeTolerance
        mutateProject(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            // A canvas transform can create or move an adjustment keyframe.
            // Defer the affected-track snapshot refresh during interaction, then
            // publish it once when the edit transaction commits.
            refreshTimeline: true
        ) { project in
            guard let location = project.itemLocation(id: itemID),
                case .adjustment(var item) = project.tracks[location.track].items[location.item]
            else { return }

            let localTime = min(
                max(((self.currentTime - item.timelineStart) * frameRate).rounded() / frameRate, 0),
                item.duration
            )
            if let positionX, positionX.isFinite {
                item.visuals.transform.positionX.setCanvasValue(
                    positionX,
                    at: localTime,
                    tolerance: tolerance
                )
            }
            if let positionY, positionY.isFinite {
                item.visuals.transform.positionY.setCanvasValue(
                    positionY,
                    at: localTime,
                    tolerance: tolerance
                )
            }
            if let scale {
                let boundedScale = ScaleValue(
                    x: min(max(scale.x.isFinite ? scale.x : 1, 0.01), 100),
                    y: min(max(scale.y.isFinite ? scale.y : 1, 0.01), 100)
                )
                item.visuals.transform.scale.setCanvasValue(
                    boundedScale,
                    at: localTime,
                    tolerance: tolerance
                )
            }
            if let rotationDegrees, rotationDegrees.isFinite {
                item.visuals.transform.rotationDegrees.setCanvasValue(
                    rotationDegrees,
                    at: localTime,
                    tolerance: tolerance
                )
            }
            project.tracks[location.track].items[location.item] = .adjustment(item)
        }
        if interactive {
            scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        }
    }

    func beginInteractiveEdit() {
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = project
        }
    }

    func finishInteractiveEdit(
        rebuild: Bool = true,
        delayRebuild: Bool = true,
        preserveLivePreviewRefresh: Bool = false
    ) {
        cancelInteractivePreviewRebuild(cancelLivePreviewRefresh: !preserveLivePreviewRefresh)
        setPreviewQualityForInteraction(false)
        guard let snapshot = interactiveEditSnapshot else {
            persist()
            if rebuild {
                schedulePreviewRebuild(seekTo: currentTime, delay: delayRebuild)
            }
            return
        }

        interactiveEditSnapshot = nil
        project.renumberTracks()
        project.synchronizeMediaLibrary()
        guard project != snapshot else {
            clearPendingLiveVisualOverrides()
            pendingTimelineInvalidationScope = nil
            refreshSelectedTimelineRange()
            return
        }
        publishProjectChange()
        refreshSelectedTimelineRange()
        flushPendingTimelineContentInvalidation()
        let renderInvalidation = project.renderInvalidation(comparedTo: snapshot)
        let command = project.historyCommand(
            from: snapshot,
            invalidation: renderInvalidation.union([.userInterface, .persistence])
        )
        undoStack.append(command)
        if undoStack.count > 80 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateHistoryFlags()
        project.updatedAt = Date()
        persist()
        if rebuild, prepareSelectedBackgroundRemovalExtensionIfNeeded() {
            return
        }
        if rebuild {
            schedulePreviewRebuild(
                seekTo: currentTime,
                // Audio-only commits already use a retained topology and do
                // not seek. Apply their canonical mix immediately after the
                // live task is cancelled so the final scrub value is audible
                // without a debounce gap.
                delay: delayRebuild && renderInvalidation != [.audioMix],
                invalidation: renderInvalidation
            )
        }
    }

    func addKeyframe(_ target: KeyframeTarget) {
        if selectedTextItem != nil {
            guard !textHasKeyframe(atPlayhead: target) else { return }
            toggleTextKeyframe(target)
            return
        }
        guard selectedClipID != nil else { return }
        activeKeyframeTarget = target
        updateSelectedClip { clip in
            let time = self.snappedKeyframeTime(self.currentTime - clip.timelineStart, clip: clip)
            if target.isScaleTarget {
                self.selectedKeyframeID = clip.transform.scale.setKeyframe(
                    at: time,
                    value: clip.transform.scale.value(at: time),
                    tolerance: self.keyframeTimeTolerance
                )
                return
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            self.selectedKeyframeID = property.setKeyframe(
                at: time,
                value: property.value(at: time),
                tolerance: self.keyframeTimeTolerance
            )
            clip.setAnimatableProperty(property, for: target)
        }
    }
}

private extension AnimatableProperty where Value == Double {
    mutating func setCanvasValue(
        _ value: Double,
        at time: Double,
        tolerance: Double
    ) {
        if keyframes.isEmpty {
            baseValue = value
        } else {
            _ = setKeyframe(at: time, value: value, tolerance: tolerance)
        }
    }
}

private extension AnimatableScale {
    mutating func setCanvasValue(
        _ value: ScaleValue,
        at time: Double,
        tolerance: Double
    ) {
        if keyframes.isEmpty {
            baseValue = value
        } else {
            _ = setKeyframe(at: time, value: value, tolerance: tolerance)
        }
    }
}
