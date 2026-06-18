// Preview clip geometry, selection, snapping, and direct manipulation.

import SwiftUI

struct PreviewClipInfo: Identifiable {
    let trackID: UUID
    let clip: TimelineClip

    var id: UUID { clip.id }
}

struct PreviewClipFrame {
    let rect: CGRect
    let rotationDegrees: Double
}

struct PreviewTransformCanvas: View {
    @ObservedObject var viewModel: EditorViewModel
    let canvasRect: CGRect

    @State private var dragStartTransform: ClipTransform?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?
    @State private var transformStartFrame: PreviewClipFrame?
    @State private var snapGuideX: CGFloat?
    @State private var snapGuideY: CGFloat?
    @State private var previewSnapKey: String?
    @State private var lastPreviewSnapFeedbackKey: String?
    @State private var lastPreviewSnapFeedbackAt: Date = .distantPast
    @State private var isTransforming = false

    var body: some View {
        ZStack {
            ForEach(activeClipInfos.reversed()) { info in
                if let frame = previewFrame(for: info.clip) {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: frame.rect.width, height: frame.rect.height)
                        .rotationEffect(.degrees(frame.rotationDegrees))
                        .position(x: frame.rect.midX, y: frame.rect.midY)
                        .onTapGesture {
                            EditorHaptics.selection()
                            viewModel.selectClip(info.clip.id, trackID: info.trackID)
                        }
                }
            }

            if isTransforming,
                let clip = selectedVisualClip,
                let frame = previewFrame(for: clip)
            {
                if let transformStartFrame {
                    TransformGhostMask(frame: transformStartFrame)
                        .allowsHitTesting(false)
                }
                LiveTransformClipProxy(
                    clip: clip,
                    frame: frame,
                    currentTime: viewModel.currentTime
                )
                .allowsHitTesting(false)
            }

            if let x = snapGuideX {
                Rectangle()
                    .fill(MotionaryTheme.accent.opacity(0.82))
                    .frame(width: 1, height: canvasRect.height)
                    .position(x: x, y: canvasRect.midY)
                    .allowsHitTesting(false)
            }

            if let y = snapGuideY {
                Rectangle()
                    .fill(MotionaryTheme.accent.opacity(0.82))
                    .frame(width: canvasRect.width, height: 1)
                    .position(x: canvasRect.midX, y: y)
                    .allowsHitTesting(false)
            }

            if let clip = selectedVisualClip,
                let frame = previewFrame(for: clip)
            {
                PreviewSelectionBox(frame: frame)
                    .gesture(dragGesture(for: clip, frame: frame))
                    .simultaneousGesture(scaleGesture(for: clip))
                    .simultaneousGesture(rotationGesture(for: clip))
                    .id(clip.id)
            }
        }
        .frame(width: canvasRect.width, height: canvasRect.height)
        .position(x: canvasRect.midX, y: canvasRect.midY)
        .onChange(of: viewModel.selectedClipID) { _, _ in
            resetPreviewInteraction(finishEdit: isTransforming)
        }
        .onDisappear {
            resetPreviewInteraction(finishEdit: isTransforming)
        }
    }

    private var selectedVisualClip: TimelineClip? {
        guard let clip = viewModel.selectedClip, clip.mediaType != .audio else { return nil }
        return clip
    }

    private var activeClipInfos: [PreviewClipInfo] {
        viewModel.project.tracks.flatMap { track in
            track.clips.compactMap { clip in
                guard clip.mediaType != .audio else { return nil }
                guard isClipVisible(clip) || clip.id == viewModel.selectedClipID else { return nil }
                return PreviewClipInfo(trackID: track.id, clip: clip)
            }
        }
    }

    private func dragGesture(for clip: TimelineClip, frame: PreviewClipFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform = clip.transform.resolved(at: localTime(for: clip))
                    transformStartFrame = frame
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let start = dragStartTransform else { return }

                let proposedX =
                    start.positionX.baseValue + Double(value.translation.width / max(canvasRect.width * 0.5, 1))
                let proposedY =
                    start.positionY.baseValue - Double(value.translation.height / max(canvasRect.height * 0.5, 1))
                let snapped = snappedPosition(
                    positionX: proposedX,
                    positionY: proposedY,
                    frame: frame,
                    selectedClipID: clip.id
                )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "position",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                viewModel.setSelectedTransform(
                    positionX: snapped.positionX,
                    positionY: snapped.positionY,
                    interactive: true
                )
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func scaleGesture(for clip: TimelineClip) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if scaleStart == nil {
                    scaleStart = clip.transform.scale.value(at: localTime(for: clip)).x
                    transformStartFrame = previewFrame(for: clip)
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let scaleStart else { return }
                let snapped = snappedScale(
                    scale: scaleStart * value,
                    clip: clip,
                    selectedClipID: clip.id
                )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "scale",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                viewModel.setSelectedTransform(scale: snapped.scale, interactive: true)
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func rotationGesture(for clip: TimelineClip) -> some Gesture {
        RotationGesture()
            .onChanged { value in
                if rotationStart == nil {
                    rotationStart = clip.transform.rotationDegrees.value(at: localTime(for: clip))
                    transformStartFrame = previewFrame(for: clip)
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let rotationStart else { return }
                let snapped = snappedRotation(rotationStart - value.degrees)
                updatePreviewSnapHaptic(
                    kind: "rotation",
                    snapped: snapped.snapped,
                    value: String(format: "%.0f", snapped.rotation)
                )
                viewModel.setSelectedTransform(rotationDegrees: snapped.rotation, interactive: true)
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func snappedPosition(
        positionX: Double,
        positionY: Double,
        frame: PreviewClipFrame,
        selectedClipID: UUID
    ) -> (positionX: Double, positionY: Double, guideX: CGFloat?, guideY: CGFloat?) {
        let proposedCenter = CGPoint(
            x: canvasRect.midX + CGFloat(positionX) * canvasRect.width * 0.5,
            y: canvasRect.midY - CGFloat(positionY) * canvasRect.height * 0.5
        )
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10

        let snappedX = snapAxis(
            center: proposedCenter.x,
            anchorOffsets: rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees).map(\.x),
            targets: targets.x,
            threshold: threshold
        )
        let snappedY = snapAxis(
            center: proposedCenter.y,
            anchorOffsets: rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees).map(\.y),
            targets: targets.y,
            threshold: threshold
        )

        let normalizedX = Double((snappedX.center - canvasRect.midX) / max(canvasRect.width * 0.5, 1))
        let normalizedY = Double(-(snappedY.center - canvasRect.midY) / max(canvasRect.height * 0.5, 1))
        return (normalizedX, normalizedY, snappedX.guide, snappedY.guide)
    }

    private func snappedScale(
        scale: Double,
        clip: TimelineClip,
        selectedClipID: UUID
    ) -> (scale: Double, guideX: CGFloat?, guideY: CGFloat?) {
        guard let baseSize = previewBaseSize(for: clip) else {
            return (min(max(scale, 0.01), 100), nil, nil)
        }

        let proposedScale = CGFloat(min(max(scale, 0.01), 100))
        let center = previewCenter(for: clip)
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10
        let rotation = -clip.transform.rotationDegrees.value(at: localTime(for: clip))

        let xSnap = snapScaleAxis(
            center: center.x,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.x),
            proposedScale: proposedScale,
            targets: targets.x,
            threshold: threshold
        )
        let ySnap = snapScaleAxis(
            center: center.y,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.y),
            proposedScale: proposedScale,
            targets: targets.y,
            threshold: threshold
        )

        let best = [xSnap, ySnap]
            .compactMap { $0 }
            .min { $0.distance < $1.distance }

        guard let best else {
            return (Double(proposedScale), nil, nil)
        }

        return (
            Double(min(max(best.scale, 0.01), 100)),
            xSnap?.guide == best.guide ? xSnap?.guide : nil,
            ySnap?.guide == best.guide ? ySnap?.guide : nil
        )
    }

    private func snappedRotation(_ degrees: Double) -> (rotation: Double, snapped: Bool) {
        let interval = 15.0
        let threshold = 2.25
        let nearest = (degrees / interval).rounded() * interval
        guard abs(nearest - degrees) <= threshold else {
            return (degrees, false)
        }
        return (nearest, true)
    }

    private func snapTargets(excluding selectedClipID: UUID) -> (x: [CGFloat], y: [CGFloat]) {
        var xTargets = [canvasRect.minX, canvasRect.midX, canvasRect.maxX]
        var yTargets = [canvasRect.minY, canvasRect.midY, canvasRect.maxY]

        for info in activeClipInfos where info.clip.id != selectedClipID {
            guard let frame = previewFrame(for: info.clip) else { continue }
            let anchors = rotatedAnchors(for: frame)
            xTargets.append(contentsOf: anchors.map(\.x))
            yTargets.append(contentsOf: anchors.map(\.y))
        }

        return (xTargets, yTargets)
    }

    private func snapAxis(center: CGFloat, anchorOffsets: [CGFloat], targets: [CGFloat], threshold: CGFloat) -> (
        center: CGFloat, guide: CGFloat?
    ) {
        let ownAnchors = anchorOffsets.map { center + $0 }
        var bestDelta: CGFloat = 0
        var bestGuide: CGFloat?
        var bestDistance = threshold

        for ownAnchor in ownAnchors {
            for target in targets {
                let delta = target - ownAnchor
                let distance = abs(delta)
                if distance < bestDistance {
                    bestDistance = distance
                    bestDelta = delta
                    bestGuide = target
                }
            }
        }

        return (center + bestDelta, bestGuide)
    }

    private func snapScaleAxis(
        center: CGFloat,
        baseOffsets: [CGFloat],
        proposedScale: CGFloat,
        targets: [CGFloat],
        threshold: CGFloat
    ) -> (scale: CGFloat, guide: CGFloat, distance: CGFloat)? {
        let offsets = baseOffsets.filter { abs($0) > 0.001 }
        guard !offsets.isEmpty else { return nil }
        var best: (scale: CGFloat, guide: CGFloat, distance: CGFloat)?

        for offset in offsets {
            let proposedAnchor = center + offset * proposedScale
            for target in targets {
                let desiredScale = (target - center) / offset
                guard desiredScale > 0 else { continue }
                let distance = abs(target - proposedAnchor)
                guard distance < threshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (desiredScale, target, distance)
                }
            }
        }

        return best
    }

    private func rotatedAnchors(for frame: PreviewClipFrame) -> [CGPoint] {
        let offsets = rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees)
        let center = CGPoint(x: frame.rect.midX, y: frame.rect.midY)
        return offsets.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
    }

    private func rotatedAnchorOffsets(size: CGSize, rotationDegrees: Double) -> [CGPoint] {
        let halfWidth = size.width * 0.5
        let halfHeight = size.height * 0.5
        let base = [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: 0, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: 0),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: 0, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: 0),
            .zero
        ]
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        return base.map { point in
            CGPoint(
                x: point.x * cosValue - point.y * sinValue,
                y: point.x * sinValue + point.y * cosValue
            )
        }
    }

    private func previewFrame(for clip: TimelineClip) -> PreviewClipFrame? {
        let sourceSize = clip.source.naturalSize?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        let localTime = localTime(for: clip)
        let scale = clip.transform.scale.value(at: localTime)
        let size = CGSize(
            width: sourceSize.width * fitScale * max(scale.x, 0.01),
            height: sourceSize.height * fitScale * max(scale.y, 0.01)
        )
        let center = previewCenter(for: clip)

        return PreviewClipFrame(
            rect: CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            ),
            rotationDegrees: -clip.transform.rotationDegrees.value(at: localTime)
        )
    }

    private func previewBaseSize(for clip: TimelineClip) -> CGSize? {
        let sourceSize = clip.source.naturalSize?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }
        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        return CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
    }

    private func previewCenter(for clip: TimelineClip) -> CGPoint {
        let localTime = localTime(for: clip)
        return CGPoint(
            x: canvasRect.midX + CGFloat(clip.transform.positionX.value(at: localTime)) * canvasRect.width * 0.5,
            y: canvasRect.midY - CGFloat(clip.transform.positionY.value(at: localTime)) * canvasRect.height * 0.5
        )
    }

    private func localTime(for clip: TimelineClip) -> Double {
        min(max(viewModel.currentTime - clip.timelineStart, 0), clip.sourceRange.duration)
    }

    private func isClipVisible(_ clip: TimelineClip) -> Bool {
        viewModel.currentTime >= clip.timelineStart && viewModel.currentTime < clip.timelineEnd
    }

    private func resetPreviewInteraction(finishEdit: Bool) {
        dragStartTransform = nil
        scaleStart = nil
        rotationStart = nil
        transformStartFrame = nil
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKey = nil
        isTransforming = false
        if finishEdit {
            viewModel.finishInteractiveEdit()
            EditorHaptics.editCommit()
        }
    }

    private func updatePreviewSnapHaptic(kind: String, snapped: Bool, value: String) {
        let key = snapped ? "\(kind)-\(value)" : nil
        let previousKey = previewSnapKey
        previewSnapKey = key
        guard let key, key != previousKey else { return }

        let now = Date()
        if key == lastPreviewSnapFeedbackKey,
            now.timeIntervalSince(lastPreviewSnapFeedbackAt) < 0.35
        {
            return
        }

        lastPreviewSnapFeedbackKey = key
        lastPreviewSnapFeedbackAt = now
        EditorHaptics.snap()
    }
}

struct TransformGhostMask: View {
    let frame: PreviewClipFrame

    var body: some View {
        Rectangle()
            .fill(Color(red: 0.015, green: 0.015, blue: 0.018))
            .frame(width: frame.rect.width + 2, height: frame.rect.height + 2)
            .rotationEffect(.degrees(frame.rotationDegrees))
            .position(x: frame.rect.midX, y: frame.rect.midY)
    }
}

struct LiveTransformClipProxy: View {
    let clip: TimelineClip
    let frame: PreviewClipFrame
    let currentTime: Double

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .clipped()
        .scaleEffect(
            x: clip.transform.isFlippedHorizontally ? -1 : 1,
            y: clip.transform.isFlippedVertically ? -1 : 1
        )
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .opacity(0.9)
        .task(id: taskID) {
            image = await TimelineThumbnailLoader.image(
                for: clip,
                timelineTime: currentTime,
                targetHeight: max(frame.rect.height, 80)
            )
        }
    }

    private var taskID: String {
        [
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration),
            String(format: "%.2f", currentTime),
            "\(Int(frame.rect.height.rounded()))"
        ].joined(separator: "|")
    }
}

struct PreviewSelectionBox: View {
    let frame: PreviewClipFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(MotionaryTheme.accent, lineWidth: 1.5)

            ForEach(SelectionHandlePosition.allCases) { position in
                Circle()
                    .fill(MotionaryTheme.accent)
                    .frame(width: 9, height: 9)
                    .position(position.point(in: frame.rect.size))
            }
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .contentShape(Rectangle())
    }
}

enum SelectionHandlePosition: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: 0, y: 0)
        case .topRight:
            CGPoint(x: size.width, y: 0)
        case .bottomLeft:
            CGPoint(x: 0, y: size.height)
        case .bottomRight:
            CGPoint(x: size.width, y: size.height)
        }
    }
}
