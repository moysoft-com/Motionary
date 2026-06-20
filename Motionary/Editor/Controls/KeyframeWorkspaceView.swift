// Segment-only easing editor. Keyframe times and values remain fixed.

import SwiftUI

struct KeyframeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        ZStack {

            if let context = graphContext {
                VStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Label(
                            context.segment.section.rawValue,
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        )
                        .font(.headline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        Spacer()
                        Text(
                            "\(formatClock(context.segment.startTime)) – \(formatClock(context.segment.endTime))"
                        )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    }
                    .frame(height: 22)

                    NormalizedEasingGraph(
                        viewModel: viewModel,
                        clip: context.clip,
                        segment: context.segment
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(KeyframeCurvePreset.allCases) { preset in
                                Button {
                                    viewModel.setInterpolation(
                                        preset.interpolation,
                                        section: context.segment.section,
                                        startTime: context.segment.startTime
                                    )
                                } label: {
                                    Text(preset.title)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .frame(height: 30)
                                        .background(
                                            context.segment.interpolation == preset.interpolation
                                                ? MotionaryTheme.accent
                                                : Color.white.opacity(0.08),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(
                                            context.segment.interpolation == preset.interpolation
                                                ? Color.black
                                                : MotionaryTheme.textPrimary
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .opacity(context.isActive ? 1 : 0.42)
                .allowsHitTesting(context.isActive)
            }
        }
        .motionaryGlass(cornerRadius: 20)
    }

    private var graphContext: (
        clip: TimelineClip,
        segment: KeyframeSegment,
        isActive: Bool
    )? {
        guard let segment = viewModel.graphSegment ?? viewModel.displayedGraphSegment,
            let clip = viewModel.project.clip(id: segment.clipID)
        else { return nil }
        return (clip, segment, viewModel.graphSegment != nil)
    }
}

private struct NormalizedEasingGraph: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip
    let segment: KeyframeSegment

    @State private var dragMode: GraphDragMode?
    @State private var workingControl1: KeyframeControlPoint?
    @State private var workingControl2: KeyframeControlPoint?

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 22,
                y: 18,
                width: max(geometry.size.width - 44, 1),
                height: max(geometry.size.height - 36, 1)
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

                if case .cubicBezier(let control1, let control2) = segment.interpolation {
                    handleLayer(control1: control1, control2: control2, plot: plot)
                }
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "NormalizedGraph")
            .highPriorityGesture(graphDragGesture(plot: plot))
        }
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
            if case .hold = segment.interpolation {
                path.move(to: point(x: 0, y: 0, in: plot))
                path.addLine(to: point(x: 1, y: 0, in: plot))
                path.addLine(to: point(x: 1, y: 1, in: plot))
                return
            }

            for index in 0...120 {
                let x = Double(index) / 120
                let y = segment.interpolation.progress(at: x)
                let sample = point(x: x, y: y, in: plot)
                if index == 0 {
                    path.move(to: sample)
                } else {
                    path.addLine(to: sample)
                }
            }
        }
    }

    @ViewBuilder
    private func playhead(in plot: CGRect) -> some View {
        let duration = max(segment.endTime - segment.startTime, 0.000_001)
        let localTime = viewModel.currentTime - clip.timelineStart
        let progress = min(max((localTime - segment.startTime) / duration, 0), 1)
        Rectangle()
            .fill(Color.white.opacity(0.72))
            .frame(width: 1.5, height: plot.height)
            .position(x: plot.minX + plot.width * CGFloat(progress), y: plot.midY)
            .allowsHitTesting(false)
    }

    private func handleLayer(
        control1: KeyframeControlPoint,
        control2: KeyframeControlPoint,
        plot: CGRect
    ) -> some View {
        let start = point(x: 0, y: 0, in: plot)
        let end = point(x: 1, y: 1, in: plot)
        let first = point(x: control1.x, y: control1.y, in: plot)
        let second = point(x: control2.x, y: control2.y, in: plot)

        return ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: first)
                path.move(to: end)
                path.addLine(to: second)
            }
            .stroke(Color.white.opacity(0.62), lineWidth: 1)

            graphHandle(
                at: first,
                isSelected: dragMode == .firstHandle
            )
            graphHandle(
                at: second,
                isSelected: dragMode == .secondHandle
            )
        }
        .zIndex(20)
    }

    private func graphHandle(
        at position: CGPoint,
        isSelected: Bool
    ) -> some View {
        Circle()
            .fill(isSelected ? MotionaryTheme.accent : Color.white)
            .overlay(Circle().stroke(MotionaryTheme.accent, lineWidth: 2))
            .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
            .position(position)
            .animation(.spring(duration: 0.18), value: isSelected)
    }

    private func graphDragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("NormalizedGraph"))
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
                    updateBackgroundScrub(location: gesture.location, plot: plot)
                case nil:
                    break
                }
            }
            .onEnded { gesture in
                switch dragMode {
                case .firstHandle, .secondHandle:
                    viewModel.finishInteractiveEdit()
                case .scrub:
                    endBackgroundScrub(location: gesture.location, plot: plot)
                case nil:
                    break
                }
                dragMode = nil
                workingControl1 = nil
                workingControl2 = nil
            }
    }

    private func beginGraphDrag(at location: CGPoint, plot: CGRect) {
        if case .cubicBezier(let control1, let control2) = segment.interpolation {
            let firstDistance = distance(
                from: location,
                to: point(x: control1.x, y: control1.y, in: plot)
            )
            let secondDistance = distance(
                from: location,
                to: point(x: control2.x, y: control2.y, in: plot)
            )
            let hitRadius: CGFloat = 32
            if min(firstDistance, secondDistance) <= hitRadius {
                dragMode = firstDistance <= secondDistance
                    ? .firstHandle
                    : .secondHandle
                workingControl1 = control1
                workingControl2 = control2
                return
            }
        }
        dragMode = .scrub
        viewModel.beginScrub()
    }

    private func updateHandle(
        isFirst: Bool,
        location: CGPoint,
        plot: CGRect
    ) {
        guard let control1 = workingControl1,
            let control2 = workingControl2
        else { return }
        let rawX = Double((location.x - plot.minX) / max(plot.width, 1))
        let rawY = Double((plot.maxY - location.y) / max(plot.height, 1))
        let moved: KeyframeControlPoint
        if isFirst {
            moved = KeyframeControlPoint(
                x: min(max(rawX, 0), control2.x),
                y: rawY
            )
            workingControl1 = moved
        } else {
            moved = KeyframeControlPoint(
                x: min(max(rawX, control1.x), 1),
                y: rawY
            )
            workingControl2 = moved
        }
        viewModel.setInterpolation(
            .cubicBezier(
                control1: isFirst ? moved : control1,
                control2: isFirst ? control2 : moved
            ),
            section: segment.section,
            startTime: segment.startTime,
            interactive: true
        )
    }

    private func updateBackgroundScrub(location: CGPoint, plot: CGRect) {
        let localTime = graphLocalTime(at: location.x, plot: plot)
        viewModel.updateScrub(to: clip.timelineStart + localTime)
    }

    private func endBackgroundScrub(location: CGPoint, plot: CGRect) {
        let localTime = graphLocalTime(at: location.x, plot: plot)
        viewModel.endScrub(at: clip.timelineStart + localTime)
    }

    private func graphLocalTime(at x: CGFloat, plot: CGRect) -> Double {
        let progress = min(
            max(Double((x - plot.minX) / max(plot.width, 1)), 0),
            1
        )
        return segment.startTime
            + (segment.endTime - segment.startTime) * progress
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func point(x: Double, y: Double, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + plot.width * CGFloat(x),
            y: plot.maxY - plot.height * CGFloat(y)
        )
    }
}

private enum GraphDragMode {
    case firstHandle
    case secondHandle
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
