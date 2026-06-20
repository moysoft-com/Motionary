// Contextual transform, adjustment, and effect workspaces.

import SwiftUI
import UIKit

struct TransformWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
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
    let section: KeyframeSection
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
                        SectionKeyframeButton(
                            viewModel: viewModel,
                            clip: clip,
                            section: section,
                            isEnabled: isEnabled
                        )
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
    let clip: TimelineClip
    let target: KeyframeTarget
    let isEnabled: Bool

    @State private var dragStartValue: Double?
    @State private var dragStartTickPosition: CGFloat?
    @State private var rulerTickPosition: CGFloat?
    @State private var lastHapticBucket: Int?
    @State private var isDragging = false
    @State private var isScrubbing = false
    @State private var momentumTask: Task<Void, Never>?

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
                    onChanged: { translation in
                        updateScrub(
                            translation: translation,
                            metadata: metadata,
                            currentValue: value
                        )
                    },
                    onEnded: { translation, velocity in
                        endScrub(
                            translation: translation,
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

    private func updateScrub(
        translation: CGFloat,
        metadata: KeyframePropertyMetadata,
        currentValue: Double
    ) {
        if !isDragging {
            momentumTask?.cancel()
            momentumTask = nil
            if isScrubbing {
                viewModel.finishInteractiveEdit()
            }
            dragStartValue = currentValue
            dragStartTickPosition = tickPosition(
                for: currentValue,
                metadata: metadata
            )
            rulerTickPosition = dragStartTickPosition
            isDragging = true
            isScrubbing = true
            viewModel.activeKeyframeTarget = target
            viewModel.beginInteractiveEdit()
            EditorHaptics.scrubStart()
        }
        guard let startPosition = dragStartTickPosition else { return }
        let position = boundedTickPosition(
            startPosition - translation / InfiniteScrubberTrack.tickSpacing,
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
        translation: CGFloat,
        velocity: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard let startPosition = dragStartTickPosition else { return }
        let position = boundedTickPosition(
            startPosition - translation / InfiniteScrubberTrack.tickSpacing,
            metadata: metadata
        )
        rulerTickPosition = position
        isDragging = false
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
        guard let position = rulerTickPosition else {
            finishScrubbing()
            return
        }
        let maximum = maximumTickPosition(metadata: clip.keyframeMetadata(for: target))
        let snappedPosition =
            position <= 0.5
            ? 0
            : (position >= maximum - 0.5 ? maximum : position.rounded())
        withAnimation(.spring(duration: 0.22, bounce: 0.12)) {
            rulerTickPosition = snappedPosition
        }

        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        let metadata = clip.keyframeMetadata(for: target)
        viewModel.setSelectedKeyframeValue(
            value(at: snappedPosition, metadata: metadata),
            target: target,
            interactive: true
        )
        finishScrubbing()
    }

    private func finishScrubbing() {
        dragStartValue = nil
        dragStartTickPosition = nil
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

private struct SectionKeyframeButton: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip
    let section: KeyframeSection
    let isEnabled: Bool

    var body: some View {
        let hasAny = viewModel.hasKeyframes(in: section, clip: clip)
        let isCurrent =
            viewModel.selectedClipID == clip.id
            && viewModel.hasKeyframe(atPlayhead: section)

        Button {
            viewModel.toggleKeyframeSection(section)
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
        .disabled(!isEnabled || clip.keyframeTargets(in: section).isEmpty)
        .opacity(clip.keyframeTargets(in: section).isEmpty ? 0.3 : 1)
        .accessibilityLabel("\(section.rawValue) keyframe")
    }
}

private struct InfiniteScrubberTrack: View {
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
                    let maximumIndex = Int(ceil(maximumTickPosition))

                    for index in 0...maximumIndex {
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

private struct HorizontalScrubInteraction: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
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
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .changed:
                onChanged(translation)
            case .ended, .cancelled:
                onEnded(translation, recognizer.velocity(in: recognizer.view).x)
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
    @Binding var contextClipID: UUID?
    @Binding var pixelsPerSecond: CGFloat
    let activeSection: KeyframeSection?
    let graphSegment: KeyframeSegment?

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
                    contentRevision: miniTimelineContentRevision,
                    contentSize: CGSize(width: contentWidth, height: geometry.size.height),
                    isScrollDisabled: false,
                    allowsVerticalScrolling: false,
                    onScrubStart: { viewModel.beginScrub() },
                    onScrubChanged: { time in
                        viewModel.updateScrub(to: time)
                        selectClipIfNeeded(at: time, in: track)
                    },
                    onScrubEnd: { time in
                        viewModel.endScrub(at: time)
                        selectClipIfNeeded(at: time, in: track)
                    },
                    onPullToAddChanged: { _ in },
                    onPullToAddEnded: { _ in }
                ) {
                    ZStack(alignment: .leading) {
                        Color.clear
                        ForEach(track.clips) { clip in
                            let width = max(CGFloat(clip.sourceRange.duration) * pixelsPerSecond, 6)
                            ZStack {
                                if clip.id == contextClipID {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white)
                                        .frame(width: width+4, height: 42)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.white, lineWidth: 2)
                                        }
                                        .allowsHitTesting(false)
                                }

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
                                        width: width,
                                        activeSection: activeSection,
                                        graphSegment: graphSegment
                                    )
                                }
                            }
                            .frame(width: width, height: 42)
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

    private func selectClipIfNeeded(at time: Double, in track: TimelineTrack) {
        guard let clip = track.clips.first(where: {
            time >= $0.timelineStart && time < $0.timelineEnd
        }) else {
            return
        }
        guard clip.id != contextClipID || clip.id != viewModel.selectedClipID else {
            return
        }

        contextClipID = clip.id
        viewModel.selectClip(clip.id, trackID: track.id)
        EditorHaptics.selection()
    }

    private var miniTimelineContentRevision: Int {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let playheadFrame = Int((viewModel.currentTime * frameRate).rounded())
        let sectionValue: Int
        switch activeSection {
        case .transform: sectionValue = 1
        case .adjust: sectionValue = 2
        case .effects: sectionValue = 3
        case .audio: sectionValue = 4
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
    let clip: TimelineClip
    let currentTime: Double
    let tolerance: Double
    let width: CGFloat
    let activeSection: KeyframeSection?
    let graphSegment: KeyframeSegment?

    var body: some View {
        ZStack {
            if let graphSegment, graphSegment.clipID == clip.id {
                graphSegmentIndicator(graphSegment)
            }

            ForEach(KeyframeSection.allCases) { section in
                ForEach(clip.keyframeTimes(in: section), id: \.self) { time in
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
            && abs((clip.timelineStart + time) - currentTime) <= tolerance
        let isGraphEndpoint =
            graphSegment?.clipID == clip.id
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
            max(CGFloat(time / max(clip.sourceRange.duration, 0.001)) * width, 7),
            max(width - 7, 7)
        )
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
