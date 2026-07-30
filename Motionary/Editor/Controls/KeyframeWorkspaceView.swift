// Segment-only easing editor. Keyframe times and values remain fixed.

import SwiftUI

struct KeyframeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
    }

    var body: some View {
        Group {
            if let context = graphContext {
                EditorWorkspaceShell(
                    title: context.segment.section.rawValue,
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    isEnabled: context.isActive,
                    contentStyle: .fixed,
                    disablesContentWhenUnavailable: true,
                    accessory: {
                        Text(
                            "\(formatClock(context.segment.startTime)) – \(formatClock(context.segment.endTime))"
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    },
                    content: {
                        EditorEasingGraph(
                            viewModel: viewModel,
                            timelineStart: context.timelineStart,
                            range: context.segment.startTime...context.segment.endTime,
                            interpolation: context.segment.interpolation,
                            horizontalInset: 22,
                            exposesDefaultHandles: false,
                            overshoot: .rubberBanded,
                            onHandleBegan: {},
                            onInterpolationChanged: { interpolation in
                                viewModel.setInterpolation(
                                    interpolation,
                                    section: context.segment.section,
                                    startTime: context.segment.startTime,
                                    interactive: true
                                )
                            },
                            onHandleEnded: { viewModel.finishInteractiveEdit() }
                        )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(KeyframeCurvePreset.allCases) { preset in
                                    EditorWorkspacePillButton(
                                        title: preset.title,
                                        isSelected: context.segment.interpolation == preset.interpolation
                                    ) {
                                        viewModel.setInterpolation(
                                            preset.interpolation,
                                            section: context.segment.section,
                                            startTime: context.segment.startTime
                                        )
                                    }
                                    .frame(width: 76)
                                }
                            }
                        }
                    }
                )
            } else {
                Color.clear
                    .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
            }
        }
    }

    private var graphContext:
        (
            item: TimelineItem,
            timelineStart: Double,
            segment: KeyframeSegment,
            isActive: Bool
        )?
    {
        guard let segment = viewModel.graphSegment ?? viewModel.displayedGraphSegment,
            let item = viewModel.project.item(id: segment.clipID)
        else { return nil }
        return (item, item.timelineStart, segment, viewModel.graphSegment != nil)
    }
}

private struct SpeedKeyframeGraph: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let item: MediaTimelineItem

    @State private var dragMode: SpeedGraphDragMode?
    @State private var selectedSourceTime: Double?
    @State private var lastHapticBucket: Int?

    init(viewModel: EditorViewModel, item: MediaTimelineItem) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.item = item
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 34,
                y: 20,
                width: max(geometry.size.width - 52, 1),
                height: max(geometry.size.height - 40, 1)
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: MotionaryDesign.Radius.graph, style: .continuous)
                .fill(MotionaryTheme.surfaceSubtle)

                speedGrid(in: plot)

                speedPath(in: plot)
                    .stroke(
                        MotionaryTheme.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )

                ForEach(item.speedMap.keyframes, id: \.time) { keyframe in
                    let isSelected =
                        selectedSourceTime.map {
                            abs($0 - keyframe.time) <= 0.000_001
                        } ?? false
                    KeyframeDiamondShape()
                        .fill(isSelected ? MotionaryTheme.accent : MotionaryTheme.control)
                        .overlay {
                            KeyframeDiamondShape()
                                .stroke(MotionaryTheme.accent, lineWidth: 2)
                        }
                        .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
                        .position(position(for: keyframe, in: plot))
                        .animation(.spring(duration: 0.18), value: isSelected)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            keyframe.time <= 0.000_001
                                ? "Initial speed anchor"
                                : "Speed keyframe"
                        )
                        .accessibilityValue(keyframeAccessibilityValue(keyframe))
                }

                playhead(in: plot)

                if let selectedKeyframe {
                    selectedKeyframeReadout(selectedKeyframe)
                }

                Text("8×")
                    .position(x: 16, y: plot.minY + 2)
                Text("1×")
                    .position(x: 16, y: yPosition(for: 1, in: plot))
                Text("0.1×")
                    .position(x: 18, y: plot.maxY - 2)
                Text("0:00")
                    .position(x: plot.minX + 16, y: geometry.size.height - 8)
                Text(formatClock(item.timelineDuration))
                    .position(x: plot.maxX - 20, y: geometry.size.height - 8)
            }
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(MotionaryTheme.textSecondary)
            .contentShape(Rectangle())
            .coordinateSpace(name: "SpeedGraph")
            .highPriorityGesture(graphGesture(plot: plot))
        }
        .onChange(of: item.speedMap.keyframes.map(\.time)) { _, times in
            guard let selectedSourceTime,
                times.contains(where: { abs($0 - selectedSourceTime) <= 0.000_001 })
            else {
                self.selectedSourceTime = nil
                return
            }
        }
        .onChange(of: item.id) { _, _ in
            finishActiveGesture()
            selectedSourceTime = nil
        }
        .onDisappear {
            finishActiveGesture()
        }
    }

    private var selectedKeyframe: SpeedKeyframe? {
        guard let selectedSourceTime else { return nil }
        return item.speedMap.keyframes.first {
            abs($0.time - selectedSourceTime) <= 0.000_001
        }
    }

    private func speedGrid(in plot: CGRect) -> some View {
        Path { path in
            for index in 0...4 {
                let progress = CGFloat(index) / 4
                let x = plot.minX + plot.width * progress
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            for speed in [0.1, 0.25, 0.5, 1, 2, 4, 8] {
                let y = yPosition(for: speed, in: plot)
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(MotionaryTheme.separator, lineWidth: 0.8)
    }

    private func speedPath(in plot: CGRect) -> Path {
        Path { path in
            guard let first = item.speedMap.keyframes.first else { return }
            var previous = position(for: first, in: plot)
            path.move(to: previous)
            for keyframe in item.speedMap.keyframes.dropFirst() {
                let next = position(for: keyframe, in: plot)
                path.addLine(to: CGPoint(x: next.x, y: previous.y))
                path.addLine(to: next)
                previous = next
            }
            path.addLine(to: CGPoint(x: plot.maxX, y: previous.y))
        }
    }

    private func playhead(in plot: CGRect) -> some View {
        let localTime = min(
            max(viewModel.currentTime - item.timelineStart, 0),
            item.timelineDuration
        )
        let progress = localTime / max(item.timelineDuration, 0.000_001)
        return Rectangle()
            .fill(MotionaryTheme.control.opacity(0.72))
            .frame(width: 1.5, height: plot.height)
            .position(x: plot.minX + plot.width * CGFloat(progress), y: plot.midY)
            .allowsHitTesting(false)
    }

    private func graphGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("SpeedGraph"))
            .onChanged { gesture in
                if dragMode == nil {
                    beginDrag(at: gesture.startLocation, plot: plot)
                }
                switch dragMode {
                case .keyframe(let sourceTime, let initialSpeed):
                    if abs(gesture.translation.height) >= 0.5 {
                        updateKeyframe(
                            sourceTime: sourceTime,
                            initialSpeed: initialSpeed,
                            verticalTranslation: gesture.translation.height,
                            plot: plot
                        )
                    }
                case .scrub:
                    updateScrub(x: gesture.location.x, plot: plot)
                case nil:
                    break
                }
            }
            .onEnded { gesture in
                finishActiveGesture(
                    scrubEndTime: timelineTime(at: gesture.location.x, plot: plot)
                )
            }
    }

    private func beginDrag(at location: CGPoint, plot: CGRect) {
        let closest = item.speedMap.keyframes
            .map { ($0, distance(from: location, to: position(for: $0, in: plot))) }
            .min { $0.1 < $1.1 }
        if let closest, closest.1 <= 32 {
            selectedSourceTime = closest.0.time
            dragMode = .keyframe(
                sourceTime: closest.0.time,
                initialSpeed: closest.0.speed
            )
            let localTime = item.speedMap.timelineTime(
                at: closest.0.time,
                sourceDuration: item.sourceRange.duration
            )
            viewModel.beginInteractiveSpeedEdit()
            viewModel.seek(to: item.timelineStart + localTime)
            EditorHaptics.scrubStart()
        } else {
            selectedSourceTime = nil
            dragMode = .scrub
            viewModel.beginScrub()
        }
    }

    private func updateKeyframe(
        sourceTime: Double,
        initialSpeed: Double,
        verticalTranslation: CGFloat,
        plot: CGRect
    ) {
        let speed = translatedSpeed(
            initialSpeed,
            verticalTranslation: verticalTranslation,
            plot: plot
        )
        guard
            viewModel.setSelectedSpeedKeyframe(
                atSourceTime: sourceTime,
                speed: speed,
                interactive: true
            )
        else { return }
        let bucket = Int((speed / 0.05).rounded())
        if let lastHapticBucket, bucket != lastHapticBucket {
            EditorHaptics.selection()
        }
        lastHapticBucket = bucket
    }

    private func updateScrub(x: CGFloat, plot: CGRect) {
        viewModel.updateScrub(to: timelineTime(at: x, plot: plot))
    }

    private func timelineTime(at x: CGFloat, plot: CGRect) -> Double {
        let progress = min(max(Double((x - plot.minX) / max(plot.width, 1)), 0), 1)
        return item.timelineStart + item.timelineDuration * progress
    }

    private func position(for keyframe: SpeedKeyframe, in plot: CGRect) -> CGPoint {
        let localTime = item.speedMap.timelineTime(
            at: keyframe.time,
            sourceDuration: item.sourceRange.duration
        )
        let progress = localTime / max(item.timelineDuration, 0.000_001)
        return CGPoint(
            x: plot.minX + plot.width * CGFloat(progress),
            y: yPosition(for: keyframe.speed, in: plot)
        )
    }

    private func yPosition(for speed: Double, in plot: CGRect) -> CGFloat {
        let normalized = log(min(max(speed, 0.1), 8) / 0.1) / log(80)
        return plot.maxY - plot.height * CGFloat(normalized)
    }

    private func speed(at y: CGFloat, in plot: CGRect) -> Double {
        let normalized = min(max(Double((plot.maxY - y) / max(plot.height, 1)), 0), 1)
        let raw = 0.1 * pow(80, normalized)
        return min(max((raw / 0.05).rounded() * 0.05, 0.1), 8)
    }

    private func translatedSpeed(
        _ initialSpeed: Double,
        verticalTranslation: CGFloat,
        plot: CGRect
    ) -> Double {
        let initialY = yPosition(for: initialSpeed, in: plot)
        return speed(at: initialY + verticalTranslation, in: plot)
    }

    private func selectedKeyframeReadout(_ keyframe: SpeedKeyframe) -> some View {
        let localTime = item.speedMap.timelineTime(
            at: keyframe.time,
            sourceDuration: item.sourceRange.duration
        )
        return Text(
            "\(keyframe.speed.formatted(.number.precision(.fractionLength(2))))×  ·  \(formatClock(localTime))"
        )
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(MotionaryTheme.textPrimary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(MotionaryTheme.surfaceStrong, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 7)
        .padding(.trailing, 8)
        .allowsHitTesting(false)
    }

    private func keyframeAccessibilityValue(_ keyframe: SpeedKeyframe) -> String {
        let localTime = item.speedMap.timelineTime(
            at: keyframe.time,
            sourceDuration: item.sourceRange.duration
        )
        return "\(keyframe.speed.formatted(.number.precision(.fractionLength(2)))) times at \(formatClock(localTime))"
    }

    private func finishActiveGesture(scrubEndTime: Double? = nil) {
        switch dragMode {
        case .keyframe:
            viewModel.finishInteractiveEdit()
        case .scrub:
            viewModel.endScrub(at: scrubEndTime ?? viewModel.currentTime)
        case nil:
            break
        }
        dragMode = nil
        lastHapticBucket = nil
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private enum SpeedGraphDragMode: Equatable {
    case keyframe(sourceTime: Double, initialSpeed: Double)
    case scrub
}

struct KeyframeDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}
