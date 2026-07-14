// Contextual transform, adjustment, and effect workspaces.

import SwiftUI
import UIKit

struct ShapeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Shape",
            systemImage: "slider.horizontal.3",
            section: .shape
        ) { clip, isEnabled in
            if let shape = clip.shape {
                VStack(spacing: 12) {
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .shapeWidth,
                        isEnabled: isEnabled
                    )
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .shapeHeight,
                        isEnabled: isEnabled
                    )

                    if shape.kind.supportsCornerRadius {
                        PropertyScrubber(
                            viewModel: viewModel,
                            clip: clip,
                            target: .shapeCornerRadius,
                            isEnabled: isEnabled
                        )
                    }

                    HStack(spacing: 8) {
                        Text("Color")
                            .font(.callout.weight(.medium))
                        Spacer()
                        ColorPicker(
                            "Color",
                            selection: Binding(
                                get: { shape.color.swiftUIColor },
                                set: { viewModel.setSelectedShape(color: RGBAColor($0)) }
                            ),
                            supportsOpacity: true
                        )
                        .labelsHidden()
                    }
                    .disabled(!isEnabled)
                }
            }
        }
    }
}

struct TransformWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let text: TextTimelineItem?

    var body: some View {
        Group {
            if let text {
                TextTransformWorkspace(viewModel: viewModel, item: text)
            } else {
                PropertyWorkspaceShell(
                    viewModel: viewModel,
                    clip: clip,
                    title: "Transform",
                    systemImage: "crop.rotate",
                    section: .transform
                ) { clip, isEnabled in
                    VStack(spacing: 12) {
                        ForEach([
                            KeyframeTarget.positionX,
                            .positionY,
                            .rotation,
                        ]) { target in
                            PropertyScrubber(
                                viewModel: viewModel,
                                clip: clip,
                                target: target,
                                isEnabled: isEnabled
                            )
                        }
//
//                HStack {
//                    Text("Scale")
//                        .font(.caption.weight(.semibold))
//                    Spacer()
//                    Picker(
//                        "Scale dimensions",
//                        selection: Binding(
//                            get: { clip.transform.scale.isLinked },
//                            set: { viewModel.setScaleLinked($0) }
//                        )
//                    ) {
//                        Label("Split", systemImage: "link.badge.plus").tag(false)
//                        Label("Linked", systemImage: "link").tag(true)
//                    }
//                    .pickerStyle(.segmented)
//                    .frame(width: 178)
//                    .disabled(!isEnabled)
//                }

                        if clip.transform.scale.isLinked {
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scale, isEnabled: isEnabled)
                        } else {
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scaleX, isEnabled: isEnabled)
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scaleY, isEnabled: isEnabled)
                        }

                        HStack(spacing: 10) {
                            TransformToggleButton(
                                title: "Horizontal",
                                systemImage: "arrow.left.and.right",
                                isSelected: clip.transform.isFlippedHorizontally,
                                isEnabled: isEnabled
                            ) {
                                viewModel.setSelectedTransform(
                                    isFlippedHorizontally: !clip.transform.isFlippedHorizontally
                                )
                            }
                            TransformToggleButton(
                                title: "Vertical",
                                systemImage: "arrow.up.and.down",
                                isSelected: clip.transform.isFlippedVertically,
                                isEnabled: isEnabled
                            ) {
                                viewModel.setSelectedTransform(
                                    isFlippedVertically: !clip.transform.isFlippedVertically
                                )
                            }
                            Button {
                                viewModel.updateSelectedClip { $0.transform = ClipTransform() }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .frame(width: 42, height: 38)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isEnabled)
                        }
                    }
                }
            }
        }
    }
}

private struct TextTransformWorkspace: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem

    var body: some View {
        let isEnabled = viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Label("Transform", systemImage: "crop.rotate")
                    .font(.headline.weight(.semibold))
                Spacer()
                SectionKeyframeButton(
                    viewModel: viewModel,
                    itemID: item.id,
                    section: .transform,
                    isEnabled: isEnabled
                )
            }
            .frame(height: 22)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(TextTransformControl.allCases) { control in
                        EditorValueScrubber(
                            title: control.title,
                            systemImage: control.systemImage,
                            value: control.value(in: item, at: localTime),
                            range: control.range,
                            step: control.step,
                            format: control.format,
                            onBegan: viewModel.beginInteractiveEdit,
                            onChanged: { value in set(value, for: control) },
                            onEnded: viewModel.finishTextEditing
                        )
                    }

                    HStack(spacing: 10) {
                        TextTransformToggleButton(
                            title: "Horizontal",
                            systemImage: "arrow.left.and.right",
                            isSelected: item.visuals.transform.isFlippedHorizontally
                        ) {
                            updateTransform { transform in
                                transform.isFlippedHorizontally.toggle()
                            }
                        }
                        TextTransformToggleButton(
                            title: "Vertical",
                            systemImage: "arrow.up.and.down",
                            isSelected: item.visuals.transform.isFlippedVertically
                        ) {
                            updateTransform { transform in
                                transform.isFlippedVertically.toggle()
                            }
                        }
                        Button {
                            viewModel.updateTextItem(item.id) { $0.visuals.transform = ClipTransform() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .frame(width: 42, height: 38)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset transform")
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .opacity(isEnabled ? 1 : 0.42)
        .disabled(!isEnabled)
        .motionaryGlass(cornerRadius: 20)
    }

    private var localTime: Double {
        min(max(viewModel.currentTime - item.timelineStart, 0), item.duration)
    }

    private func set(_ value: Double, for control: TextTransformControl) {
        viewModel.setSelectedTextKeyframeValue(
            value,
            target: control.keyframeTarget,
            interactive: true
        )
    }

    private func updateTransform(_ update: @escaping (inout ClipTransform) -> Void) {
        viewModel.updateTextItem(item.id) { item in
            update(&item.visuals.transform)
        }
    }

}

private enum TextTransformControl: String, CaseIterable, Identifiable {
    case positionX
    case positionY
    case rotation
    case scale

    var id: String { rawValue }

    var keyframeTarget: KeyframeTarget {
        switch self {
        case .positionX: .positionX
        case .positionY: .positionY
        case .rotation: .rotation
        case .scale: .scale
        }
    }

    var title: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .rotation: "Rotation"
        case .scale: "Scale"
        }
    }

    var systemImage: String {
        switch self {
        case .positionX: "arrow.left.and.right"
        case .positionY: "arrow.up.and.down"
        case .rotation: "rotate.right"
        case .scale: "arrow.up.left.and.arrow.down.right"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .positionX, .positionY: -2...2
        case .rotation: -720...720
        case .scale: 0.01...100
        }
    }

    var step: Double {
        switch self {
        case .positionX, .positionY, .scale: 0.01
        case .rotation: 1
        }
    }

    var format: (Double) -> String {
        switch self {
        case .positionX, .positionY:
            { $0.formatted(.number.precision(.fractionLength(2))) }
        case .rotation:
            { "\(Int($0.rounded()))°" }
        case .scale:
            { $0.formatted(.number.precision(.fractionLength(2))) + "×" }
        }
    }

    func value(in item: TextTimelineItem, at time: Double) -> Double {
        switch self {
        case .positionX: item.visuals.transform.positionX.value(at: time)
        case .positionY: item.visuals.transform.positionY.value(at: time)
        case .rotation: item.visuals.transform.rotationDegrees.value(at: time)
        case .scale: item.visuals.transform.scale.value(at: time).x
        }
    }
}

private struct TextTransformToggleButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : MotionaryTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    isSelected ? MotionaryTheme.accent : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct AudioWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Audio",
            systemImage: "speaker.wave.2",
            section: .audio
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType == .audio || clip.mediaType == .video {
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .volume,
                        isEnabled: isEnabled
                    )
                } else {
                    Text("Audio controls are available for audio and video clips.")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct AdjustWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Adjust",
            systemImage: "slider.horizontal.3",
            section: .adjust
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType != .audio {
                    ForEach([
                        KeyframeTarget.opacity,
                        .brightness,
                        .contrast,
                        .saturation,
                        .exposure,
                    ]) { target in
                        PropertyScrubber(
                            viewModel: viewModel,
                            clip: clip,
                            target: target,
                            isEnabled: isEnabled
                        )
                    }
                }
            }
        }
    }
}

struct EffectsWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Effects",
            systemImage: "wand.and.stars",
            section: .effects
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType == .audio {
                    Text("Effects are available for visual clips.")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(clip.effectStack.effects.enumerated()), id: \.element.id) { index, effect in
                        VStack(spacing: 9) {
                            HStack(spacing: 8) {
                                Button {
                                    viewModel.setEffectEnabled(effect.id, enabled: !effect.isEnabled)
                                } label: {
                                    Image(systemName: effect.isEnabled ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(
                                    effect.isEnabled
                                        ? MotionaryTheme.accent
                                        : MotionaryTheme.textSecondary
                                )

                                Text(effect.kind.rawValue)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                EffectCommandButton(systemName: "arrow.up", isDisabled: index == 0 || !isEnabled) {
                                    viewModel.moveEffect(effect.id, offset: -1)
                                }
                                EffectCommandButton(
                                    systemName: "arrow.down",
                                    isDisabled: index == clip.effectStack.effects.count - 1 || !isEnabled
                                ) {
                                    viewModel.moveEffect(effect.id, offset: 1)
                                }
                                EffectCommandButton(systemName: "trash", isDisabled: !isEnabled, role: .destructive) {
                                    viewModel.removeEffect(effect.id)
                                }
                            }

                            PropertyScrubber(
                                viewModel: viewModel,
                                clip: clip,
                                target: .effectIntensity(effect.id),
                                isEnabled: isEnabled && effect.isEnabled
                            )
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    }

                    Menu {
                        ForEach(ClipEffectKind.allCases) { kind in
                            Button(kind.rawValue) { viewModel.addEffect(kind) }
                        }
                    } label: {
                        Label("Add Effect", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }
        }
    }
}

private struct PropertyWorkspaceShell<Content: View>: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let title: String
    let systemImage: String
    let section: KeyframeSection?
    @ViewBuilder let content: (TimelineClip, Bool) -> Content

    var body: some View {
        ZStack {

            if let clip {
                let isEnabled =
                    viewModel.selectedClipID == clip.id
                    && viewModel.isTimeInside(clip)
                VStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Label(title, systemImage: systemImage)
                            .font(.headline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                        Spacer()
                        if let section {
                            SectionKeyframeButton(
                                viewModel: viewModel,
                                itemID: clip.id,
                                section: section,
                                isEnabled: isEnabled
                            )
                        }
                    }
                    .frame(height: 22)

                    ScrollView {
                        content(clip, isEnabled)
                            .padding(.bottom, 6)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(14)
                .opacity(isEnabled ? 1 : 0.42)
            } else {
                Label("Select a clip", systemImage: "cursorarrow.click.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }
        }
        .motionaryGlass(cornerRadius: 20)
    }
}

private struct PropertyScrubber: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let clip: TimelineClip
    let target: KeyframeTarget
    let isEnabled: Bool

    @State private var rulerTickPosition: CGFloat?
    @State private var lastHapticBucket: Int?
    @State private var isDragging = false
    @State private var isScrubbing = false
    @State private var momentumTask: Task<Void, Never>?

    init(
        viewModel: EditorViewModel,
        clip: TimelineClip,
        target: KeyframeTarget,
        isEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.clip = clip
        self.target = target
        self.isEnabled = isEnabled
    }

    var body: some View {
        let metadata = clip.keyframeMetadata(for: target)
        let value = displayedValue
        VStack {
            HStack(spacing: 8) {
                Label(metadata.title, systemImage: metadata.systemImage)
                    .font(.callout.weight(.medium))
                    .labelStyle(.titleOnly)
                    .frame(width: 82, alignment: .leading)
                    .lineLimit(1)

                Spacer()

                Text(formatted(value, metadata: metadata))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 54, alignment: .trailing)
            }
            InfiniteScrubberTrack(
                tickPosition: rulerTickPosition
                    ?? tickPosition(for: value, metadata: metadata),
                isEditing: isScrubbing,
                maximumTickPosition: maximumTickPosition(metadata: metadata)
            )
            .contentShape(Rectangle())
            .overlay {
                HorizontalScrubInteraction(
                    onBegan: {
                        beginScrub(metadata: metadata)
                    },
                    onChanged: { delta in
                        updateScrub(
                            delta: delta,
                            metadata: metadata
                        )
                    },
                    onEnded: { velocity in
                        endScrub(
                            velocity: velocity,
                            metadata: metadata
                        )
                    }
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metadata.title)
            .accessibilityValue(formatted(value, metadata: metadata))
            .accessibilityHint("Swipe left to increase or right to decrease.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustValue(by: metadata.step, metadata: metadata)
                case .decrement:
                    adjustValue(by: -metadata.step, metadata: metadata)
                @unknown default:
                    break
                }
            }

        }
        .disabled(!isEnabled)
    }

    private var displayedValue: Double {
        if viewModel.selectedClipID == clip.id {
            return viewModel.displayedValue(for: target)
        }
        let time = min(max(viewModel.currentTime - clip.timelineStart, 0), clip.sourceRange.duration)
        return clip.animatableProperty(for: target)?.value(at: time) ?? 0
    }

    private func beginScrub(metadata: KeyframePropertyMetadata) {
        momentumTask?.cancel()
        momentumTask = nil
        if isScrubbing {
            viewModel.finishInteractiveEdit()
        }
        let currentValue = displayedValue
        rulerTickPosition = tickPosition(
            for: currentValue,
            metadata: metadata
        )
        isDragging = true
        isScrubbing = true
        viewModel.activeKeyframeTarget = target
        viewModel.beginInteractiveEdit()
        EditorHaptics.scrubStart()
    }

    private func updateScrub(
        delta: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard isDragging, let currentPosition = rulerTickPosition else { return }
        let position = boundedTickPosition(
            currentPosition - delta / InfiniteScrubberTrack.tickSpacing,
            metadata: metadata
        )
        rulerTickPosition = position
        let value = value(at: position, metadata: metadata)
        viewModel.setSelectedKeyframeValue(
            value,
            target: target,
            interactive: true
        )
        updateHaptic(for: value, metadata: metadata)
    }

    private func endScrub(
        velocity: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard isDragging else { return }
        isDragging = false
        guard let position = rulerTickPosition else {
            finishScrubbing()
            return
        }
        startMomentum(
            distance: min(max(-velocity * 0.18, -480), 480),
            from: position,
            metadata: metadata
        )
    }

    private func startMomentum(
        distance: CGFloat,
        from startPosition: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard abs(distance) >= 2 else {
            momentumTask = Task { @MainActor in
                await settleRulerAndFinish()
                momentumTask = nil
            }
            return
        }

        momentumTask = Task { @MainActor in
            var remaining = distance
            var position = startPosition

            while !Task.isCancelled, abs(remaining) >= 0.35 {
                let frameDistance = remaining * 0.12
                remaining *= 0.88
                let nextPosition = boundedTickPosition(
                    position + frameDistance / InfiniteScrubberTrack.tickSpacing,
                    metadata: metadata
                )
                guard abs(nextPosition - position) > 0.0001 else { break }
                position = nextPosition
                rulerTickPosition = position
                let value = value(at: position, metadata: metadata)
                viewModel.setSelectedKeyframeValue(
                    value,
                    target: target,
                    interactive: true
                )
                updateHaptic(for: value, metadata: metadata)
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard !Task.isCancelled else { return }
            await settleRulerAndFinish()
            guard !Task.isCancelled else { return }
            momentumTask = nil
        }
    }

    @MainActor
    private func settleRulerAndFinish() async {
        guard rulerTickPosition != nil else {
            finishScrubbing()
            return
        }
        let metadata = clip.keyframeMetadata(for: target)
        let currentValue = displayedValue
        let snappedPosition = tickPosition(for: currentValue, metadata: metadata)
        withAnimation(.spring(duration: 0.22, bounce: 0.12)) {
            rulerTickPosition = snappedPosition
        }

        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        viewModel.setSelectedKeyframeValue(
            currentValue,
            target: target,
            interactive: true
        )
        finishScrubbing()
    }

    private func finishScrubbing() {
        rulerTickPosition = nil
        isScrubbing = false
        lastHapticBucket = nil
        viewModel.finishInteractiveEdit()
    }

    private func value(
        at position: CGFloat,
        metadata: KeyframePropertyMetadata
    ) -> Double {
        let rawValue: Double
        if target.isScaleTarget {
            rawValue =
                metadata.range.lowerBound * pow(1.05, Double(position))
        } else {
            rawValue =
                metadata.range.lowerBound + Double(position) * metadata.step
        }
        return quantized(rawValue, metadata: metadata)
    }

    private func tickPosition(
        for value: Double,
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        if target.isScaleTarget {
            return boundedTickPosition(
                CGFloat(
                    log(max(value, metadata.range.lowerBound) / metadata.range.lowerBound)
                        / log(1.05)
                ),
                metadata: metadata
            )
        }
        return boundedTickPosition(
            CGFloat((value - metadata.range.lowerBound) / metadata.step),
            metadata: metadata
        )
    }

    private func maximumTickPosition(
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        if target.isScaleTarget {
            return CGFloat(
                log(metadata.range.upperBound / metadata.range.lowerBound)
                    / log(1.05)
            )
        }
        return CGFloat(
            (metadata.range.upperBound - metadata.range.lowerBound) / metadata.step
        )
    }

    private func boundedTickPosition(
        _ position: CGFloat,
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        min(max(position, 0), maximumTickPosition(metadata: metadata))
    }

    private func adjustValue(by delta: Double, metadata: KeyframePropertyMetadata) {
        viewModel.activeKeyframeTarget = target
        let value = min(max(displayedValue + delta, metadata.range.lowerBound), metadata.range.upperBound)
        viewModel.setSelectedKeyframeValue(quantized(value, metadata: metadata), target: target)
        EditorHaptics.tap()
    }

    private func updateHaptic(for value: Double, metadata: KeyframePropertyMetadata) {
        let bucket: Int
        if target.isScaleTarget {
            bucket = Int((log(max(value, 0.01)) / log(1.05)).rounded())
        } else {
            bucket = Int((value / metadata.step).rounded())
        }
        guard bucket != lastHapticBucket else { return }
        if lastHapticBucket != nil {
            EditorHaptics.selection()
        }
        lastHapticBucket = bucket
    }

    private func quantized(_ value: Double, metadata: KeyframePropertyMetadata) -> Double {
        let stepped = (value / metadata.step).rounded() * metadata.step
        let bounded = min(max(stepped, metadata.range.lowerBound), metadata.range.upperBound)
        return bounded == 0 ? 0 : bounded
    }

    private func formatted(_ value: Double, metadata: KeyframePropertyMetadata) -> String {
        switch target {
        case .rotation:
            "\(Int(value.rounded()))°"
        case .scale, .scaleX, .scaleY:
            "\(value.formatted(.number.precision(.fractionLength(2))))×"
        case .opacity, .effectIntensity, .volume:
            "\(Int((value * 100).rounded()))%"
        default:
            metadata.formattedValue(value)
        }
    }
}

struct SectionKeyframeButton: View {
    @ObservedObject var viewModel: EditorViewModel
    let itemID: UUID
    let section: KeyframeSection
    let isEnabled: Bool

    var body: some View {
        let times = keyframeTimes
        let hasAny = !times.isEmpty
        let isCurrent = viewModel.selectedTimelineItemID == itemID
            && times.contains { abs((item?.timelineStart ?? 0) + $0 - viewModel.currentTime) <= viewModel.keyframeTimeTolerance }

        Button {
            if let item, case .text = item {
                viewModel.toggleTextKeyframeSection(section)
            } else {
                viewModel.toggleKeyframeSection(section)
            }
            EditorHaptics.tap()
        } label: {
            KeyframeDiamondShape()
                .fill(isCurrent ? MotionaryTheme.accent : Color.clear)
                .overlay {
                    KeyframeDiamondShape()
                        .stroke(
                            hasAny ? MotionaryTheme.accent : MotionaryTheme.textSecondary,
                            lineWidth: 1.6
                        )
                }
                .frame(width: 16, height: 16)
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || availableTargetCount == 0)
        .opacity(availableTargetCount == 0 ? 0.3 : 1)
        .accessibilityLabel("\(section.rawValue) keyframe")
    }

    private var item: TimelineItem? {
        viewModel.project.item(id: itemID)
    }

    private var keyframeTimes: [Double] {
        guard let item else { return [] }
        if let clip = item.legacyClip() {
            return clip.keyframeTimes(in: section)
        }
        if case .text(let text) = item {
            return text.keyframeTimes(in: section)
        }
        return []
    }

    private var availableTargetCount: Int {
        guard let item else { return 0 }
        if let clip = item.legacyClip() {
            return clip.keyframeTargets(in: section).count
        }
        if case .text(let text) = item {
            return text.keyframeTargets(in: section).count
        }
        return 0
    }
}

struct EditorValueScrubber: View {
    let title: String
    let systemImage: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onBegan: () -> Void
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @State private var tickPosition: CGFloat?
    @State private var lastHapticBucket: Int?
    @State private var isDragging = false
    @State private var isEditing = false
    @State private var momentumTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.medium))
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                Spacer()
                Text(format(clamped(value)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }

            InfiniteScrubberTrack(
                tickPosition: tickPosition ?? position(for: value),
                isEditing: isEditing,
                maximumTickPosition: maximumPosition
            )
            .contentShape(Rectangle())
            .overlay {
                HorizontalScrubInteraction(
                    onBegan: beginScrub,
                    onChanged: updateScrub,
                    onEnded: endScrub
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(format(clamped(value)))
            .accessibilityHint("Swipe left to increase or right to decrease.")
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = safeStep
                case .decrement: delta = -safeStep
                @unknown default: return
                }
                onBegan()
                onChanged(quantized(value + delta))
                onEnded()
                EditorHaptics.tap()
            }
        }
        .disabled(maximumPosition <= 0)
        .onDisappear {
            momentumTask?.cancel()
            if isEditing { finishScrub() }
        }
    }

    private var safeStep: Double { max(abs(step), 0.000_001) }

    private var maximumPosition: CGFloat {
        CGFloat(max((range.upperBound - range.lowerBound) / safeStep, 0))
    }

    private func position(for value: Double) -> CGFloat {
        min(max(CGFloat((clamped(value) - range.lowerBound) / safeStep), 0), maximumPosition)
    }

    private func value(at position: CGFloat) -> Double {
        quantized(range.lowerBound + Double(position) * safeStep)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func quantized(_ value: Double) -> Double {
        let steps = ((value - range.lowerBound) / safeStep).rounded()
        let result = clamped(range.lowerBound + steps * safeStep)
        return result == 0 ? 0 : result
    }

    private func beginScrub() {
        momentumTask?.cancel()
        momentumTask = nil
        if isEditing { onEnded() }
        tickPosition = position(for: value)
        isDragging = true
        isEditing = true
        onBegan()
        EditorHaptics.scrubStart()
    }

    private func updateScrub(_ delta: CGFloat) {
        guard isDragging, let currentPosition = tickPosition else { return }
        let nextPosition = min(
            max(currentPosition - delta / InfiniteScrubberTrack.tickSpacing, 0),
            maximumPosition
        )
        tickPosition = nextPosition
        publish(value(at: nextPosition))
    }

    private func endScrub(_ velocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        guard let startPosition = tickPosition else {
            finishScrub()
            return
        }
        let distance = min(max(-velocity * 0.18, -480), 480)
        guard abs(distance) >= 2 else {
            finishScrub()
            return
        }

        momentumTask = Task { @MainActor in
            var remaining = distance
            var position = startPosition
            while !Task.isCancelled, abs(remaining) >= 0.35 {
                let frameDistance = remaining * 0.12
                remaining *= 0.88
                let nextPosition = min(
                    max(position + frameDistance / InfiniteScrubberTrack.tickSpacing, 0),
                    maximumPosition
                )
                guard abs(nextPosition - position) > 0.0001 else { break }
                position = nextPosition
                tickPosition = position
                publish(value(at: position))
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            finishScrub()
            momentumTask = nil
        }
    }

    private func publish(_ value: Double) {
        onChanged(value)
        let bucket = Int(((value - range.lowerBound) / safeStep).rounded())
        guard bucket != lastHapticBucket else { return }
        if lastHapticBucket != nil { EditorHaptics.selection() }
        lastHapticBucket = bucket
    }

    private func finishScrub() {
        guard isEditing else { return }
        tickPosition = nil
        lastHapticBucket = nil
        isEditing = false
        onEnded()
    }
}

struct InfiniteScrubberTrack: View {
    static let tickSpacing: CGFloat = 8

    let tickPosition: CGFloat
    let isEditing: Bool
    let maximumTickPosition: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isEditing ? 0.085 : 0.045))

                Canvas { context, size in
                    let spacing = Self.tickSpacing
                    
                    let halfVisibleTicks = Int(ceil((size.width * 0.5) / spacing))
                    let startIndex = max(0, Int(floor(tickPosition)) - halfVisibleTicks - 1)
                    let endIndex = min(Int(ceil(maximumTickPosition)), Int(ceil(tickPosition)) + halfVisibleTicks + 1)

                    if startIndex <= endIndex {
                        for index in startIndex...endIndex {
                            let indexPosition = min(CGFloat(index), maximumTickPosition)
                            let x =
                                size.width * 0.5
                                + (indexPosition - tickPosition) * spacing
                            let isRoundNumber = index.isMultiple(of: 10)
                            let height: CGFloat = 8
                            let rect = CGRect(
                                x: x - 0.6,
                                y: (size.height - height) * 0.5,
                                width: 1.2,
                                height: height
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 0.6),
                                with: .color(
                                    Color.white.opacity(isRoundNumber ? 0.52 : 0.24)
                                )
                            )
                        }
                    }
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.14),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                Capsule()
                    .fill(MotionaryTheme.accent)
                    .frame(width: isEditing ? 2.5 : 1.5, height: isEditing ? 24 : 9)
                    .shadow(
                        color: MotionaryTheme.accent.opacity(isEditing ? 0.5 : 0.15),
                        radius: isEditing ? 3 : 1
                    )

            }
        }
        .frame(minWidth: 72, maxWidth: .infinity)
        .frame(height: 36)
        .animation(.spring(duration: 0.24, bounce: 0.18), value: isEditing)
    }
}

struct HorizontalScrubInteraction: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        init(
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                onBegan()
                recognizer.setTranslation(.zero, in: view)
            case .changed:
                let delta = recognizer.translation(in: view).x
                onChanged(delta)
                recognizer.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                let velocity = recognizer.velocity(in: view).x
                onEnded(velocity)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

struct SelectedLayerMiniTimeline: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    @Binding var contextClipID: UUID?
    @Binding var pixelsPerSecond: CGFloat
    let activeSection: KeyframeSection?
    let graphSegment: KeyframeSegment?

    init(
        viewModel: EditorViewModel,
        contextClipID: Binding<UUID?>,
        pixelsPerSecond: Binding<CGFloat>,
        activeSection: KeyframeSection?,
        graphSegment: KeyframeSegment?
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _contextClipID = contextClipID
        _pixelsPerSecond = pixelsPerSecond
        self.activeSection = activeSection
        self.graphSegment = graphSegment
    }

    var body: some View {
        GeometryReader { geometry in
            if let contextClipID,
                let track = viewModel.project.tracks.first(where: {
                    $0.items.contains { $0.id == contextClipID }
                })
            {
                let centerPadding = geometry.size.width * 0.5
                let contentWidth =
                    max(CGFloat(viewModel.duration) * pixelsPerSecond, 1)
                    + centerPadding * 2
                TimelineScrollContainer(
                    pixelsPerSecond: $pixelsPerSecond,
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    contentRevision: miniTimelineContentRevision,
                    contentSize: CGSize(width: contentWidth, height: geometry.size.height),
                    isScrollDisabled: false,
                    allowsVerticalScrolling: false,
                    onScrubStart: { viewModel.beginScrub() },
                    onScrubChanged: { time in
                        viewModel.updateScrub(to: time)
                    },
                    onScrubEnd: { time in
                        viewModel.endScrub(at: time)
                    },
                    onPullToAddChanged: { _ in },
                    onPullToAddEnded: { _ in }
                ) {
                    ZStack(alignment: .leading) {
                        Color.clear
                        ForEach(track.items) { item in
                            let width = max(CGFloat(item.placementDuration) * pixelsPerSecond, 6)
                            ZStack {
                                if item.id == contextClipID {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white)
                                        .frame(width: width+4, height: 42)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.white, lineWidth: 2)
                                        }
                                        .allowsHitTesting(false)
                                }

                                TimelineItemVisualFill(
                                    item: item,
                                    media: item.legacyClip().flatMap {
                                        viewModel.project.mediaDescriptor(for: $0)
                                    },
                                    mediaClip: item.legacyClip(),
                                    width: width,
                                    height: 38,
                                    pixelsPerSecond: pixelsPerSecond,
                                    sampleWidth: nil
                                )
                                .frame(width: width, height: 38)
                                .foregroundStyle(Color.black.opacity(0.88))
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(timelineItemTint(for: item))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                MiniTimelineKeyframes(
                                    item: item,
                                    currentTime: viewModel.currentTime,
                                    tolerance: viewModel.keyframeTimeTolerance,
                                    width: width,
                                    activeSection: activeSection,
                                    graphSegment: graphSegment
                                )
                            }
                            .frame(width: width, height: 42)
                            .opacity(item.id == contextClipID ? 1 : 0.22)
                            .offset(x: centerPadding + CGFloat(item.timelineStart) * pixelsPerSecond)
                        }
                    }
                    .frame(width: contentWidth, height: geometry.size.height, alignment: .leading)
                }
                .overlay {
                    Rectangle()
                        .fill(MotionaryTheme.selected)
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .motionaryGlass(cornerRadius: 13)
    }

    private var miniTimelineContentRevision: Int {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let playheadFrame = Int((viewModel.currentTime * frameRate).rounded())
        let sectionValue: Int
        switch activeSection {
        case .shape: sectionValue = 1
        case .transform: sectionValue = 2
        case .adjust: sectionValue = 3
        case .effects: sectionValue = 4
        case .audio: sectionValue = 5
        case .textType: sectionValue = 6
        case .textStyle: sectionValue = 7
        case nil: sectionValue = 0
        }
        let graphValue: Int
        if let graphSegment {
            graphValue =
                Int((graphSegment.startTime * frameRate).rounded()) &* 31
                &+ Int((graphSegment.endTime * frameRate).rounded()) &* 131
                &+ sectionValue &* 521
        } else {
            graphValue = 0
        }
        return viewModel.timelineContentRevision &* 10_007
            &+ playheadFrame &* 101
            &+ sectionValue &* 1_009
            &+ graphValue
    }
}

private struct MiniTimelineKeyframes: View {
    let item: TimelineItem
    let currentTime: Double
    let tolerance: Double
    let width: CGFloat
    let activeSection: KeyframeSection?
    let graphSegment: KeyframeSegment?

    var body: some View {
        ZStack {
            if let graphSegment, graphSegment.clipID == item.id {
                graphSegmentIndicator(graphSegment)
            }

            ForEach(KeyframeSection.allCases) { section in
                ForEach(keyframeTimes(in: section), id: \.self) { time in
                    marker(time: time, section: section)
                }
            }
        }
        .frame(width: width, height: 38)
    }

    @ViewBuilder
    private func marker(time: Double, section: KeyframeSection) -> some View {
        let isActiveSection = section == activeSection
        let isCurrent =
            isActiveSection
            && abs((item.timelineStart + time) - currentTime) <= tolerance
        let isGraphEndpoint =
            graphSegment?.clipID == item.id
            && graphSegment?.section == section
            && (
                abs((graphSegment?.startTime ?? -.infinity) - time) <= tolerance
                || abs((graphSegment?.endTime ?? -.infinity) - time) <= tolerance
            )
        let size: CGFloat = isActiveSection ? 12 : 8
        KeyframeDiamondShape()
            .fill(isCurrent || isGraphEndpoint ? Color.white : Color.clear)
            .overlay {
                KeyframeDiamondShape()
                    .stroke(Color.white, lineWidth: isActiveSection ? 1.5 : 1)
            }
            .frame(width: size, height: size)
            .opacity(isActiveSection ? 1 : 0.32)
            .position(x: markerX(for: time), y: 19)
            .zIndex(isActiveSection ? 2 : 1)
    }

    private func graphSegmentIndicator(_ segment: KeyframeSegment) -> some View {
        let startX = markerX(for: segment.startTime)
        let endX = markerX(for: segment.endTime)
        return Capsule()
            .fill(MotionaryTheme.accent.opacity(0.9))
            .frame(width: max(endX - startX, 2), height: 2)
            .position(x: (startX + endX) * 0.5, y: 19)
            .shadow(color: MotionaryTheme.accent.opacity(0.55), radius: 2)
            .zIndex(0)
    }

    private func markerX(for time: Double) -> CGFloat {
        min(
            max(CGFloat(time / max(item.placementDuration, 0.001)) * width, 7),
            max(width - 7, 7)
        )
    }

    private func keyframeTimes(in section: KeyframeSection) -> [Double] {
        if let clip = item.legacyClip() {
            return clip.keyframeTimes(in: section)
        }
        if case .text(let text) = item {
            return text.keyframeTimes(in: section)
        }
        return []
    }
}


private struct TransformToggleButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : MotionaryTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    isSelected ? MotionaryTheme.accent : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct EffectCommandButton: View {
    let systemName: String
    let isDisabled: Bool
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 25, height: 25)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.3 : 1)
    }
}
