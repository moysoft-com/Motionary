// Shared easing graph rendering and interaction for editor workspaces.

import SwiftUI

enum EditorEasingGraphOvershoot {
    case rubberBanded
    case clamped(ClosedRange<Double>)
}

struct GraphHandleSnapAxes: OptionSet {
    let rawValue: Int

    static let horizontal = GraphHandleSnapAxes(rawValue: 1 << 0)
    static let vertical = GraphHandleSnapAxes(rawValue: 1 << 1)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(horizontal: Bool, vertical: Bool) {
        var axes: GraphHandleSnapAxes = []
        if horizontal { axes.insert(.horizontal) }
        if vertical { axes.insert(.vertical) }
        self = axes
    }
}

enum GraphHandleSnapper {
    static let threshold: CGFloat = 12

    static func edgeValue(
        _ value: Double,
        axisLength: CGFloat
    ) -> (value: Double, didSnap: Bool) {
        let normalizedThreshold = Double(threshold / max(axisLength, 1))
        if abs(value) <= normalizedThreshold { return (0, true) }
        if abs(value - 1) <= normalizedThreshold { return (1, true) }
        return (value, false)
    }
}

struct EditorEasingGraph: View {
    @ObservedObject private var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let timelineStart: Double
    let range: ClosedRange<Double>
    let interpolation: KeyframeInterpolation
    let horizontalInset: CGFloat
    let exposesDefaultHandles: Bool
    let overshoot: EditorEasingGraphOvershoot
    let onHandleBegan: () -> Void
    let onInterpolationChanged: (KeyframeInterpolation) -> Void
    let onHandleEnded: () -> Void

    @State private var dragMode: DragMode?
    @State private var workingControl1: KeyframeControlPoint?
    @State private var workingControl2: KeyframeControlPoint?
    @State private var snappedHandleAxes: GraphHandleSnapAxes = []

    init(
        viewModel: EditorViewModel,
        timelineStart: Double,
        range: ClosedRange<Double>,
        interpolation: KeyframeInterpolation,
        horizontalInset: CGFloat,
        exposesDefaultHandles: Bool,
        overshoot: EditorEasingGraphOvershoot,
        onHandleBegan: @escaping () -> Void,
        onInterpolationChanged: @escaping (KeyframeInterpolation) -> Void,
        onHandleEnded: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.timelineStart = timelineStart
        self.range = range
        self.interpolation = interpolation
        self.horizontalInset = horizontalInset
        self.exposesDefaultHandles = exposesDefaultHandles
        self.overshoot = overshoot
        self.onHandleBegan = onHandleBegan
        self.onInterpolationChanged = onInterpolationChanged
        self.onHandleEnded = onHandleEnded
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: horizontalInset,
                y: 34,
                width: max(geometry.size.width - horizontalInset * 2, 1),
                height: max(geometry.size.height - 68, 1)
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MotionaryTheme.surfaceSubtle)
                grid(in: plot)
                curvePath(in: plot)
                    .stroke(
                        MotionaryTheme.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                graphEndpoint(x: 0, y: 0, in: plot)
                graphEndpoint(x: 1, y: 1, in: plot)
                playhead(in: plot)
                if let controlPoints = editableControlPoints {
                    handleLayer(controlPoints: controlPoints, plot: plot)
                }
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "EditorEasingGraph")
            .highPriorityGesture(graphDragGesture(plot: plot))
        }
    }

    private var displayedInterpolation: KeyframeInterpolation {
        guard let workingControl1, let workingControl2 else { return interpolation }
        return .cubicBezier(control1: workingControl1, control2: workingControl2)
    }

    private var editableControlPoints: (KeyframeControlPoint, KeyframeControlPoint)? {
        if let workingControl1, let workingControl2 {
            return (workingControl1, workingControl2)
        }
        if case .cubicBezier(let control1, let control2) = interpolation {
            return (control1, control2)
        }
        guard exposesDefaultHandles else { return nil }
        return (
            KeyframeControlPoint(x: 0.33, y: 0.33),
            KeyframeControlPoint(x: 0.67, y: 0.67)
        )
    }

    private func graphEndpoint(x: Double, y: Double, in plot: CGRect) -> some View {
        Circle()
            .fill(MotionaryTheme.control)
            .frame(width: 10, height: 10)
            .position(point(x: x, y: y, in: plot))
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
        .stroke(MotionaryTheme.separator, lineWidth: 0.8)
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
                let sample = point(x: x, y: displayedInterpolation.progress(at: x), in: plot)
                if index == 0 { path.move(to: sample) } else { path.addLine(to: sample) }
            }
        }
    }

    private func playhead(in plot: CGRect) -> some View {
        let duration = max(range.upperBound - range.lowerBound, 0.000_001)
        let localTime = viewModel.currentTime - timelineStart
        let progress = min(max((localTime - range.lowerBound) / duration, 0), 1)
        return Rectangle()
            .fill(MotionaryTheme.control.opacity(0.72))
            .frame(width: 1.5, height: plot.height)
            .position(x: plot.minX + plot.width * CGFloat(progress), y: plot.midY)
            .allowsHitTesting(false)
    }

    private func handleLayer(
        controlPoints: (KeyframeControlPoint, KeyframeControlPoint),
        plot: CGRect
    ) -> some View {
        let first = controlPointPosition(controlPoints.0, in: plot)
        let second = controlPointPosition(controlPoints.1, in: plot)
        return ZStack {
            Path { path in
                path.move(to: point(x: 0, y: 0, in: plot))
                path.addLine(to: first)
                path.move(to: point(x: 1, y: 1, in: plot))
                path.addLine(to: second)
            }
            .stroke(MotionaryTheme.control.opacity(0.62), lineWidth: 1)
            graphHandle(at: first, isSelected: dragMode == .firstHandle)
            graphHandle(at: second, isSelected: dragMode == .secondHandle)
        }
        .zIndex(20)
    }

    private func graphHandle(at position: CGPoint, isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? MotionaryTheme.accent : MotionaryTheme.control)
            .overlay(Circle().stroke(MotionaryTheme.accent, lineWidth: 2))
            .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
            .position(position)
            .animation(.spring(duration: 0.18), value: isSelected)
    }

    private func graphDragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("EditorEasingGraph"))
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
                    onHandleEnded()
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
        if let controlPoints = editableControlPoints {
            let firstDistance = distance(from: location, to: controlPointPosition(controlPoints.0, in: plot))
            let secondDistance = distance(from: location, to: controlPointPosition(controlPoints.1, in: plot))
            if min(firstDistance, secondDistance) <= 32 {
                dragMode = firstDistance <= secondDistance ? .firstHandle : .secondHandle
                workingControl1 = controlPoints.0
                workingControl2 = controlPoints.1
                onHandleBegan()
                return
            }
        }
        dragMode = .scrub
        viewModel.beginScrub()
    }

    private func updateHandle(isFirst: Bool, location: CGPoint, plot: CGRect) {
        guard var control1 = workingControl1, var control2 = workingControl2 else { return }
        let rawX = Double((location.x - plot.minX) / max(plot.width, 1))
        let rawY = Double((plot.maxY - location.y) / max(plot.height, 1))
        let snappedX = GraphHandleSnapper.edgeValue(rawX, axisLength: plot.width)
        let snappedY = GraphHandleSnapper.edgeValue(rawY, axisLength: plot.height)
        let snapAxes = GraphHandleSnapAxes(horizontal: snappedX.didSnap, vertical: snappedY.didSnap)
        if !snapAxes.subtracting(snappedHandleAxes).isEmpty {
            EditorHaptics.selection()
        }
        snappedHandleAxes = snapAxes
        let moved = KeyframeControlPoint(
            x: snappedX.didSnap ? snappedX.value : min(max(rawX, 0), 1),
            y: snappedY.didSnap ? snappedY.value : adjustedY(rawY, in: plot)
        )
        if isFirst { control1 = moved } else { control2 = moved }
        workingControl1 = control1
        workingControl2 = control2
        onInterpolationChanged(.cubicBezier(control1: control1, control2: control2))
    }

    private func timelineTime(at x: CGFloat, plot: CGRect) -> Double {
        let progress = min(max(Double((x - plot.minX) / max(plot.width, 1)), 0), 1)
        return timelineStart + range.lowerBound + (range.upperBound - range.lowerBound) * progress
    }

    private func controlPointPosition(
        _ controlPoint: KeyframeControlPoint,
        in plot: CGRect
    ) -> CGPoint {
        let y: Double
        switch overshoot {
        case .rubberBanded:
            let limit = verticalOvershootLimit(in: plot)
            y = min(max(controlPoint.y, -limit), 1 + limit)
        case .clamped:
            y = controlPoint.y
        }
        return point(x: controlPoint.x, y: y, in: plot)
    }

    private func adjustedY(_ value: Double, in plot: CGRect) -> Double {
        switch overshoot {
        case .rubberBanded:
            let limit = verticalOvershootLimit(in: plot)
            let resistanceLength = max(limit * 0.55, 0.02)
            if value < 0 {
                return -rubberBandDistance(-value, limit: limit, resistanceLength: resistanceLength)
            }
            if value > 1 {
                return 1 + rubberBandDistance(value - 1, limit: limit, resistanceLength: resistanceLength)
            }
            return value
        case .clamped(let range):
            return min(max(value, range.lowerBound), range.upperBound)
        }
    }

    private func verticalOvershootLimit(in plot: CGRect) -> Double {
        Double(max(plot.minY - 11, 8) / max(plot.height, 1))
    }

    private func rubberBandDistance(
        _ distance: Double,
        limit: Double,
        resistanceLength: Double
    ) -> Double {
        limit * (1 - exp(-distance / resistanceLength))
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

    private enum DragMode {
        case firstHandle
        case secondHandle
        case scrub
    }
}
