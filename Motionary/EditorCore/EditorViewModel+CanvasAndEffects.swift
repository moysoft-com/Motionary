// Canvas sizing, clip transforms, effects, and keyframe editing.

import Foundation

extension EditorViewModel {
    func setCanvasPreset(_ preset: CanvasRatioPreset) {
        mutateProject {
            $0.renderSettings = preset.settings(frameRate: $0.renderSettings.frameRate)
        }
    }

    var canApplySelectedClipOriginalRatio: Bool {
        guard let clip = selectedClip, clip.mediaType != .audio else { return false }
        return clip.source.naturalSize != nil
    }

    func setCanvasToSelectedClipOriginalRatio() {
        guard let clip = selectedClip,
            clip.mediaType != .audio,
            let naturalSize = clip.source.naturalSize?.displaySafeSize
        else { return }

        mutateProject {
            $0.renderSettings = RenderSettings(size: naturalSize, frameRate: $0.renderSettings.frameRate)
        }
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
        mutateProject(
            rebuild: rebuild,
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        ) { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            update(&project.tracks[location.track].clips[location.clip])
        }
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
        guard let snapshot = interactiveEditSnapshot else {
            persist()
            if rebuild {
                schedulePreviewRebuild(seekTo: currentTime)
            }
            return
        }

        interactiveEditSnapshot = nil
        guard project != snapshot else { return }

        undoStack.append(snapshot)
        if undoStack.count > 80 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateHistoryFlags()
        project.updatedAt = Date()
        persist()
        if rebuild {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    func addKeyframe(_ target: KeyframeTarget) {
        guard let selectedClipID else { return }
        activeKeyframeTarget = target
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            let time = self.snappedKeyframeTime(self.currentTime - clip.timelineStart, clip: clip)
            if target.isScaleTarget {
                self.selectedKeyframeID = clip.transform.scale.setKeyframe(
                    at: time,
                    value: clip.transform.scale.value(at: time),
                    tolerance: self.keyframeTimeTolerance
                )
                project.tracks[location.track].clips[location.clip] = clip
                return
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            self.selectedKeyframeID = property.setKeyframe(
                at: time,
                value: property.value(at: time),
                tolerance: self.keyframeTimeTolerance
            )
            clip.setAnimatableProperty(property, for: target)

            project.tracks[location.track].clips[location.clip] = clip
        }
    }
}
