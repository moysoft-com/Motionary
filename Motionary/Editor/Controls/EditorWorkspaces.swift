// Contextual transform, adjustment, and effect workspaces.

import SwiftUI

struct TransformWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Transform",
            systemImage: "crop.rotate"
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                PropertyScrubber(viewModel: viewModel, clip: clip, target: .positionX, isEnabled: isEnabled)
                PropertyScrubber(viewModel: viewModel, clip: clip, target: .positionY, isEnabled: isEnabled)
                PropertyScrubber(viewModel: viewModel, clip: clip, target: .rotation, isEnabled: isEnabled)

                HStack {
                    Text("Scale")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker(
                        "Scale dimensions",
                        selection: Binding(
                            get: { clip.transform.scale.isLinked },
                            set: { viewModel.setScaleLinked($0) }
                        )
                    ) {
                        Label("Split", systemImage: "link.badge.plus").tag(false)
                        Label("Linked", systemImage: "link").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 178)
                    .disabled(!isEnabled)
                }

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

struct AdjustWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Adjust",
            systemImage: "camera.filters"
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType != .audio {
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .opacity, isEnabled: isEnabled)
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .brightness, isEnabled: isEnabled)
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .contrast, isEnabled: isEnabled)
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .saturation, isEnabled: isEnabled)
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .exposure, isEnabled: isEnabled)
                }
                if clip.mediaType == .audio || clip.mediaType == .video {
                    PropertyScrubber(viewModel: viewModel, clip: clip, target: .volume, isEnabled: isEnabled)
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
            systemImage: "wand.and.stars"
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
    @ViewBuilder let content: (TimelineClip, Bool) -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))

            if let clip {
                let isEnabled =
                    viewModel.selectedClipID == clip.id
                    && viewModel.isTimeInside(clip)
                VStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Label(title, systemImage: systemImage)
                            .font(.headline.weight(.semibold))
                        Text(clip.name)
                            .font(.caption)
                            .foregroundStyle(MotionaryTheme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            viewModel.isAutoKeyEnabled.toggle()
                            EditorHaptics.tap()
                        } label: {
                            Label(
                                "Auto",
                                systemImage: viewModel.isAutoKeyEnabled
                                    ? "record.circle.fill"
                                    : "record.circle"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(viewModel.isAutoKeyEnabled ? Color.black : MotionaryTheme.textPrimary)
                        .background(
                            viewModel.isAutoKeyEnabled ? MotionaryTheme.accent : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                        .disabled(!isEnabled)
                    }

                    if !isEnabled {
                        Text(
                            viewModel.selectedClipID == nil
                                ? "Clip deselected"
                                : "Move the playhead onto the selected clip to edit."
                        )
                        .font(.caption2)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

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
    let clip: TimelineClip
    let target: KeyframeTarget
    let isEnabled: Bool

    @State private var dragStartValue: Double?
    @State private var tickOffset: CGFloat = 0

    var body: some View {
        let metadata = clip.keyframeMetadata(for: target)
        let value = displayedValue
        let hasAnyKeyframes =
            clip.animatableProperty(for: target)?.keyframes.isEmpty == false
        HStack(spacing: 8) {
            Label(metadata.title, systemImage: metadata.systemImage)
                .font(.caption.weight(.medium))
                .labelStyle(.titleOnly)
                .frame(width: 82, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geometry in
                Canvas { context, size in
                    let spacing: CGFloat = 14
                    let remainder = tickOffset.truncatingRemainder(dividingBy: spacing)
                    let count = Int(size.width / spacing) + 4
                    for index in -count...count {
                        let x = size.width * 0.5 + CGFloat(index) * spacing + remainder
                        guard x >= 0, x <= size.width else { continue }
                        let major = index.isMultiple(of: 5)
                        let rect = CGRect(
                            x: x - 0.75,
                            y: major ? 9 : 15,
                            width: 1.5,
                            height: major ? 26 : 14
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(Color.white.opacity(major ? 0.72 : 0.25))
                        )
                    }
                    let center = CGRect(x: size.width * 0.5 - 1.5, y: 4, width: 3, height: 36)
                    context.fill(
                        Path(roundedRect: center, cornerRadius: 1.5),
                        with: .color(MotionaryTheme.accent)
                    )
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(metadata: metadata, currentValue: value))
                .onTapGesture {
                    viewModel.activeKeyframeTarget = target
                }
            }
            .frame(height: 44)

            Text(formatted(value, metadata: metadata))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 54, alignment: .trailing)

            Button {
                viewModel.activeKeyframeTarget = target
                viewModel.toggleKeyframe(target)
                EditorHaptics.tap()
            } label: {
                KeyframeDiamondShape()
                    .fill(
                        viewModel.hasKeyframe(atPlayhead: target)
                            ? MotionaryTheme.accent
                            : Color.clear
                    )
                    .overlay {
                        KeyframeDiamondShape()
                            .stroke(
                                hasAnyKeyframes
                                    ? MotionaryTheme.accent
                                    : MotionaryTheme.textSecondary,
                                lineWidth: 1.5
                            )
                    }
                    .frame(width: 14, height: 14)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 48)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 13))
        .disabled(!isEnabled)
    }

    private var displayedValue: Double {
        if viewModel.selectedClipID == clip.id {
            return viewModel.displayedValue(for: target)
        }
        let time = min(max(viewModel.currentTime - clip.timelineStart, 0), clip.sourceRange.duration)
        return clip.animatableProperty(for: target)?.value(at: time) ?? 0
    }

    private func scrubGesture(
        metadata: KeyframePropertyMetadata,
        currentValue: Double
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartValue == nil {
                    dragStartValue = currentValue
                    viewModel.activeKeyframeTarget = target
                    viewModel.beginInteractiveEdit()
                }
                guard let start = dragStartValue else { return }
                tickOffset = gesture.translation.width
                let proposed: Double
                if target.isScaleTarget {
                    proposed = start * exp(Double(gesture.translation.width) / 115)
                } else {
                    proposed = start + Double(gesture.translation.width) * sensitivity(metadata: metadata)
                }
                viewModel.setSelectedKeyframeValue(
                    proposed,
                    target: target,
                    interactive: true
                )
            }
            .onEnded { _ in
                dragStartValue = nil
                tickOffset = 0
                viewModel.finishInteractiveEdit()
            }
    }

    private func sensitivity(metadata: KeyframePropertyMetadata) -> Double {
        switch target {
        case .positionX, .positionY:
            0.006
        case .rotation:
            0.8
        case .opacity, .brightness, .contrast, .saturation, .exposure, .effectIntensity, .volume:
            max(metadata.step * 0.6, 0.005)
        case .scale, .scaleX, .scaleY:
            0
        }
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

struct SelectedLayerMiniTimeline: View {
    @ObservedObject var viewModel: EditorViewModel
    let contextClipID: UUID?
    @Binding var pixelsPerSecond: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if let contextClipID,
                let track = viewModel.project.tracks.first(where: {
                    $0.clips.contains { $0.id == contextClipID }
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
                    contentRevision: viewModel.timelineContentRevision,
                    contentSize: CGSize(width: contentWidth, height: geometry.size.height),
                    isScrollDisabled: false,
                    onScrubStart: { viewModel.beginScrub() },
                    onScrubChanged: { viewModel.updateScrub(to: $0) },
                    onScrubEnd: { viewModel.endScrub(at: $0) },
                    onPullToAddChanged: { _ in },
                    onPullToAddEnded: { _ in }
                ) {
                    ZStack(alignment: .leading) {
                        Color.clear
                        ForEach(track.clips) { clip in
                            let width = max(CGFloat(clip.sourceRange.duration) * pixelsPerSecond, 6)
                            TimelineClipFill(
                                clip: clip,
                                width: width,
                                height: 38,
                                pixelsPerSecond: pixelsPerSecond,
                                sampleWidth: nil
                            )
                            .frame(width: width, height: 38)
                            .overlay {
                                MiniTimelineKeyframes(
                                    clip: clip,
                                    currentTime: viewModel.currentTime,
                                    tolerance: viewModel.keyframeTimeTolerance,
                                    width: width
                                )
                            }
                            .opacity(clip.id == contextClipID ? 1 : 0.22)
                            .offset(x: centerPadding + CGFloat(clip.timelineStart) * pixelsPerSecond)
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
}

private struct MiniTimelineKeyframes: View {
    let clip: TimelineClip
    let currentTime: Double
    let tolerance: Double
    let width: CGFloat

    var body: some View {
        ZStack {
            ForEach(clip.allKeyframeTimes, id: \.self) { time in
                let selected = abs((clip.timelineStart + time) - currentTime) <= tolerance
                KeyframeDiamondShape()
                    .fill(selected ? Color.white : Color.clear)
                    .overlay(KeyframeDiamondShape().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(
                        x: min(
                            max(CGFloat(time / max(clip.sourceRange.duration, 0.001)) * width, 7),
                            max(width - 7, 7)
                        ),
                        y: 19
                    )
            }
        }
        .frame(width: width, height: 38)
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
