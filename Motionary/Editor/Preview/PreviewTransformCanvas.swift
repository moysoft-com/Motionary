// Preview hit testing, selection, snapping, and direct manipulation.
// Rendered pixels stay exclusively in the AVPlayer-backed compositor surface.

import CoreImage
import SwiftUI
import UIKit

struct PreviewClipInfo: Identifiable {
    let trackID: UUID
    let clip: TimelineClip

    var id: UUID { clip.id }
}

struct PreviewTextInfo: Identifiable {
    let trackID: UUID
    let item: TextTimelineItem

    var id: UUID { item.id }
}

private enum PreviewVisualInfo: Identifiable {
    case clip(PreviewClipInfo)
    case text(PreviewTextInfo)

    var id: UUID {
        switch self {
        case .clip(let info): info.id
        case .text(let info): info.id
        }
    }
}

struct PreviewClipFrame {
    let rect: CGRect
    let rotationDegrees: Double
}

private struct PreviewHitCandidate {
    let order: Int
    let area: CGFloat
    let select: () -> Void
}

private extension PreviewClipFrame {
    func contains(_ point: CGPoint) -> Bool {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = CGFloat(-rotationDegrees * .pi / 180)
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let cosine = cos(radians)
        let sine = sin(radians)
        let unrotated = CGPoint(
            x: translated.x * cosine - translated.y * sine + center.x,
            y: translated.x * sine + translated.y * cosine + center.y
        )
        return rect.contains(unrotated)
    }

    func expandedToMinimumHitSize(_ minimum: CGFloat) -> PreviewClipFrame {
        let width = max(rect.width, minimum)
        let height = max(rect.height, minimum)
        return PreviewClipFrame(
            rect: CGRect(
                x: rect.midX - width * 0.5,
                y: rect.midY - height * 0.5,
                width: width,
                height: height
            ),
            rotationDegrees: rotationDegrees
        )
    }
}

private struct PreviewGeometryMapper {
    let canvasRect: CGRect
    let renderSize: CGSize

    func center(
        positionX: Double,
        positionY: Double,
        displayOffset: CGPoint = .zero
    ) -> CGPoint {
        CGPoint(
            x: canvasRect.midX
                + CGFloat(positionX) * canvasRect.width * 0.5
                + displayOffset.x,
            y: canvasRect.midY
                - CGFloat(positionY) * canvasRect.height * 0.5
                + displayOffset.y
        )
    }

    func normalizedPosition(
        from center: CGPoint,
        displayOffset: CGPoint = .zero
    ) -> (x: Double, y: Double) {
        (
            Double(
                (center.x - displayOffset.x - canvasRect.midX)
                    / max(canvasRect.width * 0.5, 1)
            ),
            Double(
                -(center.y - displayOffset.y - canvasRect.midY)
                    / max(canvasRect.height * 0.5, 1)
            )
        )
    }

    func canvasSize(forRenderSize size: CGSize) -> CGSize? {
        guard renderSize.width > 0, renderSize.height > 0,
            canvasRect.width > 0, canvasRect.height > 0
        else { return nil }
        return CGSize(
            width: size.width * canvasRect.width / renderSize.width,
            height: size.height * canvasRect.height / renderSize.height
        )
    }

    func fittedCanvasSize(forSourceSize sourceSize: CGSize) -> CGSize? {
        guard let fittedRenderSize = VideoSourceGeometry.fittedSize(
            sourceSize: sourceSize,
            inside: renderSize
        ) else { return nil }
        return canvasSize(forRenderSize: fittedRenderSize)
    }

    func scaledSize(_ baseSize: CGSize, by scale: ScaleValue, minimum: CGFloat = 0.01) -> CGSize {
        CGSize(
            width: baseSize.width * max(CGFloat(scale.x), minimum),
            height: baseSize.height * max(CGFloat(scale.y), minimum)
        )
    }

    func canvasVector(forRenderVector vector: CGVector) -> CGPoint? {
        guard let size = canvasSize(forRenderSize: CGSize(width: abs(vector.dx), height: abs(vector.dy))) else {
            return nil
        }
        return CGPoint(
            x: vector.dx < 0 ? -size.width : size.width,
            y: vector.dy < 0 ? size.height : -size.height
        )
    }

    func frame(center: CGPoint, size: CGSize, rotationDegrees: Double) -> PreviewClipFrame {
        PreviewClipFrame(
            rect: CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            ),
            rotationDegrees: rotationDegrees
        )
    }
}

private enum PreviewTransformComponent: Hashable {
    case position
    case scale
    case rotation
}

private enum PreviewTransformGesture: Hashable {
    case drag
    case magnification
    case rotation
    case combinedHandle
}

struct PreviewTransformCanvas: View {
    private static let interactionStartTextureDimension = 1_024
    private static let minimumCombinedHandleScaleFactor = 0.08
    private static let minimumScaleSnap = 0.05
    private static let maximumScaleSnapRatio: CGFloat = 1.35

    @ObservedObject var viewModel: EditorViewModel
    let canvasFrame: CGRect

    @State private var dragStartTransform: ClipTransform?
    @State private var liveTransform: ClipTransform?
    @State private var livePreviewImage: UIImage?
    @State private var liveTextPreviewImage: UIImage?
    @State private var liveBackgroundImage: UIImage?
    @State private var livePreviewAssetKey: String?
    @State private var isLivePreviewSourceHidden = false
    @State private var livePreviewLoadID: UUID?
    @State private var livePreviewCommitRevision: Int?
    @State private var liveProxyRasterKey: String?
    @State private var interactionClipID: UUID?
    @State private var activeTransformGestures: Set<PreviewTransformGesture> = []
    @State private var hasTwoFingerTransformInSession = false
    @State private var editedTransformComponents: Set<PreviewTransformComponent> = []
    @State private var snapGuideX: CGFloat?
    @State private var snapGuideY: CGFloat?
    @State private var previewSnapKeys: [String: String] = [:]
    @State private var lastPreviewSnapFeedbackKey: String?
    @State private var lastPreviewSnapFeedbackAt: Date = .distantPast
    @State private var isTransforming = false
    @State private var textRasterizer = PreviewTextRasterizer()
    @State private var shapeRasterizer = PreviewShapeRasterizer()

    init(viewModel: EditorViewModel, canvasFrame: CGRect) {
        self.viewModel = viewModel
        self.canvasFrame = canvasFrame
    }

    var body: some View {
        ZStack {
            ZStack {
                ForEach(activeVisualInfos.reversed()) { info in
                switch info {
                case .clip(let clipInfo):
                    if let frame = previewFrame(for: clipInfo.clip) {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: frame.rect.width, height: frame.rect.height)
                            .rotationEffect(.degrees(frame.rotationDegrees))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                            .contentShape(Rectangle())
                            .allowsHitTesting(false)
                    }

                case .text(let textInfo):
                    if let frame = previewFrame(for: textInfo.item) {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(
                                width: max(frame.rect.width, 44),
                                height: max(frame.rect.height, 44)
                            )
                            .rotationEffect(.degrees(frame.rotationDegrees))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Text layer \(textInfo.item.name)")
                            .allowsHitTesting(false)
                    }
                }
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

            if isTransforming, isLivePreviewSourceHidden, let liveBackgroundImage {
                Image(uiImage: liveBackgroundImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .clipped()
                    .allowsHitTesting(false)
            }

            if isTransforming,
                isLivePreviewSourceHidden,
                let clip = selectedVisualClip,
                let transform = liveTransform,
                let frame = previewFrame(for: clip, transform: transform)
            {
                LiveTransformClipProxy(
                    clip: clip,
                    frame: frame,
                    transform: transform,
                    image: livePreviewImage,
                    localTime: localTime(for: clip)
                )
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
            }

            if isTransforming,
                isLivePreviewSourceHidden,
                let text = selectedTextItem,
                let transform = liveTransform,
                let image = liveTextPreviewImage,
                let frame = previewFrame(for: text, transform: transform)
            {
                let sample = textAnimationSample(for: text)
                LiveTransformTextProxy(
                    image: image,
                    frame: frame,
                    opacity: transform.opacity.baseValue * sample.opacity,
                    clipReveal: sample.clipReveal,
                    isFlippedHorizontally: transform.isFlippedHorizontally,
                    isFlippedVertically: transform.isFlippedVertically
                )
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
            }

            }
            .frame(width: canvasRect.width, height: canvasRect.height)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "PreviewTransformCanvas")
            .gesture(previewSelectionGesture)
            .position(x: canvasFrame.midX, y: canvasFrame.midY)

            if let clip = selectedVisualClip,
                let frame = previewFrame(
                    for: clip,
                    transform: liveTransform ?? clip.transform
                )
            {
                PreviewSelectionBox(
                    frame: selectionFrame(from: frame),
                    onDelete: viewModel.deleteSelectedClip,
                    onDuplicate: viewModel.duplicateSelectedClip,
                    onTransformChanged: { scaleFactor, rotationDelta in
                        updateCombinedHandle(
                            scaleFactor: scaleFactor,
                            rotationDelta: rotationDelta,
                            for: clip
                        )
                    },
                    onTransformEnded: {
                        finishPreviewGesture(.combinedHandle, itemID: clip.id)
                    }
                )
                    .gesture(dragGesture(for: clip, frame: frame))
                    .simultaneousGesture(scaleGesture(for: clip))
                    .simultaneousGesture(rotationGesture(for: clip))
                    .id(clip.id)
            }

            if let text = selectedTextItem,
                let frame = previewFrame(
                    for: text,
                    transform: liveTransform ?? text.visuals.transform
                )
            {
                PreviewSelectionBox(
                    frame: selectionFrame(from: frame),
                    onDelete: viewModel.deleteSelectedClip,
                    onDuplicate: viewModel.duplicateSelectedClip,
                    onTransformChanged: { scaleFactor, rotationDelta in
                        updateCombinedHandle(
                            scaleFactor: scaleFactor,
                            rotationDelta: rotationDelta,
                            for: text
                        )
                    },
                    onTransformEnded: {
                        finishPreviewGesture(.combinedHandle, itemID: text.id)
                    }
                )
                    .gesture(dragGesture(for: text, frame: frame))
                    .simultaneousGesture(scaleGesture(for: text))
                    .simultaneousGesture(rotationGesture(for: text))
                    .id(text.id)
            }
        }
        .onChange(of: viewModel.selectedClipID) { _, _ in
            resetPreviewInteraction(finishEdit: isTransforming)
        }
        .onChange(of: viewModel.previewContentRevision) { _, revision in
            guard let targetRevision = livePreviewCommitRevision,
                revision >= targetRevision
            else { return }
            viewModel.finishLivePreviewCommitPresentation(for: interactionClipID)
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(380))
                } catch {
                    return
                }
                guard livePreviewCommitRevision == targetRevision,
                    !isTransforming
                else { return }
                clearLivePreview()
            }
        }
        .onDisappear {
            resetPreviewInteraction(finishEdit: isTransforming)
        }
        .task(id: livePreviewPreparationKey) {
            await prepareSelectedLivePreviewAssets()
        }
    }

    private var canvasRect: CGRect {
        CGRect(origin: .zero, size: canvasFrame.size)
    }

    private var geometryMapper: PreviewGeometryMapper {
        PreviewGeometryMapper(
            canvasRect: canvasRect,
            renderSize: viewModel.project.renderSettings.size
        )
    }

    private func selectionFrame(from frame: PreviewClipFrame) -> PreviewClipFrame {
        PreviewClipFrame(
            rect: frame.rect.offsetBy(dx: canvasFrame.minX, dy: canvasFrame.minY),
            rotationDegrees: frame.rotationDegrees
        )
    }

    private var selectedVisualClip: TimelineClip? {
        guard let clip = viewModel.selectedClip, clip.mediaType != .audio else { return nil }
        return clip
    }

    private var selectedTextItem: TextTimelineItem? {
        guard case .text(let item) = viewModel.selectedTimelineItem else { return nil }
        return item
    }

    private var livePreviewPreparationKey: String? {
        guard !isTransforming, livePreviewCommitRevision == nil else { return nil }
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let frameTime = (viewModel.currentTime * frameRate).rounded() / frameRate
        if let clip = selectedVisualClip {
            return livePreviewAssetKey(for: clip.id, frameTime: frameTime)
        }
        if let text = selectedTextItem {
            return livePreviewAssetKey(for: text.id, frameTime: frameTime)
        }
        return nil
    }

    private func livePreviewAssetKey(for itemID: UUID, frameTime: Double? = nil) -> String {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let time = frameTime ?? (viewModel.currentTime * frameRate).rounded() / frameRate
        return "\(itemID.uuidString)|\(viewModel.previewContentRevision)|\(String(format: "%.4f", time))"
    }

    private var activeVisualInfos: [PreviewVisualInfo] {
        viewModel.project.tracks.flatMap { track in
            track.items.compactMap { item in
                switch item {
                case .media, .shape:
                    guard let clip = item.legacyClip(), clip.mediaType != .audio else { return nil }
                    guard isClipVisible(clip) || clip.id == viewModel.selectedTimelineItemID else { return nil }
                    return .clip(PreviewClipInfo(trackID: track.id, clip: clip))

                case .text(let text):
                    guard isTextVisible(text) || text.id == viewModel.selectedTimelineItemID else { return nil }
                    return .text(PreviewTextInfo(trackID: track.id, item: text))

                case .caption, .adjustment, .compound:
                    return nil
                }
            }
        }
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

    private var activeTextInfos: [PreviewTextInfo] {
        viewModel.project.tracks.flatMap { track in
            track.items.compactMap { item in
                guard case .text(let text) = item else { return nil }
                guard isTextVisible(text) || text.id == viewModel.selectedTimelineItemID else { return nil }
                return PreviewTextInfo(trackID: track.id, item: text)
            }
        }
    }

    private var previewSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("PreviewTransformCanvas"))
            .onEnded { value in
                guard abs(value.translation.width) < 6,
                    abs(value.translation.height) < 6,
                    !isTransforming
                else { return }
                selectPreviewItem(at: value.location)
            }
    }

    private func selectPreviewItem(at point: CGPoint) {
        let candidates =
            activeVisualInfos.enumerated()
            .compactMap { index, info -> PreviewHitCandidate? in
                switch info {
                case .clip(let clipInfo):
                    guard let frame = previewFrame(for: clipInfo.clip),
                        frame.contains(point)
                    else { return nil }
                    return PreviewHitCandidate(
                        order: index,
                        area: max(frame.rect.width * frame.rect.height, 1),
                        select: {
                            viewModel.selectClip(clipInfo.clip.id, trackID: clipInfo.trackID)
                        }
                    )

                case .text(let textInfo):
                    guard var frame = previewFrame(for: textInfo.item) else { return nil }
                    frame = frame.expandedToMinimumHitSize(44)
                    guard frame.contains(point) else { return nil }
                    return PreviewHitCandidate(
                        order: index,
                        area: max(frame.rect.width * frame.rect.height, 1),
                        select: {
                            viewModel.selectTimelineItem(
                                textInfo.item.id,
                                trackID: textInfo.trackID
                            )
                        }
                    )
                }
            }

        guard let best = candidates.min(by: { left, right in
            if abs(left.area - right.area) > 0.5 {
                return left.area < right.area
            }
            return left.order < right.order
        }) else { return }

        EditorHaptics.selection()
        best.select()
    }

    private func dragGesture(for clip: TimelineClip, frame: PreviewClipFrame) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard activatePreviewGesture(.drag, for: clip) else { return }
                guard !hasTwoFingerTransformInSession else { return }
                guard let start = dragStartTransform else { return }
                editedTransformComponents.insert(.position)

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
                updateLiveTransform {
                    $0.positionX.baseValue = snapped.positionX
                    $0.positionY.baseValue = snapped.positionY
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.drag, itemID: clip.id)
            }
    }

    private func scaleGesture(for clip: TimelineClip) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.magnification, for: clip) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value - 1) > 0.001 || editedTransformComponents.contains(.scale) else {
                    return
                }
                editedTransformComponents.insert(.scale)
                let snapped =
                    abs(value - 1) <= 0.001
                    ? (scale: start.scale.baseValue.x, guideX: nil, guideY: nil)
                    : snappedScale(
                        scale: start.scale.baseValue.x * value,
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
                updateLiveTransform {
                    $0.scale.baseValue = proportionalScale(
                        x: snapped.scale,
                        from: start.scale.baseValue
                    )
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.magnification, itemID: clip.id)
            }
    }

    private func rotationGesture(for clip: TimelineClip) -> some Gesture {
        RotationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.rotation, for: clip) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value.degrees) > 0.05 || editedTransformComponents.contains(.rotation)
                else { return }
                editedTransformComponents.insert(.rotation)
                let snapped =
                    abs(value.degrees) <= 0.05
                    ? (rotation: start.rotationDegrees.baseValue, snapped: false)
                    : snappedRotation(start.rotationDegrees.baseValue + value.degrees)
                updatePreviewSnapHaptic(
                    kind: "rotation",
                    snapped: snapped.snapped,
                    value: String(format: "%.0f", snapped.rotation)
                )
                updateLiveTransform {
                    $0.rotationDegrees.baseValue = snapped.rotation
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.rotation, itemID: clip.id)
            }
    }

    private func dragGesture(for text: TextTimelineItem, frame: PreviewClipFrame) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard activatePreviewGesture(.drag, for: text) else { return }
                guard !hasTwoFingerTransformInSession else { return }
                guard let start = dragStartTransform else { return }
                editedTransformComponents.insert(.position)

                let proposedX =
                    start.positionX.baseValue
                    + Double(value.translation.width / max(canvasRect.width * 0.5, 1))
                let proposedY =
                    start.positionY.baseValue
                    - Double(value.translation.height / max(canvasRect.height * 0.5, 1))
                let snapped = snappedPosition(
                    positionX: proposedX,
                    positionY: proposedY,
                    frame: frame,
                    selectedClipID: text.id,
                    displayOffset: textAnimationOffset(for: text)
                )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "position",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                updateLiveTransform {
                    $0.positionX.baseValue = snapped.positionX
                    $0.positionY.baseValue = snapped.positionY
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.drag, itemID: text.id)
            }
    }

    private func scaleGesture(for text: TextTimelineItem) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.magnification, for: text) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value - 1) > 0.001 || editedTransformComponents.contains(.scale) else {
                    return
                }
                editedTransformComponents.insert(.scale)
                let snapped =
                    abs(value - 1) <= 0.001
                    ? (scale: start.scale.baseValue.x, guideX: nil, guideY: nil)
                    : snappedScale(
                        scale: start.scale.baseValue.x * value,
                        text: text,
                        selectedClipID: text.id
                    )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "scale",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                updateLiveTransform {
                    $0.scale.baseValue = proportionalScale(
                        x: snapped.scale,
                        from: start.scale.baseValue
                    )
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.magnification, itemID: text.id)
            }
    }

    private func rotationGesture(for text: TextTimelineItem) -> some Gesture {
        RotationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.rotation, for: text) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value.degrees) > 0.05 || editedTransformComponents.contains(.rotation)
                else { return }
                editedTransformComponents.insert(.rotation)
                let snapped =
                    abs(value.degrees) <= 0.05
                    ? (rotation: start.rotationDegrees.baseValue, snapped: false)
                    : snappedRotation(start.rotationDegrees.baseValue + value.degrees)
                updatePreviewSnapHaptic(
                    kind: "rotation",
                    snapped: snapped.snapped,
                    value: String(format: "%.0f", snapped.rotation)
                )
                updateLiveTransform {
                    $0.rotationDegrees.baseValue = snapped.rotation
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.rotation, itemID: text.id)
            }
    }

    private func updateCombinedHandle(
        scaleFactor: Double,
        rotationDelta: Double,
        for clip: TimelineClip
    ) {
        guard activatePreviewGesture(.combinedHandle, for: clip) else { return }
        guard let start = dragStartTransform else { return }

        var transform = liveTransform ?? start
        let rotation = combinedRotation(rotationDelta, from: start)
        if let rotation {
            transform.rotationDegrees.baseValue = rotation.rotation
        }

        let stableScaleFactor = max(scaleFactor, Self.minimumCombinedHandleScaleFactor)
        let shouldUpdateScale = abs(stableScaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        guard rotation != nil || shouldUpdateScale else { return }

        if shouldUpdateScale {
            editedTransformComponents.insert(.scale)
            clearScaleSnapFeedback()
            transform.scale.baseValue = proportionalScale(
                x: max(start.scale.baseValue.x * stableScaleFactor, Self.minimumScaleSnap),
                from: start.scale.baseValue
            )
        }

        setLiveTransform(transform)
    }

    private func updateCombinedHandle(
        scaleFactor: Double,
        rotationDelta: Double,
        for text: TextTimelineItem
    ) {
        guard activatePreviewGesture(.combinedHandle, for: text) else { return }
        guard let start = dragStartTransform else { return }

        var transform = liveTransform ?? start
        let rotation = combinedRotation(rotationDelta, from: start)
        if let rotation {
            transform.rotationDegrees.baseValue = rotation.rotation
        }

        let stableScaleFactor = max(scaleFactor, Self.minimumCombinedHandleScaleFactor)
        let shouldUpdateScale = abs(stableScaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        guard rotation != nil || shouldUpdateScale else { return }

        if shouldUpdateScale {
            editedTransformComponents.insert(.scale)
            clearScaleSnapFeedback()
            transform.scale.baseValue = proportionalScale(
                x: max(start.scale.baseValue.x * stableScaleFactor, Self.minimumScaleSnap),
                from: start.scale.baseValue
            )
        }

        setLiveTransform(transform)
    }

    private func combinedRotation(
        _ deltaDegrees: Double,
        from start: ClipTransform
    ) -> (rotation: Double, snapped: Bool)? {
        guard abs(deltaDegrees) > 0.05 || editedTransformComponents.contains(.rotation) else {
            return nil
        }
        editedTransformComponents.insert(.rotation)
        let snapped =
            abs(deltaDegrees) <= 0.05
            ? (rotation: start.rotationDegrees.baseValue, snapped: false)
            : snappedRotation(start.rotationDegrees.baseValue + deltaDegrees)
        updatePreviewSnapHaptic(
            kind: "rotation",
            snapped: snapped.snapped,
            value: String(format: "%.0f", snapped.rotation)
        )
        return snapped
    }

    private func applySnappedScale(
        _ snapped: (scale: Double, guideX: CGFloat?, guideY: CGFloat?),
        from start: ScaleValue
    ) {
        applySnappedScaleFeedback(snapped)
        updateLiveTransform {
            $0.scale.baseValue = proportionalScale(x: snapped.scale, from: start)
        }
    }

    private func applySnappedScaleFeedback(
        _ snapped: (scale: Double, guideX: CGFloat?, guideY: CGFloat?)
    ) {
        snapGuideX = snapped.guideX
        snapGuideY = snapped.guideY
        updatePreviewSnapHaptic(
            kind: "scale",
            snapped: snapped.guideX != nil || snapped.guideY != nil,
            value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
        )
    }

    private func clearScaleSnapFeedback() {
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKeys.removeValue(forKey: "scale")
    }

    private func proportionalScale(x proposedX: Double, from start: ScaleValue) -> ScaleValue {
        let startX = max(start.x, 0.000_001)
        let startY = max(start.y, 0.000_001)
        let proposedFactor = proposedX / startX
        let minimumFactor = max(0.01 / startX, 0.01 / startY)
        let maximumFactor = min(100 / startX, 100 / startY)
        let factor = min(max(proposedFactor, minimumFactor), maximumFactor)
        return ScaleValue(x: startX * factor, y: startY * factor)
    }

    private func snappedPosition(
        positionX: Double,
        positionY: Double,
        frame: PreviewClipFrame,
        selectedClipID: UUID,
        displayOffset: CGPoint = .zero
    ) -> (positionX: Double, positionY: Double, guideX: CGFloat?, guideY: CGFloat?) {
        let proposedCenter = geometryMapper.center(
            positionX: positionX,
            positionY: positionY,
            displayOffset: displayOffset
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

        let normalized = geometryMapper.normalizedPosition(
            from: CGPoint(x: snappedX.center, y: snappedY.center),
            displayOffset: displayOffset
        )
        return (normalized.x, normalized.y, snappedX.guide, snappedY.guide)
    }

    private func snappedScale(
        scale: Double,
        clip: TimelineClip,
        selectedClipID: UUID,
        transform overrideTransform: ClipTransform? = nil
    ) -> (scale: Double, guideX: CGFloat?, guideY: CGFloat?) {
        guard let baseSize = previewBaseSize(for: clip) else {
            return (min(max(scale, Self.minimumScaleSnap), 100), nil, nil)
        }

        let proposedScale = CGFloat(min(max(scale, Self.minimumScaleSnap), 100))
        let transform = overrideTransform ?? liveTransform ?? clip.transform
        let center = previewCenter(for: clip, transform: transform)
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10
        let rotation = transform.rotationDegrees.value(at: localTime(for: clip))

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
            Double(min(max(best.scale, Self.minimumScaleSnap), 100)),
            xSnap?.guide == best.guide ? xSnap?.guide : nil,
            ySnap?.guide == best.guide ? ySnap?.guide : nil
        )
    }

    private func snappedScale(
        scale: Double,
        text: TextTimelineItem,
        selectedClipID: UUID,
        transform overrideTransform: ClipTransform? = nil
    ) -> (scale: Double, guideX: CGFloat?, guideY: CGFloat?) {
        guard let baseSize = previewBaseSize(for: text) else {
            return (min(max(scale, Self.minimumScaleSnap), 100), nil, nil)
        }

        let animationScale = max(textAnimationSample(for: text).scale, 0.001)
        let proposedDisplayScale = CGFloat(min(max(scale * animationScale, Self.minimumScaleSnap), 100))
        let transform = overrideTransform ?? liveTransform ?? text.visuals.transform
        let center = previewCenter(for: text, transform: transform)
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10
        let rotation = previewRotationDegrees(for: text, transform: transform)

        let xSnap = snapScaleAxis(
            center: center.x,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.x),
            proposedScale: proposedDisplayScale,
            targets: targets.x,
            threshold: threshold
        )
        let ySnap = snapScaleAxis(
            center: center.y,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.y),
            proposedScale: proposedDisplayScale,
            targets: targets.y,
            threshold: threshold
        )

        let best = [xSnap, ySnap]
            .compactMap { $0 }
            .min { $0.distance < $1.distance }

        guard let best else {
            return (
                min(max(Double(proposedDisplayScale) / animationScale, Self.minimumScaleSnap), 100),
                nil,
                nil
            )
        }

        return (
            min(max(Double(best.scale) / animationScale, Self.minimumScaleSnap), 100),
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

        for info in activeTextInfos where info.item.id != selectedClipID {
            guard let frame = previewFrame(for: info.item) else { continue }
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
        let maximumOffset = baseOffsets.map { abs($0) }.max() ?? 0
        let minimumUsableOffset = max(maximumOffset * 0.12, 6)
        let offsets = baseOffsets.filter { abs($0) >= minimumUsableOffset }
        guard !offsets.isEmpty else { return nil }
        var best: (scale: CGFloat, guide: CGFloat, distance: CGFloat)?

        for offset in offsets {
            let proposedAnchor = center + offset * proposedScale
            for target in targets {
                let desiredScale = (target - center) / offset
                guard desiredScale.isFinite,
                    desiredScale >= Self.minimumScaleSnap,
                    desiredScale <= 100,
                    desiredScale >= proposedScale / Self.maximumScaleSnapRatio,
                    desiredScale <= proposedScale * Self.maximumScaleSnapRatio
                else { continue }
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

    private func previewFrame(
        for clip: TimelineClip,
        transform: ClipTransform? = nil
    ) -> PreviewClipFrame? {
        let transform = transform ?? clip.transform
        if let shape = clip.shape {
            let localTime = localTime(for: clip)
            guard
                let baseSize = geometryMapper.canvasSize(
                    forRenderSize: CGSize(
                        width: CGFloat(shape.width.value(at: localTime)),
                        height: CGFloat(shape.height.value(at: localTime))
                    )
                )
            else { return nil }
            let scale = transform.scale.value(at: localTime)
            let size = geometryMapper.scaledSize(baseSize, by: scale)
            let center = previewCenter(for: clip, transform: transform)
            return geometryMapper.frame(
                center: center,
                size: size,
                rotationDegrees: transform.rotationDegrees.value(at: localTime)
            )
        }

        let sourceSize = viewModel.project.naturalSize(for: clip)?.cgSize ?? viewModel.project.renderSettings.size
        guard let baseSize = geometryMapper.fittedCanvasSize(forSourceSize: sourceSize) else { return nil }
        let localTime = localTime(for: clip)
        let scale = transform.scale.value(at: localTime)
        let size = geometryMapper.scaledSize(baseSize, by: scale)
        let center = previewCenter(for: clip, transform: transform)

        return geometryMapper.frame(
            center: center,
            size: size,
            rotationDegrees: transform.rotationDegrees.value(at: localTime)
        )
    }

    private func previewFrame(
        for text: TextTimelineItem,
        transform: ClipTransform? = nil
    ) -> PreviewClipFrame? {
        guard let baseSize = previewBaseSize(for: text) else { return nil }
        let transform = transform ?? text.visuals.transform
        let localTime = localTime(for: text)
        let scale = transform.scale.value(at: localTime)
        let animationScale = max(textAnimationSample(for: text).scale, 0.001)
        let size = geometryMapper.scaledSize(
            baseSize,
            by: ScaleValue(x: scale.x * animationScale, y: scale.y * animationScale),
            minimum: 0.001
        )
        let center = previewCenter(for: text, transform: transform)
        return geometryMapper.frame(
            center: center,
            size: size,
            rotationDegrees: previewRotationDegrees(for: text, transform: transform)
        )
    }

    private func previewBaseSize(for clip: TimelineClip) -> CGSize? {
        if let shape = clip.shape {
            return geometryMapper.canvasSize(
                forRenderSize: CGSize(
                    width: CGFloat(shape.width.value(at: localTime(for: clip))),
                    height: CGFloat(shape.height.value(at: localTime(for: clip)))
                )
            )
        }

        let sourceSize = viewModel.project.naturalSize(for: clip)?.cgSize ?? viewModel.project.renderSettings.size
        return geometryMapper.fittedCanvasSize(forSourceSize: sourceSize)
    }

    private func previewBaseSize(for text: TextTimelineItem) -> CGSize? {
        let geometry = TextLayerRenderer.geometry(
            for: text,
            renderSize: viewModel.project.renderSettings.size,
            renderScale: 1
        )
        return geometryMapper.canvasSize(forRenderSize: geometry.layerSize)
    }

    private func previewCenter(
        for clip: TimelineClip,
        transform: ClipTransform? = nil
    ) -> CGPoint {
        let transform = transform ?? clip.transform
        let localTime = localTime(for: clip)
        return geometryMapper.center(
            positionX: transform.positionX.value(at: localTime),
            positionY: transform.positionY.value(at: localTime)
        )
    }

    private func previewCenter(
        for text: TextTimelineItem,
        transform: ClipTransform? = nil
    ) -> CGPoint {
        let transform = transform ?? text.visuals.transform
        let localTime = localTime(for: text)
        let animationOffset = textAnimationOffset(for: text)
        return geometryMapper.center(
            positionX: transform.positionX.value(at: localTime),
            positionY: transform.positionY.value(at: localTime),
            displayOffset: animationOffset
        )
    }

    private func localTime(for clip: TimelineClip) -> Double {
        viewModel.timelineLocalTime(for: clip)
    }

    private func localTime(for text: TextTimelineItem) -> Double {
        min(max(viewModel.currentTime - text.timelineStart, 0), text.duration)
    }

    private func isClipVisible(_ clip: TimelineClip) -> Bool {
        viewModel.isTimeInside(clip)
    }

    private func isTextVisible(_ text: TextTimelineItem) -> Bool {
        viewModel.currentTime >= text.timelineStart && viewModel.currentTime < text.timelineEnd
    }

    private func textAnimationSample(for text: TextTimelineItem) -> TextAnimationSample {
        TextAnimationEvaluator.sample(
            animations: text.animations,
            at: localTime(for: text),
            clipDuration: text.duration
        )
    }

    private func textAnimationOffset(for text: TextTimelineItem) -> CGPoint {
        let renderSize = viewModel.project.renderSettings.size
        guard renderSize.width > 0, renderSize.height > 0 else { return .zero }
        let geometry = TextLayerRenderer.geometry(
            for: text,
            renderSize: renderSize,
            renderScale: 1
        )
        let sample = textAnimationSample(for: text)
        return geometryMapper.canvasVector(
            forRenderVector: CGVector(
                dx: CGFloat(sample.translationX) * geometry.layerSize.width,
                dy: CGFloat(sample.translationY) * geometry.layerSize.height
            )
        )
            ?? .zero
    }

    private func previewRotationDegrees(
        for text: TextTimelineItem,
        transform: ClipTransform
    ) -> Double {
        let baseRotation = transform.rotationDegrees.value(at: localTime(for: text))
        let animationRotation = textAnimationSample(for: text).rotationRadians * 180 / .pi
        return baseRotation + animationRotation
    }

    private func activatePreviewGesture(
        _ gesture: PreviewTransformGesture,
        for clip: TimelineClip
    ) -> Bool {
        guard interactionClipID == nil || interactionClipID == clip.id else { return false }
        if dragStartTransform == nil {
            beginPreviewInteraction(for: clip)
        }
        prepareForTwoFingerTransformIfNeeded(gesture)
        activeTransformGestures.insert(gesture)
        return interactionClipID == clip.id && dragStartTransform != nil
    }

    private func activatePreviewGesture(
        _ gesture: PreviewTransformGesture,
        for text: TextTimelineItem
    ) -> Bool {
        guard interactionClipID == nil || interactionClipID == text.id else { return false }
        if dragStartTransform == nil {
            beginPreviewInteraction(for: text)
        }
        prepareForTwoFingerTransformIfNeeded(gesture)
        activeTransformGestures.insert(gesture)
        return interactionClipID == text.id && dragStartTransform != nil
    }

    private func prepareForTwoFingerTransformIfNeeded(_ gesture: PreviewTransformGesture) {
        guard gesture == .magnification || gesture == .rotation,
            !hasTwoFingerTransformInSession
        else { return }

        if activeTransformGestures.contains(.drag), let liveTransform {
            dragStartTransform = liveTransform
        }
        hasTwoFingerTransformInSession = true
    }

    private func prepareSelectedLivePreviewAssets() async {
        guard let assetKey = livePreviewPreparationKey,
            livePreviewAssetKey != assetKey
        else { return }

        if let clip = selectedVisualClip {
            let resolved = clip.transform.resolved(at: localTime(for: clip))
            loadLivePreviewAssets(
                for: clip,
                transform: resolved,
                assetKey: assetKey,
                allowSynchronousProxyRender: true
            )
            return
        }

        if let text = selectedTextItem {
            let resolved = text.visuals.transform.resolved(at: localTime(for: text))
            livePreviewImage = nil
            liveTextPreviewImage = renderPreviewImage(
                for: text,
                transform: resolved,
                maximumTextureDimension: Self.interactionStartTextureDimension
            )
            liveBackgroundImage = nil
            livePreviewAssetKey = assetKey
            loadLivePreviewBackground(excluding: text.id, assetKey: assetKey)
        }
    }

    private func finishPreviewGesture(
        _ gesture: PreviewTransformGesture,
        itemID: UUID
    ) {
        guard interactionClipID == itemID else { return }
        guard activeTransformGestures.remove(gesture) != nil else { return }
        guard activeTransformGestures.isEmpty else { return }
        resetPreviewInteraction(finishEdit: true)
    }

    private func baselineTransform(for clip: TimelineClip) -> ClipTransform {
        if interactionClipID == clip.id,
            livePreviewCommitRevision != nil,
            let liveTransform
        {
            return liveTransform
        }
        return clip.transform.resolved(at: localTime(for: clip))
    }

    private func baselineTransform(for text: TextTimelineItem) -> ClipTransform {
        if interactionClipID == text.id,
            livePreviewCommitRevision != nil,
            let liveTransform
        {
            return liveTransform
        }
        return text.visuals.transform.resolved(at: localTime(for: text))
    }

    private func hasUsableLiveProxy(
        for itemID: UUID,
        assetKey: String,
        isText: Bool
    ) -> Bool {
        guard liveBackgroundImage != nil else { return false }
        let hasMatchingPreparedProxy = livePreviewAssetKey == assetKey
            && (isText ? liveTextPreviewImage != nil : livePreviewImage != nil)
        let hasCommitHandoffProxy = interactionClipID == itemID
            && livePreviewCommitRevision != nil
            && (isText ? liveTextPreviewImage != nil : livePreviewImage != nil)
        return hasMatchingPreparedProxy || hasCommitHandoffProxy
    }

    private func beginPreviewInteraction(for clip: TimelineClip) {
        let resolved = baselineTransform(for: clip)
        let assetKey = livePreviewAssetKey(for: clip.id)
        let hasPreparedProxy = hasUsableLiveProxy(for: clip.id, assetKey: assetKey, isText: false)
        livePreviewCommitRevision = nil
        livePreviewLoadID = UUID()
        isLivePreviewSourceHidden = hasPreparedProxy
        viewModel.beginLivePreviewInteraction()
        dragStartTransform = resolved
        liveTransform = resolved
        if !hasPreparedProxy, livePreviewAssetKey != assetKey {
            livePreviewImage = nil
            liveTextPreviewImage = nil
            liveBackgroundImage = nil
        }
        interactionClipID = clip.id
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        isTransforming = true
        EditorHaptics.dragStart()
        viewModel.beginInteractiveEdit()
        viewModel.updateLivePreviewTransform(
            resolved,
            for: clip.id,
            hidden: hasPreparedProxy,
            immediate: true
        )
        if hasPreparedProxy {
            isLivePreviewSourceHidden = true
        }
        loadLivePreviewAssets(
            for: clip,
            transform: resolved,
            assetKey: assetKey,
            allowSynchronousProxyRender: false
        )
    }

    private func beginPreviewInteraction(for text: TextTimelineItem) {
        let resolved = baselineTransform(for: text)
        let assetKey = livePreviewAssetKey(for: text.id)
        let hasPreparedProxy = hasUsableLiveProxy(for: text.id, assetKey: assetKey, isText: true)
        livePreviewCommitRevision = nil
        livePreviewLoadID = UUID()
        isLivePreviewSourceHidden = hasPreparedProxy
        viewModel.beginLivePreviewInteraction()
        dragStartTransform = resolved
        liveTransform = resolved
        if !hasPreparedProxy, livePreviewAssetKey != assetKey {
            livePreviewImage = nil
            liveTextPreviewImage = nil
            liveBackgroundImage = nil
        }
        interactionClipID = text.id
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        isTransforming = true
        EditorHaptics.dragStart()
        viewModel.beginInteractiveEdit()
        viewModel.updateLivePreviewTransform(
            resolved,
            for: text.id,
            hidden: hasPreparedProxy,
            immediate: true
        )
        if hasPreparedProxy {
            isLivePreviewSourceHidden = true
        }
        loadLivePreviewBackground(excluding: text.id, assetKey: assetKey)
    }

    private func loadLivePreviewAssets(
        for clip: TimelineClip,
        transform: ClipTransform,
        assetKey: String,
        allowSynchronousProxyRender: Bool
    ) {
        guard clip.shape == nil,
            let media = viewModel.project.mediaDescriptor(for: clip)
        else {
            if allowSynchronousProxyRender, let shape = clip.shape {
                livePreviewImage = renderPreviewImage(
                    for: shape,
                    localTime: localTime(for: clip),
                    transform: transform,
                    maximumTextureDimension: Self.interactionStartTextureDimension
                )
                livePreviewAssetKey = assetKey
            }
            loadLivePreviewBackground(excluding: clip.id, assetKey: assetKey)
            return
        }

        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = viewModel.currentTime
        let targetHeight = max(previewFrame(for: clip, transform: transform)?.rect.height ?? 120, 120)
        let speedMap: SpeedMap
        if case .media(let item) = viewModel.project.item(id: clip.id) {
            speedMap = item.speedMap
        } else {
            speedMap = .constant
        }
        Task {
            async let background = viewModel.renderService.makePreviewBackgroundImage(
                for: viewModel.project,
                at: timelineTime,
                excluding: clip.id
            )
            async let proxyImage = TimelineThumbnailLoader.image(
                for: clip,
                media: media,
                speedMap: speedMap,
                timelineTime: timelineTime,
                targetHeight: targetHeight
            )
            let (backgroundImage, image) = await (try? background, proxyImage)
            guard !Task.isCancelled,
                livePreviewLoadID == loadID,
                livePreviewPreparationKey == assetKey || interactionClipID == clip.id
            else { return }
            guard interactionClipID != clip.id || isLivePreviewSourceHidden else { return }
            liveBackgroundImage = backgroundImage
            livePreviewImage = image
            livePreviewAssetKey = assetKey
        }
    }

    private func loadLivePreviewBackground(excluding itemID: UUID, assetKey: String) {
        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = viewModel.currentTime
        Task {
            let image = try? await viewModel.renderService.makePreviewBackgroundImage(
                for: viewModel.project,
                at: timelineTime,
                excluding: itemID
            )
            guard !Task.isCancelled,
                livePreviewLoadID == loadID,
                livePreviewPreparationKey == assetKey || interactionClipID == itemID
            else { return }
            guard interactionClipID != itemID || isLivePreviewSourceHidden else { return }
            liveBackgroundImage = image
            livePreviewAssetKey = assetKey
        }
    }

    private func renderPreviewImage(
        for text: TextTimelineItem,
        transform: ClipTransform,
        maximumTextureDimension: Int = GeneratedRasterPolicy.maximumTextureDimension
    ) -> UIImage? {
        let geometry = TextLayerRenderer.geometry(
            for: text,
            renderSize: viewModel.project.renderSettings.size,
            renderScale: 1,
            at: localTime(for: text)
        )
        return textRasterizer.image(
            for: text,
            renderSize: viewModel.project.renderSettings.size,
            rasterScale: liveRasterScale(
                for: transform,
                logicalSize: geometry.layerSize,
                maximumTextureDimension: maximumTextureDimension
            ),
            localTime: localTime(for: text),
            glyphReveal: textAnimationSample(for: text).glyphReveal
        )
    }

    private func renderPreviewImage(
        for shape: ClipShape,
        localTime: Double,
        transform: ClipTransform,
        maximumTextureDimension: Int = GeneratedRasterPolicy.maximumTextureDimension
    ) -> UIImage? {
        let logicalSize = CGSize(
            width: max(CGFloat(shape.width.value(at: localTime)), 1),
            height: max(CGFloat(shape.height.value(at: localTime)), 1)
        )
        return shapeRasterizer.image(
            for: shape,
            at: localTime,
            rasterScale: liveRasterScale(
                for: transform,
                logicalSize: logicalSize,
                maximumTextureDimension: maximumTextureDimension
            )
        )
    }

    private func liveRasterScale(
        for transform: ClipTransform,
        logicalSize: CGSize,
        maximumTextureDimension: Int = GeneratedRasterPolicy.maximumTextureDimension
    ) -> CGSize {
        let scale = transform.scale.baseValue
        let requested = CGSize(
            width: max(abs(CGFloat(scale.x)), 1),
            height: max(abs(CGFloat(scale.y)), 1)
        )
        return GeneratedRasterPolicy.generatedLayerRasterScale(
            transformScale: requested,
            qualityScale: 1,
            logicalSize: logicalSize,
            renderSize: viewModel.project.renderSettings.size,
            maximumTextureDimension: maximumTextureDimension
        )
    }

    private func liveProxyRasterScale(for transform: ClipTransform) -> CGSize {
        if let clip = selectedVisualClip,
            let shape = clip.shape
        {
            let localTime = localTime(for: clip)
            return liveRasterScale(
                for: transform,
                logicalSize: CGSize(
                    width: max(CGFloat(shape.width.value(at: localTime)), 1),
                    height: max(CGFloat(shape.height.value(at: localTime)), 1)
                ),
                maximumTextureDimension: GeneratedRasterPolicy.maximumTextureDimension
            )
        }
        if let text = selectedTextItem {
            let geometry = TextLayerRenderer.geometry(
                for: text,
                renderSize: viewModel.project.renderSettings.size,
                renderScale: 1,
                at: localTime(for: text)
            )
            return liveRasterScale(
                for: transform,
                logicalSize: geometry.layerSize,
                maximumTextureDimension: GeneratedRasterPolicy.maximumTextureDimension
            )
        }
        return CGSize(width: 1, height: 1)
    }

    private func updateLiveProxyRasterIfNeeded(for transform: ClipTransform) {
        guard !isTransforming else { return }

        let rasterScale = liveProxyRasterScale(for: transform)
        if let clip = selectedVisualClip, clip.shape != nil {
            let key = "\(clip.id.uuidString)|\(String(format: "%.3f", rasterScale.width))|\(String(format: "%.3f", rasterScale.height))"
            guard liveProxyRasterKey != key else { return }
            liveProxyRasterKey = key
            if let shape = clip.shape {
                livePreviewImage = renderPreviewImage(
                    for: shape,
                    localTime: localTime(for: clip),
                    transform: transform
                )
            }
            return
        }

        if let text = selectedTextItem {
            let key = "\(text.id.uuidString)|\(String(format: "%.3f", rasterScale.width))|\(String(format: "%.3f", rasterScale.height))"
            guard liveProxyRasterKey != key else { return }
            liveProxyRasterKey = key
            liveTextPreviewImage = renderPreviewImage(for: text, transform: transform)
        }
    }

    private func updateLiveTransform(_ update: (inout ClipTransform) -> Void) {
        guard var transform = liveTransform else { return }
        update(&transform)
        setLiveTransform(transform)
    }

    private func setLiveTransform(_ transform: ClipTransform) {
        liveTransform = transform
        updateLiveProxyRasterIfNeeded(for: transform)
        if let interactionClipID {
            viewModel.updateLivePreviewTransform(transform, for: interactionClipID)
        }
    }

    private func applyLiveTransformToProject(_ transform: ClipTransform) {
        viewModel.setSelectedTransform(
            positionX: editedTransformComponents.contains(.position)
                ? transform.positionX.baseValue : nil,
            positionY: editedTransformComponents.contains(.position)
                ? transform.positionY.baseValue : nil,
            scale: editedTransformComponents.contains(.scale)
                ? transform.scale.baseValue.x : nil,
            rotationDegrees: editedTransformComponents.contains(.rotation)
                ? transform.rotationDegrees.baseValue : nil,
            interactive: true
        )
    }

    private func resetPreviewInteraction(finishEdit: Bool) {
        let committedItemID = interactionClipID
        let committedTransform = liveTransform
        let hasCommittedTransform =
            finishEdit
            && interactionClipID == viewModel.selectedTimelineItemID
            && liveTransform != nil
            && !editedTransformComponents.isEmpty
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKeys.removeAll()
        activeTransformGestures.removeAll()
        hasTwoFingerTransformInSession = false
        dragStartTransform = nil

        guard hasCommittedTransform, let committedTransform else {
            viewModel.showLivePreviewSource(for: committedItemID)
            clearLivePreview()
            if finishEdit {
                viewModel.finishInteractiveEdit()
            }
            return
        }

        if let committedItemID {
            viewModel.updateLivePreviewTransform(
                committedTransform,
                for: committedItemID,
                hidden: isLivePreviewSourceHidden,
                immediate: true
            )
        }
        applyLiveTransformToProject(committedTransform)
        livePreviewCommitRevision = viewModel.previewContentRevision + 1
        viewModel.finishInteractiveEdit(
            delayRebuild: false,
            preserveLivePreviewRefresh: true
        )
        EditorHaptics.editCommit()
    }

    private func clearLivePreview() {
        dragStartTransform = nil
        liveTransform = nil
        livePreviewImage = nil
        liveTextPreviewImage = nil
        liveBackgroundImage = nil
        livePreviewAssetKey = nil
        isLivePreviewSourceHidden = false
        livePreviewLoadID = nil
        livePreviewCommitRevision = nil
        liveProxyRasterKey = nil
        interactionClipID = nil
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKeys = [:]
        isTransforming = false
    }

    private func updatePreviewSnapHaptic(kind: String, snapped: Bool, value: String) {
        let key = snapped ? "\(kind)-\(value)" : nil
        let previousKey = previewSnapKeys[kind]
        if let key {
            previewSnapKeys[kind] = key
        } else {
            previewSnapKeys.removeValue(forKey: kind)
        }
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

struct PreviewSelectionBox: View {
    let frame: PreviewClipFrame
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onTransformChanged: (_ scaleFactor: Double, _ rotationDelta: Double) -> Void
    let onTransformEnded: () -> Void

    @State private var combinedHandleState: CombinedHandleInteractionState?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(MotionaryTheme.accent, lineWidth: 1.5)

            selectionButton(
                systemName: "xmark",
                accessibilityLabel: "Delete layer",
                action: onDelete
            )
            .position(SelectionHandlePosition.topLeft.point(in: frame.rect.size))

            selectionButton(
                systemName: "plus.square.on.square",
                accessibilityLabel: "Duplicate layer",
                action: onDuplicate
            )
            .position(SelectionHandlePosition.bottomLeft.point(in: frame.rect.size))

            transformHandle(
                systemName: "arrow.up.left.and.arrow.down.right",
                accessibilityLabel: "Scale and rotate layer"
            )
            .position(SelectionHandlePosition.bottomRight.point(in: frame.rect.size))
            .highPriorityGesture(combinedHandleGesture)
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .contentShape(Rectangle())
    }

    private func selectionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            selectionControl(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func transformHandle(
        systemName: String,
        accessibilityLabel: String
    ) -> some View {
        selectionControl(systemName: systemName)
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private func selectionControl(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(MotionaryTheme.foregroundOnAccent)
            .frame(width: 22, height: 22)
            .background(MotionaryTheme.accent, in: Circle())
            .frame(width: 30, height: 30)
            .contentShape(Circle())
    }

    private var combinedHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                var state = combinedHandleState
                if state == nil {
                    let startVector = rotatedBottomRightVector(
                        size: frame.rect.size,
                        rotationDegrees: frame.rotationDegrees
                    )
                    state = CombinedHandleInteractionState(
                        startVector: startVector,
                        previousAngle: atan2(startVector.dy, startVector.dx),
                        accumulatedRotationDegrees: 0
                    )
                }
                guard var state else { return }

                let currentVector = CGVector(
                    dx: state.startVector.dx + value.translation.width,
                    dy: state.startVector.dy + value.translation.height
                )
                let startDistance = max(hypot(state.startVector.dx, state.startVector.dy), 1)
                let currentDistance = hypot(currentVector.dx, currentVector.dy)
                let scaleFactor = max(Double(currentDistance / startDistance), 0.01)

                if currentDistance > 1 {
                    let angle = atan2(currentVector.dy, currentVector.dx)
                    state.accumulatedRotationDegrees += normalizedDegrees(
                        (angle - state.previousAngle) * 180 / .pi
                    )
                    state.previousAngle = angle
                }

                combinedHandleState = state
                onTransformChanged(scaleFactor, state.accumulatedRotationDegrees)
            }
            .onEnded { _ in
                combinedHandleState = nil
                onTransformEnded()
            }
    }

    private func rotatedBottomRightVector(
        size: CGSize,
        rotationDegrees: Double
    ) -> CGVector {
        let vector = CGVector(dx: size.width * 0.5, dy: size.height * 0.5)
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGVector(
            dx: vector.dx * cosine - vector.dy * sine,
            dy: vector.dx * sine + vector.dy * cosine
        )
    }

    private func normalizedDegrees(_ degrees: CGFloat) -> Double {
        var normalized = Double(degrees)
        while normalized > 180 { normalized -= 360 }
        while normalized <= -180 { normalized += 360 }
        return normalized
    }
}

private struct LiveTransformClipProxy: View {
    let clip: TimelineClip
    let frame: PreviewClipFrame
    let transform: ClipTransform
    let image: UIImage?
    let localTime: Double

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.clear)
            }
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .clipped()
        .scaleEffect(
            x: transform.isFlippedHorizontally ? -1 : 1,
            y: transform.isFlippedVertically ? -1 : 1
        )
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .opacity(min(max(transform.opacity.baseValue, 0), 1))
    }
}

private struct LiveTransformTextProxy: View {
    let image: UIImage
    let frame: PreviewClipFrame
    let opacity: Double
    let clipReveal: Double
    let isFlippedHorizontally: Bool
    let isFlippedVertically: Bool

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: frame.rect.width, height: frame.rect.height)
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(
                        width: frame.rect.width * CGFloat(min(max(clipReveal, 0), 1)),
                        height: frame.rect.height
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaleEffect(
                x: isFlippedHorizontally ? -1 : 1,
                y: isFlippedVertically ? -1 : 1
            )
            .rotationEffect(.degrees(frame.rotationDegrees))
            .position(x: frame.rect.midX, y: frame.rect.midY)
            .opacity(min(max(opacity, 0), 1))
    }
}

@MainActor
private final class PreviewTextRasterizer {
    private let renderer = TextLayerRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(
        for item: TextTimelineItem,
        renderSize: CGSize,
        rasterScale: CGSize,
        localTime: Double,
        glyphReveal: Double
    ) -> UIImage? {
        let result = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 1,
            rasterScale: rasterScale,
            at: localTime,
            glyphReveal: glyphReveal
        )
        let extent = result.image.extent.integral
        guard extent.width > 0, extent.height > 0,
            let image = context.createCGImage(result.image, from: extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor
private final class PreviewShapeRasterizer {
    private final class CachedImage: NSObject {
        let image: UIImage

        init(image: UIImage) {
            self.image = image
        }
    }

    private let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 96
        cache.totalCostLimit = GeneratedRasterPolicy.livePreviewShapeCacheBytes
        return cache
    }()

    private let renderer = try? MetalFrameRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(
        for shape: ClipShape,
        at localTime: Double,
        rasterScale: CGSize
    ) -> UIImage? {
        let layout = ShapeRasterLayout(
            shape: shape,
            at: localTime,
            logicalRenderScale: 1,
            rasterScale: rasterScale
        )
        let key = cacheKey(shape: shape, layout: layout, localTime: localTime)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let renderer,
            let raster = try? renderer.renderShapeLayer(
                shape,
                at: localTime,
                logicalRenderScale: 1,
                rasterScale: layout.rasterScale
            )
        else { return nil }
        let extent = raster.extent.integral
        guard extent.width > 0, extent.height > 0,
            let cgImage = context.createCGImage(raster, from: extent)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(
            CachedImage(image: image),
            forKey: key,
            cost: max(Int(layout.rasterSize.width * layout.rasterSize.height * 4), 1)
        )
        return image
    }

    private func cacheKey(
        shape: ClipShape,
        layout: ShapeRasterLayout,
        localTime: Double
    ) -> NSString {
        [
            shape.kind.rawValue,
            String(format: "%.4f", shape.width.value(at: localTime)),
            String(format: "%.4f", shape.height.value(at: localTime)),
            String(format: "%.4f", shape.cornerRadius.value(at: localTime)),
            String(format: "%.5f", shape.color.red),
            String(format: "%.5f", shape.color.green),
            String(format: "%.5f", shape.color.blue),
            String(format: "%.5f", shape.color.alpha),
            String(format: "%.5f", layout.rasterScale.width),
            String(format: "%.5f", layout.rasterScale.height),
            "\(Int(layout.rasterSize.width.rounded()))",
            "\(Int(layout.rasterSize.height.rounded()))",
            String(format: "%.4f", layout.rasterCornerRadius)
        ].joined(separator: "|") as NSString
    }
}

private struct CombinedHandleInteractionState {
    let startVector: CGVector
    var previousAngle: CGFloat
    var accumulatedRotationDegrees: Double
}

enum SelectionHandlePosition: CaseIterable, Identifiable {
    case topLeft
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: 0, y: 0)
        case .bottomLeft:
            CGPoint(x: 0, y: size.height)
        case .bottomRight:
            CGPoint(x: size.width, y: size.height)
        }
    }
}
