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

            VStack(alignment: .leading, spacing: 9) {
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
            .padding(11)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

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
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
                    .fill(isConfigured ? phase.tint : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(isSelected ? Color.black : MotionaryTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                isSelected ? MotionaryTheme.accent : Color.white.opacity(0.06),
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
            .foregroundStyle(isSelected ? Color.black : MotionaryTheme.textPrimary)
            .frame(width: 82, height: 58)
            .background(
                isSelected ? MotionaryTheme.accent : Color.white.opacity(0.06),
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
        VStack(spacing: 12) {
            HStack {
                Label("Timing", systemImage: "timer")
                    .font(.callout.weight(.semibold))
                Spacer()
            }

            phaseTimingScrubbers
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
        Group {
            if let currentItem, let graphContext = graphContext(for: currentItem) {
                VStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Label(
                            "\(phase.shortTitle) Motion",
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        )
                        .font(.headline.weight(.semibold))
                        Spacer()
                        Text(
                            "\(formatClock(graphContext.range.lowerBound)) – "
                                + formatClock(graphContext.range.upperBound)
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    }
                    .frame(height: 22)

                    TextMotionEasingGraph(
                        viewModel: viewModel,
                        item: currentItem,
                        range: graphContext.range,
                        interpolation: graphContext.interpolation,
                        onInterpolationChanged: { interpolation in
                            setInterpolation(interpolation, for: currentItem.id, interactive: true)
                        },
                        onEditingEnded: viewModel.finishTextEditing
                    )

                    Label("Drag the two handles to shape this phase.", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            } else {
                Label("Choose a motion for this phase first", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .motionaryGlass(cornerRadius: 20)
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

private struct TextMotionEasingGraph: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let item: TextTimelineItem
    let range: ClosedRange<Double>
    let interpolation: KeyframeInterpolation
    let onInterpolationChanged: (KeyframeInterpolation) -> Void
    let onEditingEnded: () -> Void

    @State private var dragMode: TextMotionGraphDragMode?
    @State private var workingControl1: KeyframeControlPoint?
    @State private var workingControl2: KeyframeControlPoint?
    @State private var snappedHandleAxes: GraphHandleSnapAxes = []

    init(
        viewModel: EditorViewModel,
        item: TextTimelineItem,
        range: ClosedRange<Double>,
        interpolation: KeyframeInterpolation,
        onInterpolationChanged: @escaping (KeyframeInterpolation) -> Void,
        onEditingEnded: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.item = item
        self.range = range
        self.interpolation = interpolation
        self.onInterpolationChanged = onInterpolationChanged
        self.onEditingEnded = onEditingEnded
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 24,
                y: 34,
                width: max(geometry.size.width - 48, 1),
                height: max(geometry.size.height - 68, 1)
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.28))

                grid(in: plot)

                curvePath(in: plot)
                    .stroke(
                        MotionaryTheme.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .position(point(x: 0, y: 0, in: plot))
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .position(point(x: 1, y: 1, in: plot))

                playhead(in: plot)
                handleLayer(plot: plot)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "TextMotionGraph")
            .highPriorityGesture(graphDragGesture(plot: plot))
        }
    }

    private var displayedInterpolation: KeyframeInterpolation {
        guard let workingControl1, let workingControl2 else { return interpolation }
        return .cubicBezier(control1: workingControl1, control2: workingControl2)
    }

    private var editableControlPoints: (KeyframeControlPoint, KeyframeControlPoint) {
        if let workingControl1, let workingControl2 {
            return (workingControl1, workingControl2)
        }
        if case .cubicBezier(let control1, let control2) = interpolation {
            return (control1, control2)
        }
        return (
            KeyframeControlPoint(x: 0.33, y: 0.33),
            KeyframeControlPoint(x: 0.67, y: 0.67)
        )
    }

    private func grid(in plot: CGRect) -> some View {
        Path { path in
            for index in 0...4 {
                let progress = CGFloat(index) / 4
                let x = plot.minX + plot.width * progress
                let y = plot.minY + plot.height * progress
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
    }

    private func curvePath(in plot: CGRect) -> Path {
        Path { path in
            if case .hold = displayedInterpolation {
                path.move(to: point(x: 0, y: 0, in: plot))
                path.addLine(to: point(x: 1, y: 0, in: plot))
                path.addLine(to: point(x: 1, y: 1, in: plot))
                return
            }
            for index in 0...120 {
                let x = Double(index) / 120
                let sample = point(
                    x: x,
                    y: displayedInterpolation.progress(at: x),
                    in: plot
                )
                if index == 0 { path.move(to: sample) } else { path.addLine(to: sample) }
            }
        }
    }

    private func handleLayer(plot: CGRect) -> some View {
        let controlPoints = editableControlPoints
        let first = controlPointPosition(controlPoints.0, in: plot)
        let second = controlPointPosition(controlPoints.1, in: plot)
        return ZStack {
            Path { path in
                path.move(to: point(x: 0, y: 0, in: plot))
                path.addLine(to: first)
                path.move(to: point(x: 1, y: 1, in: plot))
                path.addLine(to: second)
            }
            .stroke(Color.white.opacity(0.62), lineWidth: 1)

            graphHandle(at: first, isSelected: dragMode == .firstHandle)
            graphHandle(at: second, isSelected: dragMode == .secondHandle)
        }
        .zIndex(20)
    }

    private func graphHandle(at position: CGPoint, isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? MotionaryTheme.accent : Color.white)
            .overlay(Circle().stroke(MotionaryTheme.accent, lineWidth: 2))
            .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
            .position(position)
            .animation(.spring(duration: 0.18), value: isSelected)
    }

    private func playhead(in plot: CGRect) -> some View {
        let duration = max(range.upperBound - range.lowerBound, 0.000_001)
        let localTime = viewModel.currentTime - item.timelineStart
        let progress = min(max((localTime - range.lowerBound) / duration, 0), 1)
        return Rectangle()
            .fill(Color.white.opacity(0.72))
            .frame(width: 1.5, height: plot.height)
            .position(x: plot.minX + plot.width * CGFloat(progress), y: plot.midY)
            .allowsHitTesting(false)
    }

    private func graphDragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("TextMotionGraph"))
            .onChanged { gesture in
                if dragMode == nil {
                    beginGraphDrag(at: gesture.startLocation, plot: plot)
                }
                switch dragMode {
                case .firstHandle:
                    updateHandle(isFirst: true, location: gesture.location, plot: plot)
                case .secondHandle:
                    updateHandle(isFirst: false, location: gesture.location, plot: plot)
                case .scrub:
                    viewModel.updateScrub(to: timelineTime(at: gesture.location.x, plot: plot))
                case nil:
                    break
                }
            }
            .onEnded { gesture in
                switch dragMode {
                case .firstHandle, .secondHandle:
                    onEditingEnded()
                case .scrub:
                    viewModel.endScrub(at: timelineTime(at: gesture.location.x, plot: plot))
                case nil:
                    break
                }
                dragMode = nil
                workingControl1 = nil
                workingControl2 = nil
                snappedHandleAxes = []
            }
    }

    private func beginGraphDrag(at location: CGPoint, plot: CGRect) {
        let controlPoints = editableControlPoints
        let firstDistance = distance(from: location, to: controlPointPosition(controlPoints.0, in: plot))
        let secondDistance = distance(from: location, to: controlPointPosition(controlPoints.1, in: plot))
        if min(firstDistance, secondDistance) <= 32 {
            dragMode = firstDistance <= secondDistance ? .firstHandle : .secondHandle
            workingControl1 = controlPoints.0
            workingControl2 = controlPoints.1
            viewModel.beginInteractiveEdit()
        } else {
            dragMode = .scrub
            viewModel.beginScrub()
        }
    }

    private func updateHandle(isFirst: Bool, location: CGPoint, plot: CGRect) {
        guard var control1 = workingControl1, var control2 = workingControl2 else { return }
        let rawX = Double((location.x - plot.minX) / max(plot.width, 1))
        let rawY = Double((plot.maxY - location.y) / max(plot.height, 1))
        let snappedX = GraphHandleSnapper.edgeValue(rawX, axisLength: plot.width)
        let snappedY = GraphHandleSnapper.edgeValue(rawY, axisLength: plot.height)
        let snapAxes = GraphHandleSnapAxes(
            horizontal: snappedX.didSnap,
            vertical: snappedY.didSnap
        )
        if !snapAxes.subtracting(snappedHandleAxes).isEmpty {
            EditorHaptics.selection()
        }
        snappedHandleAxes = snapAxes
        let moved = KeyframeControlPoint(
            x: snappedX.didSnap ? snappedX.value : min(max(rawX, 0), 1),
            y: snappedY.didSnap ? snappedY.value : min(max(rawY, -0.3), 1.3)
        )
        if isFirst { control1 = moved } else { control2 = moved }
        workingControl1 = control1
        workingControl2 = control2
        onInterpolationChanged(.cubicBezier(control1: control1, control2: control2))
    }

    private func timelineTime(at x: CGFloat, plot: CGRect) -> Double {
        let progress = min(max(Double((x - plot.minX) / max(plot.width, 1)), 0), 1)
        let localTime = range.lowerBound + (range.upperBound - range.lowerBound) * progress
        return item.timelineStart + localTime
    }

    private func controlPointPosition(
        _ controlPoint: KeyframeControlPoint,
        in plot: CGRect
    ) -> CGPoint {
        point(x: controlPoint.x, y: controlPoint.y, in: plot)
    }

    private func point(x: Double, y: Double, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + plot.width * CGFloat(x),
            y: plot.maxY - plot.height * CGFloat(y)
        )
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private enum TextMotionGraphDragMode {
    case firstHandle
    case secondHandle
    case scrub
}

private struct MotionRangeStrip: View {
    let animations: TextAnimationSet
    let duration: Double

    var body: some View {
        VStack(spacing: 7) {
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
                    Capsule().fill(Color.white.opacity(0.07))
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
        .padding(11)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
