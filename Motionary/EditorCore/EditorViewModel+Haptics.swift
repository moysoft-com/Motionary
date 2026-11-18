import Foundation

extension EditorViewModel {
    @discardableResult
    func addHaptic() -> UUID? {
        guard !isPerformingLongTask else { return nil }
        let start = visibleInsertionTime(at: currentTime)
        let available = duration - start
        let defaultDuration = 2.0
        let length = available > 0 ? min(defaultDuration, available) : defaultDuration
        let item = HapticTimelineItem(
            timelineStart: start, duration: length, style: .rumble,
            patternEnabled: false, pulseLength: HapticTimelineItem.defaultPulseLength
        )
        let before = project
        var after = project
        let track = after.tracks.firstIndex { track in
            !track.isLocked && track.items.isEmpty && (track.kind == .undefined || track.kind == .haptic)
        } ?? after.topAvailableTrackIndex(kind: .haptic, start: start, duration: length)
            ?? after.insertFreshTrack(kind: .haptic)
        after.adoptTrackKindIfNeeded(at: track, requiredKind: .haptic)
        after.tracks[track].items.append(.haptic(item))
        after.tracks[track].sortItems()
        after.renumberTracks()
        let invalidation: EditorInvalidation = after.duration == before.duration
            ? [.timelineLayout, .persistence, .userInterface]
            : [.timelineLayout, .persistence, .userInterface, .compositionTopology, .previewFrame]
        commit(EditorCommandFactory.importMedia(before: before, after: after, invalidation: invalidation), seekTo: start)
        selectTimelineItem(item.id, trackID: after.tracks[track].id)
        return item.id
    }

    func updateHaptic(id: UUID, interactive: Bool = false, _ edit: (inout HapticTimelineItem) -> Void) {
        guard !isPerformingLongTask, let location = project.itemLocation(id: id),
            !project.tracks[location.track].isLocked,
            case .haptic(var item) = project.tracks[location.track].items[location.item]
        else { return }
        edit(&item)
        hapticPlayback.stopAudition()
        mutateProject(
            rebuild: false, recordHistory: !interactive, persistChanges: !interactive,
            touchUpdatedAt: !interactive, liveTimelineContent: interactive
        ) { project in
            project.tracks[location.track].items[location.item] = .haptic(item)
        }
    }

    func auditionHaptic(_ item: HapticTimelineItem) {
        pausePlaybackForEditing()
        guard HapticPlayback.isSupported else { return }
        var preview = item
        preview.timelineStart = 0
        if let track = try? HapticTrack.render([preview], through: preview.duration) {
            hapticPlayback.audition(track)
        }
    }

    func hapticKeyframeTime(for item: HapticTimelineItem) -> Double {
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        let localTime = min(max(currentTime - item.timelineStart, 0), item.duration)
        let nearest = item.keyframeTimes.min { abs($0 - localTime) < abs($1 - localTime) }
        if let nearest, abs(nearest - localTime) <= keyframeTimeTolerance {
            return item.sourceStart + nearest
        }
        let snapped = (localTime * frameRate).rounded() / frameRate
        return item.sourceStart + min(snapped, item.duration)
    }

    func setHapticKeyframeValue(
        _ value: Double, item: HapticTimelineItem,
        property: WritableKeyPath<HapticTimelineItem, AnimatableProperty<Double>>, interactive: Bool
    ) {
        if interactive { beginInteractiveEdit() }
        let time = hapticKeyframeTime(for: item)
        updateHaptic(id: item.id, interactive: interactive) { item in
            let range = KeyframeTarget.hapticControls.first { $0.hapticProperty == property }?.hapticMetadata.range ?? 0...1
            let value = min(max(value, range.lowerBound), range.upperBound)
            let properties = item.keyframeTargets.compactMap(\.hapticProperty)
            if properties.contains(where: { !item[keyPath: $0].keyframes.isEmpty }) {
                item.insertKeyframes(at: time, tolerance: keyframeTimeTolerance)
                if let index = item[keyPath: property].keyframeIndex(at: time, tolerance: keyframeTimeTolerance) {
                    item[keyPath: property].keyframes[index].value = value
                }
            } else {
                item[keyPath: property].baseValue = value
            }
        }
    }

    func toggleHapticKeyframes(for item: HapticTimelineItem) {
        let time = hapticKeyframeTime(for: item)
        let hasMarker = item.hasKeyframe(at: time, tolerance: keyframeTimeTolerance)
        updateHaptic(id: item.id) { item in
            if hasMarker {
                for target in item.keyframeTargets {
                    guard let property = target.hapticProperty,
                        let index = item[keyPath: property].keyframeIndex(at: time, tolerance: keyframeTimeTolerance)
                    else { continue }
                    let removed = item[keyPath: property].keyframes.remove(at: index)
                    if item[keyPath: property].keyframes.isEmpty {
                        item[keyPath: property].baseValue = removed.value
                    }
                }
            } else {
                item.insertKeyframes(at: time, tolerance: keyframeTimeTolerance)
            }
        }
        refreshGraphSegment()
    }

}


extension KeyframeTarget {
    static let hapticControls: [Self] = [.hapticIntensity, .hapticSharpness, .hapticRepeat, .hapticLength]

    var hapticProperty: WritableKeyPath<HapticTimelineItem, AnimatableProperty<Double>>? {
        switch self {
        case .hapticIntensity: \.intensity
        case .hapticSharpness: \.sharpness
        case .hapticRepeat: \.animatedPeriod
        case .hapticLength: \.animatedLength
        default: nil
        }
    }

    var hapticMetadata: KeyframePropertyMetadata {
        switch self {
        case .hapticRepeat:
            return .init(
                title: "Repeat Every", systemImage: "repeat", group: .haptics,
                range: HapticTimelineItem.repeatRange, step: 0.01, fractionDigits: 2, usesSeconds: true
            )
        case .hapticLength:
            return .init(
                title: "Length", systemImage: "timer", group: .haptics,
                range: 0...HapticTimelineItem.repeatRange.upperBound, step: 0.01, fractionDigits: 2,
                usesSeconds: true, zeroLabel: "Impact"
            )
        default:
            return .init(
                title: self == .hapticIntensity ? "Intensity" : "Sharpness",
                systemImage: self == .hapticIntensity ? "waveform" : "bolt",
                group: .haptics, range: 0...1, step: 0.01, fractionDigits: 0
            )
        }
    }
}

extension HapticTimelineItem {
    var keyframeTargets: [KeyframeTarget] {
        guard style != .impact else { return [] }
        return isPatternEnabled ? KeyframeTarget.hapticControls : [.hapticIntensity, .hapticSharpness]
    }

    func hasKeyframe(at time: Double, tolerance: Double) -> Bool {
        keyframeTargets.compactMap(\.hapticProperty).contains {
            self[keyPath: $0].keyframeIndex(at: time, tolerance: tolerance) != nil
        }
    }

    mutating func insertKeyframes(at time: Double, tolerance: Double) {
        for property in keyframeTargets.compactMap(\.hapticProperty) {
            // Preserve off-grid keys moved by the timeline gesture.
            if self[keyPath: property].keyframeIndex(at: time, tolerance: tolerance) == nil {
                let value = self[keyPath: property].value(at: time)
                _ = self[keyPath: property].setKeyframe(at: time, value: value, tolerance: tolerance)
            }
        }
    }
}
