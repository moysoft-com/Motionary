// Contextual transform, adjustment, and effect workspaces.

import SwiftUI
import UIKit

struct CanvasWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        EditorWorkspaceShell(
            title: "Canvas",
            systemImage: "aspectratio"
        ) {
            VStack(spacing: 12) {
                EditorWorkspaceCard(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Format", systemImage: "rectangle.on.rectangle")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(currentResolution)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(MotionaryTheme.textSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            CanvasFormatButton(
                                title: "Original",
                                aspectRatio: originalAspectRatio ?? currentAspectRatio,
                                isSelected: isOriginalSelected,
                                isEnabled: viewModel.canApplySelectedClipOriginalRatio
                            ) {
                                viewModel.setCanvasToSelectedClipOriginalRatio()
                            }

                            ForEach(CanvasRatioPreset.presets) { preset in
                                CanvasFormatButton(
                                    title: preset.title,
                                    aspectRatio: CGFloat(preset.width) / CGFloat(preset.height),
                                    isSelected: isSelected(preset)
                                ) {
                                    viewModel.setCanvasPreset(preset)
                                }
                            }
                        }
                    }
                }

                EditorWorkspaceCard(alignment: .leading, spacing: 10) {
                    Label("Background", systemImage: "paintpalette")
                        .font(.callout.weight(.semibold))

                    HStack(spacing: 10) {
                        ColorPicker(
                            "Canvas background",
                            selection: Binding(
                                get: { viewModel.project.renderSettings.backgroundColor.swiftUIColor },
                                set: { viewModel.setCanvasBackgroundColor(RGBAColor($0)) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()

                        Text("Canvas color")
                            .font(.caption.weight(.medium))
                        Spacer()
                        EditorWorkspaceCapsuleIconButton(
                            systemName: "arrow.counterclockwise",
                            accessibilityLabel: "Reset canvas background"
                        ) {
                            viewModel.setCanvasBackgroundColor(.black)
                        }
                    }
                }
            }
        }
    }

    private var isOriginalSelected: Bool {
        guard let clip = viewModel.selectedClip,
            clip.mediaType != .audio,
            let size = viewModel.project.naturalSize(for: clip)?.cgSize
        else { return false }
        let width = max(Int(abs(size.width).rounded()), 1)
        let height = max(Int(abs(size.height).rounded()), 1)
        return viewModel.project.renderSettings.width == width
            && viewModel.project.renderSettings.height == height
    }

    private func isSelected(_ preset: CanvasRatioPreset) -> Bool {
        viewModel.project.renderSettings.width == preset.width
            && viewModel.project.renderSettings.height == preset.height
    }

    private var currentResolution: String {
        let settings = viewModel.project.renderSettings
        return "\(settings.width) × \(settings.height)"
    }

    private var currentAspectRatio: CGFloat {
        let settings = viewModel.project.renderSettings
        return CGFloat(settings.width) / CGFloat(max(settings.height, 1))
    }

    private var originalAspectRatio: CGFloat? {
        guard let clip = viewModel.selectedClip,
            clip.mediaType != .audio,
            let size = viewModel.project.naturalSize(for: clip)?.displaySafeSize
        else { return nil }
        return size.width / max(size.height, 1)
    }
}

private struct CanvasFormatButton: View {
    let title: String
    let aspectRatio: CGFloat
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary, lineWidth: 1.5)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(width: 28, height: 30)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(width: 66, height: 64)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel("Canvas format \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

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

                    EditorWorkspaceColorRow(
                        title: "Color",
                        color: shape.color.swiftUIColor
                    ) {
                        viewModel.setSelectedShape(color: RGBAColor($0))
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
                            EditorWorkspaceSelectionButton(
                                title: "Horizontal",
                                systemImage: "arrow.left.and.right",
                                isSelected: clip.transform.isFlippedHorizontally,
                                isEnabled: isEnabled
                            ) {
                                viewModel.setSelectedTransform(
                                    isFlippedHorizontally: !clip.transform.isFlippedHorizontally
                                )
                            }
                            EditorWorkspaceSelectionButton(
                                title: "Vertical",
                                systemImage: "arrow.up.and.down",
                                isSelected: clip.transform.isFlippedVertically,
                                isEnabled: isEnabled
                            ) {
                                viewModel.setSelectedTransform(
                                    isFlippedVertically: !clip.transform.isFlippedVertically
                                )
                            }
                            EditorWorkspaceCapsuleIconButton(
                                systemName: "arrow.counterclockwise",
                                accessibilityLabel: "Reset transform",
                                isEnabled: isEnabled
                            ) {
                                viewModel.updateSelectedClip { $0.transform = ClipTransform() }
                            }
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
        EditorWorkspaceShell(
            title: "Transform",
            systemImage: "crop.rotate",
            isEnabled: isEnabled,
            disablesContentWhenUnavailable: true,
            accessory: {
                SectionKeyframeButton(
                    viewModel: viewModel,
                    itemID: item.id,
                    section: .transform,
                    isEnabled: isEnabled
                )
            },
            content: {
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
                        EditorWorkspaceSelectionButton(
                            title: "Horizontal",
                            systemImage: "arrow.left.and.right",
                            isSelected: item.visuals.transform.isFlippedHorizontally
                        ) {
                            updateTransform { transform in
                                transform.isFlippedHorizontally.toggle()
                            }
                        }
                        EditorWorkspaceSelectionButton(
                            title: "Vertical",
                            systemImage: "arrow.up.and.down",
                            isSelected: item.visuals.transform.isFlippedVertically
                        ) {
                            updateTransform { transform in
                                transform.isFlippedVertically.toggle()
                            }
                        }
                        EditorWorkspaceCapsuleIconButton(
                            systemName: "arrow.counterclockwise",
                            accessibilityLabel: "Reset transform"
                        ) {
                            viewModel.updateTextItem(item.id) { $0.visuals.transform = ClipTransform() }
                        }
                    }
                }
            }
        )
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
                                EditorWorkspaceIconButton(
                                    systemName: "arrow.up",
                                    accessibilityLabel: "Move effect up",
                                    isEnabled: index != 0 && isEnabled
                                ) {
                                    viewModel.moveEffect(effect.id, offset: -1)
                                }
                                EditorWorkspaceIconButton(
                                    systemName: "arrow.down",
                                    accessibilityLabel: "Move effect down",
                                    isEnabled: index != clip.effectStack.effects.count - 1 && isEnabled
                                ) {
                                    viewModel.moveEffect(effect.id, offset: 1)
                                }
                                EditorWorkspaceIconButton(
                                    systemName: "trash",
                                    accessibilityLabel: "Remove effect",
                                    isEnabled: isEnabled,
                                    role: .destructive
                                ) {
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
                        .background(MotionaryTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 13))
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
                            .background(MotionaryTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                }
            }
        }
    }
}

struct PropertyWorkspaceShell<Content: View>: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let title: String
    let systemImage: String
    let section: KeyframeSection?
    @ViewBuilder let content: (TimelineClip, Bool) -> Content

    var body: some View {
        let isEnabled = clip.map(isWorkspaceEnabled) ?? false
        EditorWorkspaceShell(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            emptyState: clip == nil
                ? EditorWorkspaceEmptyState(title: "Select a clip", systemImage: "cursorarrow.click.2")
                : nil,
            accessory: {
                if let clip, let section {
                    SectionKeyframeButton(
                        viewModel: viewModel,
                        itemID: clip.id,
                        section: section,
                        isEnabled: isEnabled
                    )
                }
            },
            content: {
                if let clip {
                    content(clip, isEnabled)
                }
            }
        )
    }

    private func isWorkspaceEnabled(_ clip: TimelineClip) -> Bool {
        viewModel.selectedClipID == clip.id && isTimeInsideTimelineItem(clip)
    }

    private func isTimeInsideTimelineItem(_ clip: TimelineClip) -> Bool {
        guard let item = viewModel.project.item(id: clip.id) else {
            return viewModel.isTimeInside(clip)
        }
        return viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
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
        let time = viewModel.timelineLocalTime(for: clip)
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
        let times = item?.keyframeTimes(in: section) ?? []
        let hasAny = !times.isEmpty
        let isSelectedItem = viewModel.selectedTimelineItemID == itemID
        let isCurrent = isSelectedItem
            && times.contains {
                abs((item?.timelineStart ?? 0) + $0 - viewModel.currentTime)
                    <= viewModel.keyframeTimeTolerance
            }

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
        .accessibilityValue(isCurrent ? "At playhead" : (hasAny ? "Active" : "Inactive"))
        .accessibilityHint(
            isCurrent ? "Removes the keyframe at the playhead." : "Adds a keyframe at the playhead."
        )
    }

    private var item: TimelineItem? {
        viewModel.project.item(id: itemID)
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
                    .fill(Color.primary.opacity(isEditing ? 0.085 : 0.045))

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
                                    Color.primary.opacity(isRoundNumber ? 0.52 : 0.24)
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
    @State private var displayTime: Double = 0

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
                    currentTime: displayTime,
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
                                        .fill(MotionaryTheme.selected)
                                        .frame(width: width+4, height: 42)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(MotionaryTheme.selected, lineWidth: 2)
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
        .background {
            TimelineDisplayLink(
                player: viewModel.player,
                isPlaying: viewModel.isPlaying
            ) { time in
                displayTime = min(max(time, 0), max(viewModel.duration, 0))
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            displayTime = viewModel.currentTime
        }
        .onChange(of: playbackState.currentTime) { _, time in
            guard !viewModel.isPlaying else { return }
            displayTime = time
        }
    }

    private var miniTimelineContentRevision: Int {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let playheadFrame = viewModel.isPlaying
            ? 0
            : Int((viewModel.currentTime * frameRate).rounded())
        let sectionValue: Int
        switch activeSection {
        case .shape: sectionValue = 1
        case .transform: sectionValue = 2
        case .adjust: sectionValue = 3
        case .effects: sectionValue = 4
        case .audio: sectionValue = 5
        case .speed: sectionValue = 6
        case .textType: sectionValue = 7
        case .textStyle: sectionValue = 8
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
            .fill(isCurrent || isGraphEndpoint ? MotionaryTheme.control : Color.clear)
            .overlay {
                KeyframeDiamondShape()
                    .stroke(MotionaryTheme.control, lineWidth: isActiveSection ? 1.5 : 1)
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
        item.keyframeTimes(in: section)
    }
}
