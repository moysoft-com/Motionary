// Focused, phase-based motion builder for text clips.

import SwiftUI

struct TextAnimationControls: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem
    @Binding var activePhase: TextAnimationPhase

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(TextAnimationPhase.allCases, id: \.rawValue) { phase in
                    phaseButton(phase)
                }
            }

            MotionRangeStrip(
                viewModel: viewModel,
                item: item,
                phase: activePhase
            )

            EditorWorkspaceSection(title: "Preset") {
                EditorWorkspaceHorizontalStrip {
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

            if selectedPresetID != nil {
                phaseSettings
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

        return EditorWorkspacePillButton(
            title: phase.shortTitle,
            systemImage: phase.systemImage,
            isSelected: isSelected,
            indicatorColor: isConfigured ? phase.tint : nil,
            haptic: { EditorHaptics.selection() }
        ) {
            activePhase = phase
        }
    }

    private func presetTile(id: String?, title: String, systemImage: String) -> some View {
        let isSelected = id == selectedPresetID
        return EditorWorkspaceTileButton(
            title: title,
            systemImage: systemImage,
            isSelected: isSelected
        ) {
            setPreset(id, phase: activePhase)
        }
    }

    @ViewBuilder
    private var phaseSettings: some View {
        phaseTimingScrubbers
    }

    @ViewBuilder
    private var phaseTimingScrubbers: some View {
        switch activePhase {
        case .entrance:
//            if let entrance = item.animations.entrance {
//                motionScrubber(
//                    title: "Duration",
//                    systemImage: "timer",
//                    value: entrance.endTime,
//                    range: 0.05...max(item.animations.exit?.startTime ?? item.duration, 0.05),
//                    step: timeStep
//                ) { value in
//                    update(interactive: true) { $0.animations.entrance?.endTime = value }
//                }
//            }
            EmptyView()

        case .loop:
            if let loop = item.animations.loop {
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
//            if let exit = item.animations.exit {
//                let duration = max(item.duration - exit.startTime, 0.05)
//                let maximum = max(item.duration - (item.animations.entrance?.endTime ?? 0), 0.05)
//                motionScrubber(
//                    title: "Duration",
//                    systemImage: "timer",
//                    value: duration,
//                    range: 0.05...maximum,
//                    step: timeStep
//                ) { value in
//                    update(interactive: true) { $0.animations.exit?.startTime = max($0.duration - value, 0) }
//                }
//            }
            EmptyView()
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
        if presetID.contains("scale") || presetID.contains("pop") || presetID.contains("pulse") {
            return "arrow.up.left.and.arrow.down.right"
        }
        if presetID.contains("typewriter") { return "character.cursor.ibeam" }
        if presetID.contains("spin") || presetID.contains("swing") || presetID.contains("wobble") {
            return "rotate.right"
        }
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

    private var workspaceContext:
        (
            item: TextTimelineItem,
            range: ClosedRange<Double>,
            interpolation: KeyframeInterpolation
        )?
    {
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
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem
    let phase: TextAnimationPhase

    @State private var dragState: DragState?

    private enum Edge {
        case lower
        case upper
    }

    private struct DragState {
        let edge: Edge
        let lowerBound: Double
        let upperBound: Double
    }

    var body: some View {
        if isConfigured {
            VStack(spacing: 8) {
                HStack {
                    Text("Duration")
                        .font(MotionaryDesign.Typography.sectionTitle)
                    Spacer()
                    Text(rangeLabel)
                        .font(MotionaryDesign.Typography.controlValue)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                }

                GeometryReader { proxy in
                    let horizontalInset: CGFloat = 0
                    let trackWidth = max(proxy.size.width - horizontalInset * 2, 1)
                    let positions = handlePositions(width: trackWidth, inset: horizontalInset)

                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(MotionaryTheme.surface)
                            .frame(width: trackWidth, height: 12)
                            .offset(x: horizontalInset, y: 16)

                        if isConfigured {
                            Capsule()
                                .fill(phase.tint.opacity(0.82))
                                .frame(width: max(positions.upper - positions.lower, 2), height: 12)
                                .offset(x: positions.lower, y: 16)
                        }

                        if canEditLowerBound {
                            rangeHandle(edge: .lower, trackWidth: trackWidth)
                                .position(x: positions.lower, y: 22)
                        }

                        if canEditUpperBound {
                            rangeHandle(edge: .upper, trackWidth: trackWidth)
                                .position(x: positions.upper, y: 22)
                        }
                    }
                }
                .frame(height: MotionaryDesign.Control.rangeStripHeight)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(phase.shortTitle) motion range")
            .accessibilityValue(rangeLabel)
            .onChange(of: phase) { _, _ in finishDragging() }
            .onChange(of: item.id) { _, _ in finishDragging() }
            .onDisappear(perform: finishDragging)
            .transaction { transaction in
                if dragState != nil {
                    transaction.animation = nil
                }
            }
        }
    }

    private var currentRange: ClosedRange<Double> {
        switch phase {
        case .entrance:
            0...max(item.animations.entrance?.endTime ?? 0, 0)
        case .loop:
            (item.animations.loop?.startTime ?? 0)...max(
                item.animations.loop?.endTime ?? item.duration,
                item.animations.loop?.startTime ?? 0
            )
        case .exit:
            min(item.animations.exit?.startTime ?? item.duration, item.duration)...item.duration
        }
    }

    private var rangeLabel: String {
        guard isConfigured else { return "No motion" }
        return "\(format(currentRange.lowerBound)) – \(format(currentRange.upperBound)) s"
    }

    private var canEditLowerBound: Bool {
        isConfigured && (phase == .loop || phase == .exit)
    }

    private var canEditUpperBound: Bool {
        isConfigured && (phase == .entrance || phase == .loop)
    }

    private var isConfigured: Bool {
        switch phase {
        case .entrance:
            item.animations.entrance != nil
        case .loop:
            item.animations.loop != nil
        case .exit:
            item.animations.exit != nil
        }
    }

    private func handlePositions(width: CGFloat, inset: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        let duration = max(item.duration, 0.000_001)
        let range = currentRange
        return (
            inset + CGFloat(range.lowerBound / duration) * width,
            inset + CGFloat(range.upperBound / duration) * width
        )
    }

    private func rangeHandle(edge: Edge, trackWidth: CGFloat) -> some View {
        Image(systemName: edge == .lower ? "chevron.left" : "chevron.right")
            .font(MotionaryDesign.Typography.rangeHandle)
            .foregroundStyle(MotionaryTheme.foregroundOnAccent)
            .frame(
                width: MotionaryDesign.Control.rangeHandleSize.width,
                height: MotionaryDesign.Control.rangeHandleSize.height
            )
            .background(phase.tint, in: Capsule())
            .frame(
                width: MotionaryDesign.Control.rangeHandleHitSize.width,
                height: MotionaryDesign.Control.rangeHandleHitSize.height
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { gesture in
                        update(edge: edge, translation: gesture.translation.width, trackWidth: trackWidth)
                    }
                    .onEnded { _ in finishDragging() }
            )
    }

    private func update(edge: Edge, translation: CGFloat, trackWidth: CGFloat) {
        let initialState: DragState
        if let dragState {
            initialState = dragState
        } else {
            let range = currentRange
            initialState = DragState(
                edge: edge,
                lowerBound: range.lowerBound,
                upperBound: range.upperBound
            )
        }

        guard initialState.edge == edge else { return }
        let delta = Double(translation / max(trackWidth, 1)) * item.duration
        let proposedValue = proposedValue(for: edge, state: initialState, delta: delta)
        let currentValue = edge == .lower ? currentRange.lowerBound : currentRange.upperBound
        let minimumVisibleChange = max(item.duration / Double(max(trackWidth, 1)) * 0.1, 0.000_01)
        guard abs(proposedValue - currentValue) >= minimumVisibleChange else { return }
        if dragState == nil {
            dragState = initialState
        }

        viewModel.updateTextItem(
            item.id,
            interactive: true,
            refreshTimeline: false
        ) { text in
            switch (phase, edge) {
            case (.entrance, .upper):
                text.animations.entrance?.endTime = proposedValue
            case (.loop, .lower):
                text.animations.loop?.startTime = proposedValue
            case (.loop, .upper):
                text.animations.loop?.endTime = proposedValue
            case (.exit, .lower):
                text.animations.exit?.startTime = proposedValue
            default:
                break
            }
        }
    }

    private func proposedValue(for edge: Edge, state: DragState, delta: Double) -> Double {
        let minimumLength = min(0.05, item.duration)
        switch (phase, edge) {
        case (.entrance, .upper):
            let maximum = item.animations.exit?.startTime ?? item.duration
            return min(max(state.upperBound + delta, minimumLength), maximum)
        case (.loop, .lower):
            return min(
                max(state.lowerBound + delta, 0),
                max(state.upperBound - minimumLength, 0)
            )
        case (.loop, .upper):
            return min(
                max(state.upperBound + delta, state.lowerBound + minimumLength),
                item.duration
            )
        case (.exit, .lower):
            let minimum = item.animations.entrance?.endTime ?? 0
            return min(
                max(state.lowerBound + delta, minimum),
                max(item.duration - minimumLength, minimum)
            )
        default:
            return edge == .lower ? state.lowerBound : state.upperBound
        }
    }

    private func finishDragging() {
        guard dragState != nil else { return }
        dragState = nil
        viewModel.finishTextEditing()
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
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
        case .entrance: .purple
        case .loop: .yellow
        case .exit: .pink
        }
    }
}
