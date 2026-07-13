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
        let before = project.tracks[location.track].clips[location.clip]
        var after = before
        update(&after)
        guard after != before else { return }
        var invalidation: EditorInvalidation = [.userInterface, .persistence]
        if rebuild {
            invalidation.formUnion(EditorProject.renderInvalidation(before: before, after: after))
        }
        if refreshTimeline {
            invalidation.insert(.timelineLayout)
        }
        perform(
            AnyEditorCommand(
                ReplaceClipCommand(
                    before: before,
                    after: after,
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

    func beginInteractiveEdit() {
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = project
        }
    }

    func finishInteractiveEdit(rebuild: Bool = true) {
        setPreviewQualityForInteraction(false)
        guard let snapshot = interactiveEditSnapshot else {
            persist()
            if rebuild {
                schedulePreviewRebuild(seekTo: currentTime)
            }
            return
        }

        interactiveEditSnapshot = nil
        guard project != snapshot else { return }
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
        if rebuild {
            schedulePreviewRebuild(
                seekTo: currentTime,
                invalidation: renderInvalidation
            )
        }
    }

    func addKeyframe(_ target: KeyframeTarget) {
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
