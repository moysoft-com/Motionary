// Unified keyframe editing commands for inspectors, the graph editor, and direct manipulation.

import Foundation

extension EditorViewModel {
    var selectedClipLocalTime: Double {
        guard let clip = selectedClip else { return 0 }
        return min(max(currentTime - clip.timelineStart, 0), clip.sourceRange.duration)
    }

    var keyframeTimeTolerance: Double {
        0.5 / Double(max(project.renderSettings.frameRate, 1))
    }

    func snappedKeyframeTime(_ time: Double, clip: TimelineClip? = nil) -> Double {
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        let snapped = max((time * frameRate).rounded() / frameRate, 0)
        guard let duration = clip?.sourceRange.duration ?? selectedClip?.sourceRange.duration else {
            return snapped
        }
        return min(snapped, duration)
    }

    func displayedValue(for target: KeyframeTarget) -> Double {
        guard let clip = selectedClip else { return 0 }
        if target.isScaleTarget {
            let scale = clip.transform.scale.value(at: selectedClipLocalTime)
            return target == .scaleY ? scale.y : scale.x
        }
        guard
            let property = clip.animatableProperty(for: target)
        else { return 0 }
        return property.value(at: selectedClipLocalTime)
    }

    func hasKeyframe(atPlayhead target: KeyframeTarget) -> Bool {
        guard let property = selectedClip?.animatableProperty(for: target) else { return false }
        return property.keyframeIndex(
            at: snappedKeyframeTime(selectedClipLocalTime),
            tolerance: keyframeTimeTolerance
        ) != nil
    }

    func propertyRange(
        for target: KeyframeTarget,
        clip: TimelineClip? = nil
    ) -> ClosedRange<Double> {
        guard let clip = clip ?? selectedClip else {
            return target == .rotation
                ? -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
                : -1...1
        }
        switch target {
        case .positionX, .positionY:
            let canvas = project.renderSettings.size
            let source = clip.source.naturalSize?.displaySafeSize ?? canvas
            let fitScale = min(
                canvas.width / max(source.width, 1),
                canvas.height / max(source.height, 1)
            )
            let localTime = min(
                max(currentTime - clip.timelineStart, 0),
                clip.sourceRange.duration
            )
            let scale = clip.transform.scale.value(at: localTime)
            let width = source.width * fitScale * max(scale.x, 0.01)
            let height = source.height * fitScale * max(scale.y, 0.01)
            let radians = clip.transform.rotationDegrees.value(at: localTime) * .pi / 180
            let rotatedWidth = abs(width * cos(radians)) + abs(height * sin(radians))
            let rotatedHeight = abs(width * sin(radians)) + abs(height * cos(radians))
            let maximum =
                target == .positionX
                ? 1 + Double(rotatedWidth / max(canvas.width, 1))
                : 1 + Double(rotatedHeight / max(canvas.height, 1))
            return -maximum...maximum
        case .rotation:
            return -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        default:
            return clip.keyframeMetadata(for: target).range
        }
    }

    var candidateGraphSegment: KeyframeSegment? {
        guard let clip = selectedClip,
            isTimeInside(clip),
            let target = activeKeyframeTarget,
            let property = clip.animatableProperty(for: target)
        else { return nil }
        let frames = property.keyframes.sorted { $0.time < $1.time }
        guard frames.count >= 2 else { return nil }
        let localTime = currentTime - clip.timelineStart

        let leftIndex: Int?
        if let exact = frames.firstIndex(
            where: { abs($0.time - localTime) <= keyframeTimeTolerance }
        ) {
            leftIndex = exact < frames.count - 1 ? exact : exact - 1
        } else {
            leftIndex = frames.indices.dropLast().first {
                localTime > frames[$0].time && localTime < frames[$0 + 1].time
            }
        }
        guard let leftIndex, leftIndex >= 0, leftIndex + 1 < frames.count else {
            return nil
        }
        let left = frames[leftIndex]
        let right = frames[leftIndex + 1]
        return KeyframeSegment(
            clipID: clip.id,
            target: target,
            leftKeyframeID: left.id,
            rightKeyframeID: right.id,
            startTime: left.time,
            endTime: right.time,
            interpolation: left.interpolation
        )
    }

    func openCandidateGraphSegment() {
        guard let segment = candidateGraphSegment else { return }
        graphSegment = segment
        selectedKeyframeID = segment.leftKeyframeID
    }

    func refreshGraphSegment() {
        guard let segment = graphSegment,
            let clip = project.clip(id: segment.clipID),
            let property = clip.animatableProperty(for: segment.target)
        else {
            graphSegment = nil
            return
        }
        let frames = property.keyframes.sorted { $0.time < $1.time }
        guard let leftIndex = frames.firstIndex(where: { $0.id == segment.leftKeyframeID }),
            leftIndex + 1 < frames.count,
            frames[leftIndex + 1].id == segment.rightKeyframeID
        else {
            graphSegment = nil
            return
        }
        let left = frames[leftIndex]
        let right = frames[leftIndex + 1]
        graphSegment = KeyframeSegment(
            clipID: segment.clipID,
            target: segment.target,
            leftKeyframeID: left.id,
            rightKeyframeID: right.id,
            startTime: left.time,
            endTime: right.time,
            interpolation: left.interpolation
        )
    }

    func setSelectedKeyframeValue(
        _ value: Double,
        target: KeyframeTarget,
        interactive: Bool = false
    ) {
        guard selectedClipID != nil else { return }
        if target.isScaleTarget {
            setSelectedScaleValue(value, target: target, interactive: interactive)
            return
        }
        if interactive {
            beginInteractiveEdit()
        }
        activeKeyframeTarget = target

        updateSelectedClip(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: true
        ) { clip in
            guard var property = clip.animatableProperty(for: target) else { return }
            let range = self.propertyRange(for: target, clip: clip)
            let boundedValue = min(max(value, range.lowerBound), range.upperBound)
            let localTime = self.snappedKeyframeTime(
                self.currentTime - clip.timelineStart,
                clip: clip
            )

            if property.keyframes.isEmpty {
                property.baseValue = boundedValue
            } else if let index = property.keyframeIndex(
                at: localTime,
                tolerance: self.keyframeTimeTolerance
            ) {
                property.keyframes[index].value = boundedValue
                self.selectedKeyframeID = property.keyframes[index].id
            } else if self.isAutoKeyEnabled {
                self.selectedKeyframeID = property.setKeyframe(
                    at: localTime,
                    value: boundedValue,
                    tolerance: self.keyframeTimeTolerance
                )
            } else {
                let delta = boundedValue - property.value(at: localTime)
                property.offsetValues(by: delta, range: range)
            }

            clip.setAnimatableProperty(property, for: target)
        }
        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
        refreshGraphSegment()
    }

    func toggleKeyframe(_ target: KeyframeTarget) {
        guard let selectedClipID else { return }
        activeKeyframeTarget = target
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            if target.isScaleTarget {
                let time = self.snappedKeyframeTime(
                    self.currentTime - clip.timelineStart,
                    clip: clip
                )
                if clip.transform.scale.removeKeyframe(
                    at: time,
                    tolerance: self.keyframeTimeTolerance
                ) {
                    self.selectedKeyframeID = nil
                } else {
                    self.selectedKeyframeID = clip.transform.scale.setKeyframe(
                        at: time,
                        value: clip.transform.scale.value(at: time),
                        tolerance: self.keyframeTimeTolerance
                    )
                }
                project.tracks[location.track].clips[location.clip] = clip
                return
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            let time = self.snappedKeyframeTime(self.currentTime - clip.timelineStart, clip: clip)

            if let index = property.keyframeIndex(
                at: time,
                tolerance: self.keyframeTimeTolerance
            ) {
                property.keyframes.remove(at: index)
                self.selectedKeyframeID = nil
            } else {
                self.selectedKeyframeID = property.setKeyframe(
                    at: time,
                    value: property.value(at: time),
                    tolerance: self.keyframeTimeTolerance
                )
            }
            clip.setAnimatableProperty(property, for: target)
            project.tracks[location.track].clips[location.clip] = clip
        }
    }

    func updateKeyframe(
        target: KeyframeTarget,
        id: UUID,
        time: Double? = nil,
        value: Double? = nil,
        interactive: Bool = false
    ) {
        guard selectedClipID != nil else { return }
        if interactive {
            beginInteractiveEdit()
        }
        activeKeyframeTarget = target
        selectedKeyframeID = id

        updateSelectedClip(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: true
        ) { clip in
            guard var property = clip.animatableProperty(for: target),
                property.keyframes.contains(where: { $0.id == id })
            else { return }
            let metadata = clip.keyframeMetadata(for: target)

            if let time {
                let snapped = self.snappedKeyframeTime(time, clip: clip)
                property.keyframes.removeAll {
                    $0.id != id && abs($0.time - snapped) <= self.keyframeTimeTolerance
                }
                guard let refreshedIndex = property.keyframes.firstIndex(where: { $0.id == id }) else { return }
                property.keyframes[refreshedIndex].time = snapped
            }
            if let value,
                let refreshedIndex = property.keyframes.firstIndex(where: { $0.id == id })
            {
                property.keyframes[refreshedIndex].value = min(
                    max(value, metadata.range.lowerBound),
                    metadata.range.upperBound
                )
            }
            property.keyframes.sort { $0.time < $1.time }
            clip.setAnimatableProperty(property, for: target)
        }
        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
        refreshGraphSegment()
    }

    func removeKeyframe(target: KeyframeTarget, id: UUID) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            if target.isScaleTarget {
                clip.transform.scale.keyframes.removeAll { $0.id == id }
                project.tracks[location.track].clips[location.clip] = clip
                self.selectedKeyframeID = nil
                return
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            property.removeKeyframe(id: id)
            clip.setAnimatableProperty(property, for: target)
            project.tracks[location.track].clips[location.clip] = clip
            self.selectedKeyframeID = nil
        }
    }

    func setInterpolation(
        _ interpolation: KeyframeInterpolation,
        target: KeyframeTarget,
        keyframeID: UUID,
        interactive: Bool = false
    ) {
        guard selectedClipID != nil else { return }
        if interactive {
            beginInteractiveEdit()
        }
        updateSelectedClip(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: true
        ) { clip in
            if target.isScaleTarget {
                clip.transform.scale.setInterpolation(
                    interpolation,
                    keyframeID: keyframeID
                )
                return
            }
            guard var property = clip.animatableProperty(for: target),
                let index = property.keyframes.firstIndex(where: { $0.id == keyframeID })
            else { return }
            property.keyframes[index].interpolation = interpolation
            clip.setAnimatableProperty(property, for: target)
        }
        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
        refreshGraphSegment()
    }

    func selectAdjacentKeyframe(target: KeyframeTarget, direction: Int) {
        guard let clip = selectedClip,
            let property = clip.animatableProperty(for: target),
            !property.keyframes.isEmpty
        else { return }
        let frames = property.keyframes.sorted { $0.time < $1.time }
        let currentIndex =
            selectedKeyframeID.flatMap { id in frames.firstIndex(where: { $0.id == id }) }
            ?? frames.lastIndex(where: { $0.time < selectedClipLocalTime + keyframeTimeTolerance })
            ?? (direction > 0 ? -1 : frames.count)
        let targetIndex = min(max(currentIndex + direction, 0), frames.count - 1)
        let frame = frames[targetIndex]
        selectedKeyframeID = frame.id
        activeKeyframeTarget = target
        seek(to: clip.timelineStart + frame.time)
    }

    func addEffect(_ kind: ClipEffectKind) {
        updateSelectedClip { clip in
            guard clip.mediaType != .audio else { return }
            let effect = ClipEffect(kind: kind)
            clip.effectStack.effects.append(effect)
            self.activeKeyframeTarget = .effectIntensity(effect.id)
        }
    }

    func setEffectEnabled(_ effectID: UUID, enabled: Bool) {
        updateSelectedClip { clip in
            guard let index = clip.effectStack.effects.firstIndex(where: { $0.id == effectID }) else { return }
            clip.effectStack.effects[index].isEnabled = enabled
        }
    }

    func removeEffect(_ effectID: UUID) {
        updateSelectedClip { clip in
            clip.effectStack.effects.removeAll { $0.id == effectID }
            if self.activeKeyframeTarget == .effectIntensity(effectID) {
                self.activeKeyframeTarget = clip.availableKeyframeTargets.first
                self.selectedKeyframeID = nil
            }
        }
    }

    func moveEffect(_ effectID: UUID, offset: Int) {
        updateSelectedClip { clip in
            guard let index = clip.effectStack.effects.firstIndex(where: { $0.id == effectID }) else { return }
            let destination = min(max(index + offset, 0), clip.effectStack.effects.count - 1)
            guard destination != index else { return }
            let effect = clip.effectStack.effects.remove(at: index)
            clip.effectStack.effects.insert(effect, at: destination)
        }
    }

    func setScaleLinked(_ isLinked: Bool) {
        updateSelectedClip { clip in
            clip.transform.scale.isLinked = isLinked
            self.activeKeyframeTarget = isLinked ? .scale : .scaleX
            self.selectedKeyframeID = nil
        }
    }

    private func setSelectedScaleValue(
        _ value: Double,
        target: KeyframeTarget,
        interactive: Bool
    ) {
        if interactive {
            beginInteractiveEdit()
        }
        activeKeyframeTarget = target

        updateSelectedClip(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: true
        ) { clip in
            let localTime = self.snappedKeyframeTime(
                self.currentTime - clip.timelineStart,
                clip: clip
            )
            let boundedValue = min(max(value, 0.01), 100)
            var scale = clip.transform.scale
            let current = scale.value(at: localTime)
            let editsBothAxes = target == .scale

            func adjusted(_ original: ScaleValue) -> ScaleValue {
                if editsBothAxes {
                    let factor = Self.boundedScaleFactor(
                        proposed: boundedValue / max(current.x, 0.000_001),
                        values: [original.x, original.y]
                    )
                    return ScaleValue(x: original.x * factor, y: original.y * factor)
                }
                if target == .scaleY {
                    return ScaleValue(x: original.x, y: boundedValue)
                }
                return ScaleValue(x: boundedValue, y: original.y)
            }

            if scale.keyframes.isEmpty {
                scale.baseValue = adjusted(scale.baseValue)
            } else if let index = scale.keyframes.firstIndex(
                where: { abs($0.time - localTime) <= self.keyframeTimeTolerance }
            ) {
                scale.keyframes[index].value = adjusted(scale.keyframes[index].value)
                self.selectedKeyframeID = scale.keyframes[index].id
            } else if self.isAutoKeyEnabled {
                self.selectedKeyframeID = scale.setKeyframe(
                    at: localTime,
                    value: adjusted(current),
                    tolerance: self.keyframeTimeTolerance
                )
            } else if editsBothAxes {
                let values =
                    [scale.baseValue.x, scale.baseValue.y]
                    + scale.keyframes.flatMap { [$0.value.x, $0.value.y] }
                let factor = Self.boundedScaleFactor(
                    proposed: boundedValue / max(current.x, 0.000_001),
                    values: values
                )
                scale.baseValue.x *= factor
                scale.baseValue.y *= factor
                for index in scale.keyframes.indices {
                    scale.keyframes[index].value.x *= factor
                    scale.keyframes[index].value.y *= factor
                }
            } else {
                let isY = target == .scaleY
                let currentAxis = isY ? current.y : current.x
                let values =
                    [isY ? scale.baseValue.y : scale.baseValue.x]
                    + scale.keyframes.map { isY ? $0.value.y : $0.value.x }
                let factor = Self.boundedScaleFactor(
                    proposed: boundedValue / max(currentAxis, 0.000_001),
                    values: values
                )
                if isY {
                    scale.baseValue.y *= factor
                    for index in scale.keyframes.indices {
                        scale.keyframes[index].value.y *= factor
                    }
                } else {
                    scale.baseValue.x *= factor
                    for index in scale.keyframes.indices {
                        scale.keyframes[index].value.x *= factor
                    }
                }
            }
            clip.transform.scale = scale
        }

        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    nonisolated private static func boundedScaleFactor(
        proposed: Double,
        values: [Double]
    ) -> Double {
        var lower = 0.0
        var upper = Double.greatestFiniteMagnitude
        for value in values where value > 0 {
            lower = max(lower, 0.01 / value)
            upper = min(upper, 100 / value)
        }
        return min(max(proposed, lower), upper)
    }
}
