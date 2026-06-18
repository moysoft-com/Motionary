// Segment-only easing editor. Keyframe times and values remain fixed.

import SwiftUI

struct KeyframeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))

            if let context = graphContext {
                VStack(spacing: 10) {
                    HStack {
                        Label(
                            context.clip.keyframeMetadata(for: context.segment.target).title,
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(
                            "\(formatClock(context.segment.startTime)) – \(formatClock(context.segment.endTime))"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MotionaryTheme.textSecondary)
                    }

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
                                        target: context.segment.target,
                                        keyframeID: context.segment.leftKeyframeID
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
                .padding(13)
            } else {
                Label("No active keyframe segment", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }
        }
        .motionaryGlass(cornerRadius: 20)
    }

    private var graphContext: (clip: TimelineClip, segment: KeyframeSegment)? {
        guard let segment = viewModel.graphSegment,
            let clip = viewModel.project.clip(id: segment.clipID)
        else { return nil }
        return (clip, segment)
    }
}

private struct NormalizedEasingGraph: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip
    let segment: KeyframeSegment

    @State private var isBackgroundScrubbing = false

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
            .gesture(backgroundScrubGesture(plot: plot))
        }
        .frame(minHeight: 180)
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
                isFirst: true,
                current: control1,
                other: control2,
                plot: plot
            )
            graphHandle(
                at: second,
                isFirst: false,
                current: control2,
                other: control1,
                plot: plot
            )
        }
        .zIndex(20)
    }

    private func graphHandle(
        at position: CGPoint,
        isFirst: Bool,
        current: KeyframeControlPoint,
        other: KeyframeControlPoint,
        plot: CGRect
    ) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(MotionaryTheme.accent, lineWidth: 2))
            .frame(width: 15, height: 15)
            .position(position)
            .contentShape(Rectangle().inset(by: -14))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("NormalizedGraph"))
                    .onChanged { gesture in
                        let rawX = Double((gesture.location.x - plot.minX) / max(plot.width, 1))
                        let rawY = Double((plot.maxY - gesture.location.y) / max(plot.height, 1))
                        let x: Double
                        if isFirst {
                            x = min(max(rawX, 0), other.x)
                        } else {
                            x = min(max(rawX, other.x), 1)
                        }
                        let moved = KeyframeControlPoint(x: x, y: rawY)
                        viewModel.setInterpolation(
                            .cubicBezier(
                                control1: isFirst ? moved : other,
                                control2: isFirst ? other : moved
                            ),
                            target: segment.target,
                            keyframeID: segment.leftKeyframeID,
                            interactive: true
                        )
                    }
                    .onEnded { _ in
                        viewModel.finishInteractiveEdit()
                    }
            )
    }

    private func backgroundScrubGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("NormalizedGraph"))
            .onChanged { gesture in
                if !isBackgroundScrubbing {
                    isBackgroundScrubbing = true
                    viewModel.beginScrub()
                }
                let progress = min(
                    max(Double((gesture.location.x - plot.minX) / max(plot.width, 1)), 0),
                    1
                )
                let localTime =
                    segment.startTime
                    + (segment.endTime - segment.startTime) * progress
                viewModel.updateScrub(to: clip.timelineStart + localTime)
            }
            .onEnded { gesture in
                let progress = min(
                    max(Double((gesture.location.x - plot.minX) / max(plot.width, 1)), 0),
                    1
                )
                let localTime =
                    segment.startTime
                    + (segment.endTime - segment.startTime) * progress
                isBackgroundScrubbing = false
                viewModel.endScrub(at: clip.timelineStart + localTime)
            }
    }

    private func point(x: Double, y: Double, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + plot.width * CGFloat(x),
            y: plot.maxY - plot.height * CGFloat(y)
        )
    }
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
