// Keyframe editing for text transform, type, and style sections.

import Foundation

extension EditorViewModel {
    var selectedTimelineItemLocalTime: Double {
        guard let item = selectedTimelineItem else { return 0 }
        return min(max(currentTime - item.timelineStart, 0), item.placementDuration)
    }

    func snappedTextKeyframeTime(_ time: Double, item: TextTimelineItem) -> Double {
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        return min(max((time * frameRate).rounded() / frameRate, 0), item.duration)
    }

    func textDisplayedValue(for target: KeyframeTarget) -> Double {
        selectedTextItem?.value(for: target, at: selectedTimelineItemLocalTime) ?? 0
    }

    func textHasKeyframe(atPlayhead target: KeyframeTarget) -> Bool {
        guard let item = selectedTextItem,
            let property = item.animatableProperty(for: target)
        else { return false }
        let time = snappedTextKeyframeTime(selectedTimelineItemLocalTime, item: item)
        return property.keyframeIndex(at: time, tolerance: keyframeTimeTolerance) != nil
    }

    func textHasKeyframe(atPlayhead section: KeyframeSection) -> Bool {
        guard let item = selectedTextItem else { return false }
        let time = snappedTextKeyframeTime(selectedTimelineItemLocalTime, item: item)
        return item.keyframeTargets(in: section, includingInactiveEffects: true).contains { target in
            item.animatableProperty(for: target)?.keyframeIndex(
                at: time,
                tolerance: keyframeTimeTolerance
            ) != nil
        }
    }

    func textHasKeyframes(in section: KeyframeSection, item: TextTimelineItem? = nil) -> Bool {
        guard let item = item ?? selectedTextItem else { return false }
        return !item.keyframeTimes(in: section).isEmpty
    }

    func textPropertyRange(
        for target: KeyframeTarget,
        item: TextTimelineItem? = nil
    ) -> ClosedRange<Double> {
        (item ?? selectedTextItem)?.keyframeMetadata(for: target).range ?? -1...1
    }

    func textGraphSegmentCandidate(
        in section: KeyframeSection,
        item: TextTimelineItem,
        localTime: Double
    ) -> KeyframeSegment? {
        let times = item.keyframeTimes(in: section)
        guard times.count >= 2 else { return nil }
        let leftIndex: Int?
        if let exact = times.firstIndex(where: { abs($0 - localTime) <= keyframeTimeTolerance }) {
            leftIndex = exact < times.count - 1 ? exact : exact - 1
        } else {
            leftIndex = times.indices.dropLast().first {
                localTime > times[$0] && localTime < times[$0 + 1]
            }
        }
        guard let leftIndex, leftIndex >= 0, leftIndex + 1 < times.count else { return nil }
        let startTime = times[leftIndex]
        let interpolation = item
            .keyframeTargets(in: section, includingInactiveEffects: true)
            .lazy
            .compactMap { target in
                item.animatableProperty(for: target)?.keyframes.first {
                    abs($0.time - startTime) <= self.keyframeTimeTolerance
                }?.interpolation
            }
            .first ?? .linear
        return KeyframeSegment(
            clipID: item.id,
            section: section,
            startTime: startTime,
            endTime: times[leftIndex + 1],
            interpolation: interpolation
        )
    }

    func setSelectedTextKeyframeValue(
        _ value: Double,
        target: KeyframeTarget,
        interactive: Bool = false
    ) {
        guard selectedTextItem != nil else { return }
        if target.isScaleTarget {
            setSelectedTextScaleValue(value, target: target, interactive: interactive)
            return
        }
        if interactive { beginInteractiveEdit() }
        activeKeyframeTarget = target

        updateSelectedText(interactive: interactive) { item in
            guard item.animatableProperty(for: target) != nil else { return }
            let localTime = self.snappedTextKeyframeTime(
                self.currentTime - item.timelineStart,
                item: item
            )
            let section = item.keyframeSection(for: target)
            if self.textHasKeyframes(in: section, item: item) {
                self.insertTextSectionKeyframe(at: localTime, section: section, into: &item)
            }
            guard var property = item.animatableProperty(for: target) else { return }
            let range = item.keyframeMetadata(for: target).range
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
            item.setAnimatableProperty(property, for: target)
        }
        if interactive { scheduleInteractivePreviewRebuild(invalidation: [.previewFrame]) }
        refreshGraphSegment()
    }

    func setSelectedTextColor(
        _ color: RGBAColor,
        property colorProperty: TextColorProperty,
        interactive: Bool = false
    ) {
        guard let selectedTextItem,
            colorProperty == .fill || selectedTextItem.color(for: colorProperty, at: 0) != nil
        else { return }
        if interactive { beginInteractiveEdit() }
        let preferredTarget = colorTargets(for: colorProperty).first
        activeKeyframeTarget = preferredTarget

        updateSelectedText(interactive: interactive) { item in
            let localTime = self.snappedTextKeyframeTime(
                self.currentTime - item.timelineStart,
                item: item
            )
            if self.textHasKeyframes(in: .textStyle, item: item) {
                self.insertTextSectionKeyframe(at: localTime, section: .textStyle, into: &item)
            }
            var animation = item.colorAnimation(for: colorProperty)
            if animation.keyframes.isEmpty {
                animation.baseValue = color
                self.selectedKeyframeID = nil
            } else {
                self.selectedKeyframeID = animation.setKeyframe(
                    at: localTime,
                    value: color,
                    tolerance: self.keyframeTimeTolerance
                )
            }
            item.setColorAnimation(animation, for: colorProperty)
        }
        if interactive { scheduleInteractivePreviewRebuild(invalidation: [.previewFrame]) }
        refreshGraphSegment()
    }

    func toggleTextKeyframe(_ target: KeyframeTarget) {
        guard selectedTextItem != nil else { return }
        activeKeyframeTarget = target
        updateSelectedText { item in
            let time = self.snappedTextKeyframeTime(
                self.currentTime - item.timelineStart,
                item: item
            )
            if target.isScaleTarget {
                if item.visuals.transform.scale.removeKeyframe(
                    at: time,
                    tolerance: self.keyframeTimeTolerance
                ) {
                    self.selectedKeyframeID = nil
                } else {
                    self.selectedKeyframeID = item.visuals.transform.scale.setKeyframe(
                        at: time,
                        value: item.visuals.transform.scale.value(at: time),
                        tolerance: self.keyframeTimeTolerance
                    )
                }
                return
            }
            guard var property = item.animatableProperty(for: target) else { return }
            if let index = property.keyframeIndex(at: time, tolerance: self.keyframeTimeTolerance) {
                property.keyframes.remove(at: index)
                self.selectedKeyframeID = nil
            } else {
                self.selectedKeyframeID = property.setKeyframe(
                    at: time,
                    value: property.value(at: time),
                    tolerance: self.keyframeTimeTolerance
                )
            }
            item.setAnimatableProperty(property, for: target)
        }
    }

    func toggleTextKeyframeSection(_ section: KeyframeSection) {
        guard selectedTextItem != nil else { return }
        updateSelectedText { item in
            let time = self.snappedTextKeyframeTime(
                self.currentTime - item.timelineStart,
                item: item
            )
            let targets = item.keyframeTargets(in: section, includingInactiveEffects: true)
            let hasMarker = targets.contains { target in
                item.animatableProperty(for: target)?.keyframeIndex(
                    at: time,
                    tolerance: self.keyframeTimeTolerance
                ) != nil
            }
            if hasMarker {
                self.removeTextSectionKeyframe(at: time, section: section, from: &item)
                self.selectedKeyframeID = nil
            } else {
                self.insertTextSectionKeyframe(at: time, section: section, into: &item)
                let activeTargets = item.keyframeTargets(in: section)
                let preferredTarget = self.activeKeyframeTarget.flatMap {
                    activeTargets.contains($0) ? $0 : nil
                } ?? activeTargets.first
                self.activeKeyframeTarget = preferredTarget
                self.selectedKeyframeID = preferredTarget.flatMap { target in
                    item.animatableProperty(for: target)?.keyframes.first {
                        abs($0.time - time) <= self.keyframeTimeTolerance
                    }?.id
                }
            }
        }
    }

    func updateTextKeyframe(
        target: KeyframeTarget,
        id: UUID,
        time: Double? = nil,
        value: Double? = nil,
        interactive: Bool = false
    ) {
        guard selectedTextItem != nil else { return }
        if interactive { beginInteractiveEdit() }
        activeKeyframeTarget = target
        selectedKeyframeID = id
        updateSelectedText(interactive: interactive) { item in
            guard var property = item.animatableProperty(for: target),
                property.keyframes.contains(where: { $0.id == id })
            else { return }
            let metadata = item.keyframeMetadata(for: target)
            if let time {
                let snapped = self.snappedTextKeyframeTime(time, item: item)
                property.keyframes.removeAll {
                    $0.id != id && abs($0.time - snapped) <= self.keyframeTimeTolerance
                }
                guard let index = property.keyframes.firstIndex(where: { $0.id == id }) else { return }
                property.keyframes[index].time = snapped
            }
            if let value, let index = property.keyframes.firstIndex(where: { $0.id == id }) {
                property.keyframes[index].value = min(
                    max(value, metadata.range.lowerBound),
                    metadata.range.upperBound
                )
            }
            property.keyframes.sort { $0.time < $1.time }
            item.setAnimatableProperty(property, for: target)
        }
        if interactive { scheduleInteractivePreviewRebuild(invalidation: [.previewFrame]) }
        refreshGraphSegment()
    }

    func removeTextKeyframe(target: KeyframeTarget, id: UUID) {
        guard selectedTextItem != nil else { return }
        updateSelectedText { item in
            if target.isScaleTarget {
                item.visuals.transform.scale.keyframes.removeAll { $0.id == id }
            } else if var property = item.animatableProperty(for: target) {
                property.removeKeyframe(id: id)
                item.setAnimatableProperty(property, for: target)
            }
            self.selectedKeyframeID = nil
        }
    }

    func setTextInterpolation(
        _ interpolation: KeyframeInterpolation,
        section: KeyframeSection,
        startTime: Double,
        interactive: Bool = false
    ) {
        guard selectedTextItem != nil else { return }
        if interactive { beginInteractiveEdit() }
        updateSelectedText(interactive: interactive) { item in
            let targets = item.keyframeTargets(in: section, includingInactiveEffects: true)
            if targets.contains(where: \.isScaleTarget),
                let index = item.visuals.transform.scale.keyframes.firstIndex(
                    where: { abs($0.time - startTime) <= self.keyframeTimeTolerance }
                )
            {
                item.visuals.transform.scale.keyframes[index].interpolation = interpolation
            }
            for target in targets where !target.isScaleTarget {
                guard var property = item.animatableProperty(for: target),
                    let index = property.keyframes.firstIndex(
                        where: { abs($0.time - startTime) <= self.keyframeTimeTolerance }
                    )
                else { continue }
                property.keyframes[index].interpolation = interpolation
                item.setAnimatableProperty(property, for: target)
            }
        }
        if interactive { scheduleInteractivePreviewRebuild(invalidation: [.previewFrame]) }
        refreshGraphSegment()
    }

    func selectAdjacentTextKeyframe(target: KeyframeTarget, direction: Int) {
        guard let item = selectedTextItem,
            let property = item.animatableProperty(for: target),
            !property.keyframes.isEmpty
        else { return }
        let frames = property.keyframes.sorted { $0.time < $1.time }
        let currentIndex = selectedKeyframeID.flatMap { id in
            frames.firstIndex(where: { $0.id == id })
        } ?? frames.lastIndex(where: {
            $0.time < selectedTimelineItemLocalTime + keyframeTimeTolerance
        }) ?? (direction > 0 ? -1 : frames.count)
        let targetIndex = min(max(currentIndex + direction, 0), frames.count - 1)
        let frame = frames[targetIndex]
        selectedKeyframeID = frame.id
        activeKeyframeTarget = target
        seek(to: item.timelineStart + frame.time)
    }

    func insertTextSectionKeyframe(
        at time: Double,
        section: KeyframeSection,
        into item: inout TextTimelineItem
    ) {
        let targets = item.keyframeTargets(in: section).filter(item.isKeyframeTargetEnabled)
        if targets.contains(where: \.isScaleTarget) {
            _ = item.visuals.transform.scale.setKeyframe(
                at: time,
                value: item.visuals.transform.scale.value(at: time),
                tolerance: keyframeTimeTolerance
            )
        }
        for target in targets where !target.isScaleTarget {
            guard var property = item.animatableProperty(for: target) else { continue }
            _ = property.setKeyframe(
                at: time,
                value: property.value(at: time),
                tolerance: keyframeTimeTolerance
            )
            item.setAnimatableProperty(property, for: target)
        }
    }

    func removeTextSectionKeyframe(
        at time: Double,
        section: KeyframeSection,
        from item: inout TextTimelineItem
    ) {
        let targets = item.keyframeTargets(in: section, includingInactiveEffects: true)
        if targets.contains(where: \.isScaleTarget) {
            _ = item.visuals.transform.scale.removeKeyframe(
                at: time,
                tolerance: keyframeTimeTolerance
            )
        }
        for target in targets where !target.isScaleTarget {
            guard var property = item.animatableProperty(for: target) else { continue }
            property.keyframes.removeAll { abs($0.time - time) <= keyframeTimeTolerance }
            item.setAnimatableProperty(property, for: target)
        }
    }

    private func setSelectedTextScaleValue(
        _ value: Double,
        target: KeyframeTarget,
        interactive: Bool
    ) {
        if interactive { beginInteractiveEdit() }
        activeKeyframeTarget = target
        updateSelectedText(interactive: interactive) { item in
            let localTime = self.snappedTextKeyframeTime(
                self.currentTime - item.timelineStart,
                item: item
            )
            if self.textHasKeyframes(in: .transform, item: item) {
                self.insertTextSectionKeyframe(at: localTime, section: .transform, into: &item)
            }
            let boundedValue = min(max(value, 0.01), 100)
            var scale = item.visuals.transform.scale
            let current = scale.value(at: localTime)
            let editsBothAxes = target == .scale
            func adjusted(_ original: ScaleValue) -> ScaleValue {
                if editsBothAxes {
                    let factor = boundedValue / max(current.x, 0.000_001)
                    return ScaleValue(
                        x: min(max(original.x * factor, 0.01), 100),
                        y: min(max(original.y * factor, 0.01), 100)
                    )
                }
                return target == .scaleY
                    ? ScaleValue(x: original.x, y: boundedValue)
                    : ScaleValue(x: boundedValue, y: original.y)
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
            item.visuals.transform.scale = scale
        }
        if interactive { scheduleInteractivePreviewRebuild(invalidation: [.previewFrame]) }
    }

    private func colorTargets(for property: TextColorProperty) -> [KeyframeTarget] {
        switch property {
        case .fill: ColorComponent.allCases.map(KeyframeTarget.textFill)
        case .stroke: ColorComponent.allCases.map(KeyframeTarget.textStroke)
        case .shadow: ColorComponent.allCases.map(KeyframeTarget.textShadow)
        case .background: ColorComponent.allCases.map(KeyframeTarget.textBackground)
        }
    }
}
