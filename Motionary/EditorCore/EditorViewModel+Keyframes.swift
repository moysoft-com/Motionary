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

    func hasKeyframe(atPlayhead section: KeyframeSection) -> Bool {
        guard let clip = selectedClip else { return false }
        let time = snappedKeyframeTime(selectedClipLocalTime, clip: clip)
        return clip.keyframeTargets(in: section).contains { target in
            clip.animatableProperty(for: target)?.keyframeIndex(
                at: time,
                tolerance: keyframeTimeTolerance
            ) != nil
        }
    }

    func hasKeyframes(in section: KeyframeSection, clip: TimelineClip? = nil) -> Bool {
        guard let clip = clip ?? selectedClip else { return false }
        return !clip.keyframeTimes(in: section).isEmpty
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
        case .shapeCornerRadius:
            guard let shape = clip.shape else { return 0...4096 }
            let time = min(max(currentTime - clip.timelineStart, 0), clip.sourceRange.duration)
            let maximum = min(shape.width.value(at: time), shape.height.value(at: time)) * 0.5
            return 0...max(maximum, 0)
        case .positionX, .positionY:
            let canvas = project.renderSettings.size
            let source = project.naturalSize(for: clip)?.displaySafeSize ?? canvas
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

    func candidateGraphSegment(in section: KeyframeSection) -> KeyframeSegment? {
        guard let clip = selectedClip, isTimeInside(clip) else { return nil }
        return graphSegmentCandidate(
            in: section,
            clip: clip,
            localTime: currentTime - clip.timelineStart
        )
    }

    private func graphSegmentCandidate(
        in section: KeyframeSection,
        clip: TimelineClip,
        localTime: Double
    ) -> KeyframeSegment? {
        let times = clip.keyframeTimes(in: section)
        guard times.count >= 2 else { return nil }
        let leftIndex: Int?
        if let exact = times.firstIndex(
            where: { abs($0 - localTime) <= keyframeTimeTolerance }
        ) {
            leftIndex = exact < times.count - 1 ? exact : exact - 1
        } else {
            leftIndex = times.indices.dropLast().first {
                localTime > times[$0] && localTime < times[$0 + 1]
            }
        }
        guard let leftIndex, leftIndex >= 0, leftIndex + 1 < times.count else {
            return nil
        }
        let startTime = times[leftIndex]
        let endTime = times[leftIndex + 1]
        let interpolation =
            clip.keyframeTargets(in: section).lazy.compactMap { target in
                clip.animatableProperty(for: target)?.keyframes.first {
                    abs($0.time - startTime) <= self.keyframeTimeTolerance
                }?.interpolation
            }.first
            ?? .linear
        return KeyframeSegment(
            clipID: clip.id,
            section: section,
            startTime: startTime,
            endTime: endTime,
            interpolation: interpolation
        )
    }

    func openCandidateGraphSegment(in section: KeyframeSection) {
        guard let segment = candidateGraphSegment(in: section) else { return }
        graphSegment = segment
        displayedGraphSegment = segment
        activeKeyframeTarget = nil
        selectedKeyframeID = nil
    }

    func selectGraphSegment(atPlayheadIn section: KeyframeSection) {
        graphSegment = candidateGraphSegment(in: section)
        if let graphSegment {
            displayedGraphSegment = graphSegment
        }
        activeKeyframeTarget = nil
        selectedKeyframeID = nil
    }

    func refreshGraphSegment() {
        guard let segment = graphSegment,
            let clip = project.clip(id: segment.clipID)
        else {
            graphSegment = nil
            return
        }
        graphSegment = graphSegmentCandidate(
            in: segment.section,
            clip: clip,
            localTime: currentTime - clip.timelineStart
        )
        if let graphSegment {
            displayedGraphSegment = graphSegment
        }
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
            let localTime = self.snappedKeyframeTime(
                self.currentTime - clip.timelineStart,
                clip: clip
            )
            let section = clip.keyframeSection(for: target)
            if self.hasKeyframes(in: section, clip: clip) {
                self.insertSectionKeyframe(
                    at: localTime,
                    section: section,
                    into: &clip
                )
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            let range = self.propertyRange(for: target, clip: clip)
            let boundedValue = min(max(value, range.lowerBound), range.upperBound)

            if property.keyframes.isEmpty {
                property.baseValue = boundedValue
            } else if let index = property.keyframeIndex(
                at: localTime,
                tolerance: self.keyframeTimeTolerance
            ) {
                property.keyframes[index].value = boundedValue
                self.selectedKeyframeID = property.keyframes[index].id
            } else {
                self.selectedKeyframeID = property.setKeyframe(
                    at: localTime,
                    value: boundedValue,
                    tolerance: self.keyframeTimeTolerance
                )
            }

            clip.setAnimatableProperty(property, for: target)
        }
        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
        refreshGraphSegment()
    }

    func toggleKeyframe(_ target: KeyframeTarget) {
        guard selectedClipID != nil else { return }
        activeKeyframeTarget = target
        updateSelectedClip { clip in
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
        }
    }

    func toggleKeyframeSection(_ section: KeyframeSection) {
        guard selectedClipID != nil else { return }
        updateSelectedClip { clip in
            let time = self.snappedKeyframeTime(
                self.currentTime - clip.timelineStart,
                clip: clip
            )
            let targets = clip.keyframeTargets(in: section)
            let hasMarker = targets.contains { target in
                clip.animatableProperty(for: target)?.keyframeIndex(
                    at: time,
                    tolerance: self.keyframeTimeTolerance
                ) != nil
            }

            if hasMarker {
                self.removeSectionKeyframe(
                    at: time,
                    section: section,
                    from: &clip
                )
                self.selectedKeyframeID = nil
            } else {
                self.insertSectionKeyframe(
                    at: time,
                    section: section,
                    into: &clip
                )
                let preferredTarget =
                    self.activeKeyframeTarget.flatMap { targets.contains($0) ? $0 : nil }
                    ?? targets.first
                self.activeKeyframeTarget = preferredTarget
                self.selectedKeyframeID = preferredTarget.flatMap { target in
                    clip.animatableProperty(for: target)?.keyframes.first {
                        abs($0.time - time) <= self.keyframeTimeTolerance
                    }?.id
                }
            }
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
        guard selectedClipID != nil else { return }
        updateSelectedClip { clip in
            if target.isScaleTarget {
                clip.transform.scale.keyframes.removeAll { $0.id == id }
                self.selectedKeyframeID = nil
                return
            }
            guard var property = clip.animatableProperty(for: target) else { return }
            property.removeKeyframe(id: id)
            clip.setAnimatableProperty(property, for: target)
            self.selectedKeyframeID = nil
        }
    }

    func setInterpolation(
        _ interpolation: KeyframeInterpolation,
        section: KeyframeSection,
        startTime: Double,
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
            let targets = clip.keyframeTargets(in: section)
            if targets.contains(where: \.isScaleTarget),
                let index = clip.transform.scale.keyframes.firstIndex(
                    where: {
                        abs($0.time - startTime) <= self.keyframeTimeTolerance
                    }
                )
            {
                clip.transform.scale.keyframes[index].interpolation = interpolation
            }
            for target in targets where !target.isScaleTarget {
                guard var property = clip.animatableProperty(for: target),
                    let index = property.keyframes.firstIndex(
                        where: {
                            abs($0.time - startTime) <= self.keyframeTimeTolerance
                        }
                    )
                else { continue }
                property.keyframes[index].interpolation = interpolation
                clip.setAnimatableProperty(property, for: target)
            }
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
            let section = clip.keyframeSection(for: target)
            if self.hasKeyframes(in: section, clip: clip) {
                self.insertSectionKeyframe(
                    at: localTime,
                    section: section,
                    into: &clip
                )
            }
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
            } else {
                self.selectedKeyframeID = scale.setKeyframe(
                    at: localTime,
                    value: adjusted(current),
                    tolerance: self.keyframeTimeTolerance
                )
            }
            clip.transform.scale = scale
        }

        if interactive {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    private func insertSectionKeyframe(
        at time: Double,
        section: KeyframeSection,
        into clip: inout TimelineClip
    ) {
        let targets = clip.keyframeTargets(in: section)
        if targets.contains(where: \.isScaleTarget) {
            _ = clip.transform.scale.setKeyframe(
                at: time,
                value: clip.transform.scale.value(at: time),
                tolerance: keyframeTimeTolerance
            )
        }
        for target in targets where !target.isScaleTarget {
            guard var property = clip.animatableProperty(for: target) else { continue }
            _ = property.setKeyframe(
                at: time,
                value: property.value(at: time),
                tolerance: keyframeTimeTolerance
            )
            clip.setAnimatableProperty(property, for: target)
        }
    }

    private func removeSectionKeyframe(
        at time: Double,
        section: KeyframeSection,
        from clip: inout TimelineClip
    ) {
        let targets = clip.keyframeTargets(in: section)
        if targets.contains(where: \.isScaleTarget) {
            _ = clip.transform.scale.removeKeyframe(
                at: time,
                tolerance: keyframeTimeTolerance
            )
        }
        for target in targets where !target.isScaleTarget {
            guard var property = clip.animatableProperty(for: target) else { continue }
            property.keyframes.removeAll {
                abs($0.time - time) <= keyframeTimeTolerance
            }
            clip.setAnimatableProperty(property, for: target)
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
