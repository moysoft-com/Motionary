// Focused, phase-based motion builder for text clips.

import SwiftUI

struct TextAnimationControls: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem
    @Binding var activePhase: TextAnimationPhase

    var body: some View {
        VStack(spacing: 12) {
            MotionRangeStrip(animations: item.animations, duration: item.duration)

            HStack(spacing: 8) {
                ForEach(TextAnimationPhase.allCases, id: \.rawValue) { phase in
                    phaseButton(phase)
                }
            }

            EditorWorkspaceCard(alignment: .leading, spacing: 9, padding: 11) {
                Text("Choose a motion")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        presetTile(id: nil, title: "None", systemImage: "nosign")
                        ForEach(TextAnimationPresetCatalog.definitions(for: activePhase)) { definition in
                            presetTile(
                                id: definition.id,
                                title: definition.title,
                                systemImage: motionIcon(for: definition.id)
                            )
                        }
                    }
                }
            }

            if selectedPresetID != nil {
                phaseSettings
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    Text("Pick a preset to shape this phase.")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
                .background(MotionaryTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    private var selectedPresetID: String? {
        switch activePhase {
        case .entrance: item.animations.entrance?.presetID
        case .loop: item.animations.loop?.presetID
        case .exit: item.animations.exit?.presetID
        }
    }

    private func phaseButton(_ phase: TextAnimationPhase) -> some View {
        let isSelected = activePhase == phase
        let isConfigured: Bool
        switch phase {
        case .entrance: isConfigured = item.animations.entrance != nil
        case .loop: isConfigured = item.animations.loop != nil
        case .exit: isConfigured = item.animations.exit != nil
        }

        return Button {
            activePhase = phase
            EditorHaptics.selection()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: phase.systemImage)
                    .font(.caption.weight(.semibold))
                Text(phase.shortTitle)
                    .font(.caption.weight(.semibold))
                Circle()
                    .fill(isConfigured ? phase.tint : MotionaryTheme.surfaceStrong)
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func presetTile(id: String?, title: String, systemImage: String) -> some View {
        let isSelected = id == selectedPresetID
        return Button {
            setPreset(id, phase: activePhase)
            EditorHaptics.tap()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(width: 82, height: 58)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !isSelected, id != nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(activePhase.tint.opacity(0.24), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var phaseSettings: some View {
        EditorWorkspaceCard {
            HStack {
                Label("Timing", systemImage: "timer")
                    .font(.callout.weight(.semibold))
                Spacer()
            }

            phaseTimingScrubbers
        }
    }

    @ViewBuilder
    private var phaseTimingScrubbers: some View {
        switch activePhase {
        case .entrance:
            if let entrance = item.animations.entrance {
                motionScrubber(
                    title: "Duration",
                    systemImage: "timer",
                    value: entrance.endTime,
                    range: 0.05...max(item.animations.exit?.startTime ?? item.duration, 0.05),
                    step: timeStep
                ) { value in
                    update(interactive: true) { $0.animations.entrance?.endTime = value }
                }
            }

        case .loop:
            if let loop = item.animations.loop {
                motionScrubber(
                    title: "Starts at",
                    systemImage: "arrow.right.to.line",
                    value: loop.startTime,
                    range: 0...max(loop.endTime, 0),
                    step: timeStep
                ) { value in
                    update(interactive: true) { $0.animations.loop?.startTime = value }
                }
                motionScrubber(
                    title: "Ends at",
                    systemImage: "arrow.left.to.line",
                    value: loop.endTime,
                    range: loop.startTime...max(item.duration, loop.startTime),
                    step: timeStep
                ) { value in
                    update(interactive: true) { $0.animations.loop?.endTime = value }
                }
                motionScrubber(
                    title: "Cycle",
                    systemImage: "repeat",
                    value: loop.cycleDuration,
                    range: 0.05...max(item.duration, 0.05),
                    step: timeStep
                ) { value in
                    update(interactive: true) { $0.animations.loop?.cycleDuration = value }
                }
            }

        case .exit:
            if let exit = item.animations.exit {
                let duration = max(item.duration - exit.startTime, 0.05)
                let maximum = max(item.duration - (item.animations.entrance?.endTime ?? 0), 0.05)
                motionScrubber(
                    title: "Duration",
                    systemImage: "timer",
                    value: duration,
                    range: 0.05...maximum,
                    step: timeStep
                ) { value in
                    update(interactive: true) { $0.animations.exit?.startTime = max($0.duration - value, 0) }
                }
            }
        }
    }

    private var timeStep: Double {
        max(min(item.duration / 600, 0.05), 0.01)
    }

    private func motionScrubber(
        title: String,
        systemImage: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        onChanged: @escaping (Double) -> Void
    ) -> some View {
        EditorValueScrubber(
            title: title,
            systemImage: systemImage,
            value: value,
            range: range,
            step: step,
            format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" },
            onBegan: viewModel.beginInteractiveEdit,
            onChanged: onChanged,
            onEnded: viewModel.finishTextEditing
        )
    }

    private func setPreset(_ presetID: String?, phase: TextAnimationPhase) {
        update(interactive: false) { text in
            switch phase {
            case .entrance:
                guard let presetID else {
                    text.animations.entrance = nil
                    return
                }
                let maximumEnd = text.animations.exit?.startTime ?? text.duration
                text.animations.entrance = TextEntranceAnimationConfiguration(
                    presetID: presetID,
                    endTime: text.animations.entrance.map { min($0.endTime, maximumEnd) }
                        ?? min(0.6, maximumEnd),
                    timing: text.animations.entrance?.timing ?? .easeOut,
                    customInterpolation: text.animations.entrance?.customInterpolation
                )
            case .loop:
                guard let presetID else {
                    text.animations.loop = nil
                    return
                }
                text.animations.loop = TextLoopAnimationConfiguration(
                    presetID: presetID,
                    startTime: text.animations.loop?.startTime ?? 0,
                    endTime: text.animations.loop?.endTime ?? text.duration,
                    cycleDuration: text.animations.loop?.cycleDuration ?? min(1, max(text.duration, 0.05)),
                    timing: text.animations.loop?.timing ?? .easeInOut,
                    customInterpolation: text.animations.loop?.customInterpolation
                )
            case .exit:
                guard let presetID else {
                    text.animations.exit = nil
                    return
                }
                let minimumStart = text.animations.entrance?.endTime ?? 0
                text.animations.exit = TextExitAnimationConfiguration(
                    presetID: presetID,
                    startTime: text.animations.exit.map { max($0.startTime, minimumStart) }
                        ?? max(text.duration - 0.6, minimumStart),
                    timing: text.animations.exit?.timing ?? .easeIn,
                    customInterpolation: text.animations.exit?.customInterpolation
                )
            }
        }
    }

    private func motionIcon(for presetID: String) -> String {
        if presetID.contains("fade") || presetID.contains("flicker") { return "circle.lefthalf.filled" }
        if presetID.contains("slideUp") { return "arrow.up" }
        if presetID.contains("slideDown") { return "arrow.down" }
        if presetID.contains("slideLeft") { return "arrow.left" }
        if presetID.contains("slideRight") { return "arrow.right" }
        if presetID.contains("scale") || presetID.contains("pop") || presetID.contains("pulse") { return "arrow.up.left.and.arrow.down.right" }
        if presetID.contains("typewriter") { return "character.cursor.ibeam" }
        if presetID.contains("spin") || presetID.contains("swing") || presetID.contains("wobble") { return "rotate.right" }
        if presetID.contains("wipe") { return "rectangle.split.1x2" }
        if presetID.contains("float") || presetID.contains("bounce") { return "arrow.up.and.down" }
        if presetID.contains("shake") { return "waveform.path" }
        return "sparkles"
    }

    private func update(
        interactive: Bool,
        _ change: @escaping (inout TextTimelineItem) -> Void
    ) {
        viewModel.updateTextItem(item.id, interactive: interactive, change)
    }
}

struct TextMotionGraphWorkspace: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem?
    let phase: TextAnimationPhase

    var body: some View {
        let context = workspaceContext
        EditorWorkspaceShell(
            title: "\(phase.shortTitle) Motion",
            systemImage: "point.topleft.down.curvedto.point.bottomright.up",
            emptyState: context == nil
                ? EditorWorkspaceEmptyState(
                    title: "Choose a motion for this phase first",
                    systemImage: "sparkles"
                )
                : nil,
            contentStyle: .fixed,
            accessory: {
                if let context {
                    Text(
                        "\(formatClock(context.range.lowerBound)) – "
                            + formatClock(context.range.upperBound)
                    )
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
                }
            },
            content: {
                if let context {
                    EditorEasingGraph(
                        viewModel: viewModel,
                        timelineStart: context.item.timelineStart,
                        range: context.range,
                        interpolation: context.interpolation,
                        horizontalInset: 24,
                        exposesDefaultHandles: true,
                        overshoot: .clamped(-0.3...1.3),
                        onHandleBegan: viewModel.beginInteractiveEdit,
                        onInterpolationChanged: { interpolation in
                            setInterpolation(interpolation, for: context.item.id, interactive: true)
                        },
                        onHandleEnded: viewModel.finishTextEditing
                    )

                    Label("Drag the two handles to shape this phase.", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        )
    }

    private var workspaceContext: (
        item: TextTimelineItem,
        range: ClosedRange<Double>,
        interpolation: KeyframeInterpolation
    )? {
        guard let currentItem, let graphContext = graphContext(for: currentItem) else { return nil }
        return (currentItem, graphContext.range, graphContext.interpolation)
    }

    private var currentItem: TextTimelineItem? {
        guard let item,
            case .text(let current) = viewModel.project.item(id: item.id)
        else { return nil }
        return current
    }

    private func graphContext(
        for item: TextTimelineItem
    ) -> (range: ClosedRange<Double>, interpolation: KeyframeInterpolation)? {
        switch phase {
        case .entrance:
            guard let entrance = item.animations.entrance else { return nil }
            return (0...max(entrance.endTime, 0.000_001), entrance.interpolation)
        case .loop:
            guard let loop = item.animations.loop else { return nil }
            let upper = min(loop.startTime + loop.cycleDuration, loop.endTime)
            return (
                loop.startTime...max(upper, loop.startTime + 0.000_001),
                loop.interpolation
            )
        case .exit:
            guard let exit = item.animations.exit else { return nil }
            return (
                exit.startTime...max(item.duration, exit.startTime + 0.000_001),
                exit.interpolation
            )
        }
    }

    private func setInterpolation(
        _ interpolation: KeyframeInterpolation,
        for itemID: UUID,
        interactive: Bool
    ) {
        viewModel.updateTextItem(itemID, interactive: interactive) { item in
            switch phase {
            case .entrance:
                item.animations.entrance?.customInterpolation = interpolation
            case .loop:
                item.animations.loop?.customInterpolation = interpolation
            case .exit:
                item.animations.exit?.customInterpolation = interpolation
            }
        }
    }
}


private struct MotionRangeStrip: View {
    let animations: TextAnimationSet
    let duration: Double

    var body: some View {
        EditorWorkspaceCard(spacing: 7, padding: 11) {
            HStack {
                Text("Clip motion")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(duration.formatted(.number.precision(.fractionLength(2))) + " s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(MotionaryTheme.surface)
                    if let entrance = animations.entrance {
                        segment(
                            color: TextAnimationPhase.entrance.tint,
                            start: 0,
                            end: entrance.endTime,
                            width: proxy.size.width
                        )
                    }
                    if let loop = animations.loop {
                        segment(
                            color: TextAnimationPhase.loop.tint,
                            start: loop.startTime,
                            end: loop.endTime,
                            width: proxy.size.width
                        )
                    }
                    if let exit = animations.exit {
                        segment(
                            color: TextAnimationPhase.exit.tint,
                            start: exit.startTime,
                            end: duration,
                            width: proxy.size.width
                        )
                    }
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Configured text motion across the clip")
    }

    private func segment(
        color: Color,
        start: Double,
        end: Double,
        width: CGFloat
    ) -> some View {
        let safeDuration = max(duration, 0.000_001)
        let lower = min(max(start, 0), safeDuration)
        let upper = min(max(end, lower), safeDuration)
        let x = CGFloat(lower / safeDuration) * width
        let segmentWidth = max(CGFloat((upper - lower) / safeDuration) * width, 2)
        return Capsule()
            .fill(color.opacity(0.78))
            .frame(width: segmentWidth, height: 12)
            .offset(x: x)
    }
}

extension TextAnimationPhase {
    var shortTitle: String {
        switch self {
        case .entrance: "In"
        case .loop: "Loop"
        case .exit: "Out"
        }
    }

    var systemImage: String {
        switch self {
        case .entrance: "arrow.right.to.line"
        case .loop: "repeat"
        case .exit: "arrow.left.to.line"
        }
    }

    var tint: Color {
        switch self {
        case .entrance: .cyan
        case .loop: MotionaryTheme.accent
        case .exit: .pink
        }
    }
}
