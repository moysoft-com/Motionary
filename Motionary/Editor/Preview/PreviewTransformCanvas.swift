// Preview hit testing, selection, snapping, and direct manipulation.
// Rendered pixels stay exclusively in the AVPlayer-backed compositor surface.

import CoreImage
import SwiftUI
import UIKit

struct PreviewClipInfo: Identifiable {
    let trackID: UUID
    let clip: TimelineClip
    let timelineDuration: Double

    var id: UUID { clip.id }
}

struct PreviewTextInfo: Identifiable {
    let trackID: UUID
    let item: TextTimelineItem

    var id: UUID { item.id }
}

struct PreviewAdjustmentInfo: Identifiable {
    let trackID: UUID
    let item: AdjustmentTimelineItem

    var id: UUID { item.id }
}

enum PreviewVisualInfo: Identifiable {
    case clip(PreviewClipInfo)
    case text(PreviewTextInfo)
    case adjustment(PreviewAdjustmentInfo)

    var id: UUID {
        switch self {
        case .clip(let info): info.id
        case .text(let info): info.id
        case .adjustment(let info): info.id
        }
    }
}

private struct PreviewVisualInterval {
    let order: Int
    let start: Double
    let end: Double
    let info: PreviewVisualInfo
}

private struct PreviewVisualIndexRevision: Equatable {
    let timeline: Int
    let preview: Int
}

struct PreviewVisualIntervalIndex {
    private indirect enum Node {
        case empty
        case branch(
            center: Double,
            overlappingByStart: [PreviewVisualInterval],
            overlappingByEnd: [PreviewVisualInterval],
            left: Node,
            right: Node
        )
    }

    private let root: Node
    private let intervalByID: [UUID: PreviewVisualInterval]

    init(project: EditorProject) {
        var intervals: [PreviewVisualInterval] = []
        intervals.reserveCapacity(
            project.tracks.reduce(0) { $0 + $1.items.count }
        )
        var order = 0
        for track in project.tracks {
            for item in track.items {
                defer { order += 1 }
                let info: PreviewVisualInfo
                switch item {
                case .media, .shape:
                    guard let clip = item.legacyClip(), clip.mediaType != .audio else {
                        continue
                    }
                    info = .clip(
                        PreviewClipInfo(
                            trackID: track.id,
                            clip: clip,
                            timelineDuration: item.placementDuration
                        )
                    )
                case .text(let text):
                    info = .text(
                        PreviewTextInfo(trackID: track.id, item: text)
                    )
                case .adjustment(let adjustment):
                    info = .adjustment(
                        PreviewAdjustmentInfo(
                            trackID: track.id,
                            item: adjustment
                        )
                    )
                case .caption, .compound:
                    continue
                }
                guard item.timelineStart.isFinite,
                    item.timelineEnd.isFinite,
                    item.timelineEnd > item.timelineStart
                else { continue }
                intervals.append(
                    PreviewVisualInterval(
                        order: order,
                        start: item.timelineStart,
                        end: item.timelineEnd,
                        info: info
                    )
                )
            }
        }
        root = Self.makeNode(intervals)
        intervalByID = intervals.reduce(into: [:]) {
            $0[$1.info.id] = $1
        }
    }

    func active(
        at time: Double,
        retaining selectedItemID: UUID?
    ) -> [PreviewVisualInfo] {
        var intervals: [PreviewVisualInterval] = []
        Self.collectActive(in: root, at: time, into: &intervals)
        if let selectedItemID,
            !intervals.contains(where: { $0.info.id == selectedItemID }),
            let retained = intervalByID[selectedItemID]
        {
            intervals.append(retained)
        }
        intervals.sort { $0.order < $1.order }
        return intervals.map(\.info)
    }

    private static func makeNode(
        _ intervals: [PreviewVisualInterval]
    ) -> Node {
        guard !intervals.isEmpty else { return .empty }
        let centers = intervals
            .map { ($0.start + $0.end) * 0.5 }
            .sorted()
        let center = centers[centers.count / 2]
        var left: [PreviewVisualInterval] = []
        var right: [PreviewVisualInterval] = []
        var overlapping: [PreviewVisualInterval] = []
        left.reserveCapacity(intervals.count / 2)
        right.reserveCapacity(intervals.count / 2)
        overlapping.reserveCapacity(intervals.count)
        for interval in intervals {
            if interval.end <= center {
                left.append(interval)
            } else if interval.start > center {
                right.append(interval)
            } else {
                overlapping.append(interval)
            }
        }
        return .branch(
            center: center,
            overlappingByStart: overlapping.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.order < $1.order
            },
            overlappingByEnd: overlapping.sorted {
                if $0.end != $1.end { return $0.end > $1.end }
                return $0.order < $1.order
            },
            left: makeNode(left),
            right: makeNode(right)
        )
    }

    private static func collectActive(
        in node: Node,
        at time: Double,
        into result: inout [PreviewVisualInterval]
    ) {
        switch node {
        case .empty:
            return
        case .branch(
            let center,
            let overlappingByStart,
            let overlappingByEnd,
            let left,
            let right
        ):
            if time < center {
                for interval in overlappingByStart {
                    guard interval.start <= time else { break }
                    result.append(interval)
                }
                collectActive(in: left, at: time, into: &result)
            } else {
                for interval in overlappingByEnd {
                    guard interval.end > time else { break }
                    result.append(interval)
                }
                if time > center {
                    collectActive(in: right, at: time, into: &result)
                }
            }
        }
    }
}

struct PreviewClipFrame {
    let rect: CGRect
    let rotationDegrees: Double
}

private struct PreviewHitCandidate {
    let itemID: UUID
    let order: Int
    let select: () -> Void
}

extension PreviewClipFrame {
    var center: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    func contains(_ point: CGPoint) -> Bool {
        rect.contains(unrotated(point))
    }

    func containsBorder(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let resolvedTolerance = max(tolerance, 0)
        let localPoint = unrotated(point)
        guard rect.insetBy(dx: -resolvedTolerance, dy: -resolvedTolerance).contains(localPoint) else {
            return false
        }
        guard rect.width > resolvedTolerance * 2,
            rect.height > resolvedTolerance * 2
        else {
            return true
        }
        return !rect.insetBy(dx: resolvedTolerance, dy: resolvedTolerance).contains(localPoint)
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

    private func unrotated(_ point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = CGFloat(-rotationDegrees * .pi / 180)
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGPoint(
            x: translated.x * cosine - translated.y * sine + center.x,
            y: translated.x * sine + translated.y * cosine + center.y
        )
    }
}

struct PreviewGeometryMapper {
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
        guard
            let fittedRenderSize = VideoSourceGeometry.fittedSize(
                sourceSize: sourceSize,
                inside: renderSize
            )
        else { return nil }
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

    func adjustmentFrame(
        transform: ClipTransform,
        at localTime: Double
    ) -> PreviewClipFrame {
        let scale = transform.scale.value(at: localTime)
        return frame(
            center: center(
                positionX: transform.positionX.value(at: localTime),
                positionY: transform.positionY.value(at: localTime)
            ),
            size: scaledSize(canvasRect.size, by: scale),
            rotationDegrees: transform.rotationDegrees.value(at: localTime)
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

private struct PreviewSnapInteractionState {
    var positionLockX: PreviewAxisSnapLock?
    var positionLockY: PreviewAxisSnapLock?
    var scaleLockX: PreviewAxisSnapLock?
    var scaleLockY: PreviewAxisSnapLock?
    var rotationGuideDegrees: Double?

    mutating func reset() {
        self = PreviewSnapInteractionState()
    }
}

private struct PreviewCanvasPositionSnap {
    let positionX: Double
    let positionY: Double
    let lockX: PreviewAxisSnapLock?
    let lockY: PreviewAxisSnapLock?

    var guideX: CGFloat? { lockX?.guide }
    var guideY: CGFloat? { lockY?.guide }
}

private struct PreviewCanvasScaleSnap {
    let scale: Double
    let lockX: PreviewAxisSnapLock?
    let lockY: PreviewAxisSnapLock?

    var guideX: CGFloat? { lockX?.guide }
    var guideY: CGFloat? { lockY?.guide }
}

enum PreviewInteractionProxyPolicy {
    static func canUseRasterProxy(for visuals: TimelineItemVisuals) -> Bool {
        visuals.adjustments == AdjustmentSettings()
            && !visuals.effectStack.effects.contains(where: \.isEnabled)
            && visuals.mask == nil
            && visuals.backgroundRemoval == nil
            && visuals.blendMode == .normal
    }
}

struct PreviewRasterRequestToken: Equatable {
    let itemID: UUID
    let assetKey: String
    let loadID: UUID
}

enum PreviewRasterDeliveryPolicy {
    static func shouldApply(
        _ token: PreviewRasterRequestToken,
        currentLoadID: UUID?,
        currentSelectedItemID: UUID?,
        currentAssetKey: String?,
        isTransforming: Bool
    ) -> Bool {
        !isTransforming
            && currentLoadID == token.loadID
            && currentSelectedItemID == token.itemID
            && currentAssetKey == token.assetKey
    }
}

struct PreviewTransformCanvas: View {
    private static let interactionStartTextureDimension = 1_024
    private static let minimumCombinedHandleScaleFactor = 0.08
    private static let minimumScaleSnap = 0.05
    private static let maximumScaleSnapRatio: CGFloat = 1.35

    let viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    @ObservedObject private var selectionState: SelectionState
    @ObservedObject private var timelineState: TimelineState
    @ObservedObject private var previewState: PreviewState
    @ObservedObject private var previewCanvasState: PreviewCanvasState
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
    @State private var interactionClipID: UUID?
    @State private var activeTransformGestures: Set<PreviewTransformGesture> = []
    @State private var hasTwoFingerTransformInSession = false
    @State private var editedTransformComponents: Set<PreviewTransformComponent> = []
    @State private var snapGuideX: CGFloat?
    @State private var snapGuideY: CGFloat?
    @State private var snapRotationGuideDegrees: Double?
    @State private var snapInteractionState = PreviewSnapInteractionState()
    @State private var interactionSnapTargets = PreviewSnapTargets.empty
    @State private var previewSnapKeys: [String: String] = [:]
    @State private var lastPreviewSnapFeedbackKey: String?
    @State private var lastPreviewSnapFeedbackAt: Date = .distantPast
    @State private var isTransforming = false
    @State private var isCommitPresenting = false
    @State private var textGeometryRenderer = TextLayerRenderer()
    @State private var textRasterizer = PreviewTextRasterizer()
    @State private var shapeRasterizer = PreviewShapeRasterizer()
    @State private var visualIntervalIndex: PreviewVisualIntervalIndex

    init(viewModel: EditorViewModel, canvasFrame: CGRect) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _selectionState = ObservedObject(wrappedValue: viewModel.selectionState)
        _timelineState = ObservedObject(wrappedValue: viewModel.timelineState)
        _previewState = ObservedObject(wrappedValue: viewModel.previewState)
        _previewCanvasState = ObservedObject(wrappedValue: viewModel.previewCanvasState)
        self.canvasFrame = canvasFrame
        _visualIntervalIndex = State(
            initialValue: PreviewVisualIntervalIndex(project: viewModel.project)
        )
    }

    var body: some View {
        let _ = previewCanvasState.visualRevision
        ZStack {
            ZStack {
                ForEach(activeVisualInfos.reversed()) { info in
                    switch info {
                    case .clip(let clipInfo):
                        if let frame = previewFrame(for: clipInfo) {
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

                    case .adjustment(let adjustmentInfo):
                        let frame = previewFrame(for: adjustmentInfo.item)
                        Rectangle()
                            .fill(Color.clear)
                            .frame(
                                width: max(frame.rect.width, 44),
                                height: max(frame.rect.height, 44)
                            )
                            .rotationEffect(.degrees(frame.rotationDegrees))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Adjustment layer \(adjustmentInfo.item.name)")
                            .allowsHitTesting(false)
                    }
                }

                if isLiveProxyVisible, isLivePreviewSourceHidden, let liveBackgroundImage {
                    Image(uiImage: liveBackgroundImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .clipped()
                        .allowsHitTesting(false)
                }

                if isLiveProxyVisible,
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

                if isLiveProxyVisible,
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

                PreviewSnapGuideOverlay(
                    canvasRect: canvasRect,
                    guideX: snapGuideX,
                    guideY: snapGuideY,
                    rotationDegrees: snapRotationGuideDegrees,
                    rotationCenter: selectedPreviewFrame?.center
                )

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
                    onTap: handleSelectionBoxTap,
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
                    onTap: handleSelectionBoxTap,
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

            if let adjustment = selectedAdjustmentItem {
                let frame = previewFrame(
                    for: adjustment,
                    transform: liveTransform ?? adjustment.visuals.transform
                )
                PreviewSelectionBox(
                    frame: selectionFrame(from: frame),
                    style: .adjustment,
                    onDelete: viewModel.deleteSelectedClip,
                    onDuplicate: viewModel.duplicateSelectedClip,
                    onTap: handleSelectionBoxTap,
                    onTransformChanged: { scaleFactor, rotationDelta in
                        updateCombinedHandle(
                            scaleFactor: scaleFactor,
                            rotationDelta: rotationDelta,
                            for: adjustment
                        )
                    },
                    onTransformEnded: {
                        finishPreviewGesture(.combinedHandle, itemID: adjustment.id)
                    }
                )
                .gesture(dragGesture(for: adjustment, frame: frame))
                .simultaneousGesture(scaleGesture(for: adjustment))
                .simultaneousGesture(rotationGesture(for: adjustment))
                .id(adjustment.id)
            }
        }
        .coordinateSpace(name: "PreviewTransformCanvasRoot")
        .onChange(of: selectionState.clipID) { _, _ in
            DispatchQueue.main.async {
                resetPreviewInteraction(finishEdit: isTransforming)
            }
        }
        .onChange(of: previewState.contentRevision) { _, revision in
            guard let targetRevision = livePreviewCommitRevision,
                revision >= targetRevision
            else { return }
            DispatchQueue.main.async {
                viewModel.completeLivePreviewCommitPresentation(for: interactionClipID)
                clearLivePreview()
            }
        }
        .onChange(of: visualIndexRevision) { _, _ in
            let project = viewModel.project
            DispatchQueue.main.async {
                visualIntervalIndex = PreviewVisualIntervalIndex(project: project)
            }
        }
        .onDisappear {
            DispatchQueue.main.async {
                resetPreviewInteraction(finishEdit: isTransforming)
            }
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

    private var isLiveProxyVisible: Bool {
        isTransforming || isCommitPresenting
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

    private var selectedAdjustmentItem: AdjustmentTimelineItem? {
        guard case .adjustment(let item) = viewModel.selectedTimelineItem else { return nil }
        return item
    }

    private var selectedPreviewFrame: PreviewClipFrame? {
        if let clip = selectedVisualClip {
            return previewFrame(for: clip, transform: liveTransform ?? clip.transform)
        }
        if let text = selectedTextItem {
            return previewFrame(for: text, transform: liveTransform ?? text.visuals.transform)
        }
        if let adjustment = selectedAdjustmentItem {
            return previewFrame(
                for: adjustment,
                transform: liveTransform ?? adjustment.visuals.transform
            )
        }
        return nil
    }

    private var livePreviewPreparationKey: String? {
        // Do not pre-render live transform proxies just because playback paused.
        // On dense projects this path builds a temporary composition and can
        // overlap with pause/resume state changes, freezing the editor.
        return nil
    }

    private func canUseRasterProxy(for itemID: UUID) -> Bool {
        guard let visuals = viewModel.project.item(id: itemID)?.editableVisuals else {
            return false
        }
        return PreviewInteractionProxyPolicy.canUseRasterProxy(for: visuals)
    }

    private func livePreviewAssetKey(for itemID: UUID, frameTime: Double? = nil) -> String {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let time = frameTime ?? (playbackState.currentTime * frameRate).rounded() / frameRate
        return "\(itemID.uuidString)|\(previewState.contentRevision)|\(String(format: "%.4f", time))"
    }

    private var activeVisualInfos: [PreviewVisualInfo] {
        visualIntervalIndex.active(
            at: playbackState.currentTime,
            retaining: viewModel.selectedTimelineItemID
        )
    }

    private var visualIndexRevision: PreviewVisualIndexRevision {
        PreviewVisualIndexRevision(
            timeline: timelineState.contentRevision,
            preview: previewState.contentRevision
        )
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
                    guard let frame = previewFrame(for: clipInfo),
                        frame.contains(point)
                    else { return nil }
                    return PreviewHitCandidate(
                        itemID: clipInfo.clip.id,
                        order: index,
                        select: {
                            viewModel.selectClip(clipInfo.clip.id, trackID: clipInfo.trackID)
                        }
                    )

                case .text(let textInfo):
                    guard var frame = previewFrame(for: textInfo.item) else { return nil }
                    frame = frame.expandedToMinimumHitSize(44)
                    guard frame.contains(point) else { return nil }
                    return PreviewHitCandidate(
                        itemID: textInfo.item.id,
                        order: index,
                        select: {
                            viewModel.selectTimelineItem(
                                textInfo.item.id,
                                trackID: textInfo.trackID
                            )
                        }
                    )

                case .adjustment(let adjustmentInfo):
                    let frame = previewFrame(for: adjustmentInfo.item)
                    guard frame.containsBorder(point, tolerance: 18) else { return nil }
                    return PreviewHitCandidate(
                        itemID: adjustmentInfo.item.id,
                        order: index,
                        select: {
                            viewModel.selectTimelineItem(
                                adjustmentInfo.item.id,
                                trackID: adjustmentInfo.trackID
                            )
                        }
                    )
                }
            }

        let hitLayers = candidates.map {
            PreviewHitLayer(id: $0.itemID, stackOrder: $0.order)
        }
        guard let topmostID = PreviewHitResolver.topmost(in: hitLayers),
            let best = candidates.first(where: { $0.itemID == topmostID })
        else { return }

        EditorHaptics.selection()
        best.select()
    }

    private func handleSelectionBoxTap(_ pointInRoot: CGPoint) {
        selectPreviewItem(
            at: CGPoint(
                x: pointInRoot.x - canvasFrame.minX,
                y: pointInRoot.y - canvasFrame.minY
            )
        )
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
                applyPositionSnapFeedback(snapped)
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
                    ? PreviewCanvasScaleSnap(
                        scale: start.scale.baseValue.x,
                        lockX: nil,
                        lockY: nil
                    )
                    : snappedScale(
                        scale: start.scale.baseValue.x * value,
                        clip: clip,
                        selectedClipID: clip.id
                    )
                applySnappedScaleFeedback(snapped)
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
                    ? PreviewRotationSnapResult(
                        degrees: start.rotationDegrees.baseValue,
                        guideDegrees: nil
                    )
                    : snappedRotation(start.rotationDegrees.baseValue + value.degrees)
                applyRotationSnapFeedback(snapped)
                updateLiveTransform {
                    $0.rotationDegrees.baseValue = snapped.degrees
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
                applyPositionSnapFeedback(snapped)
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
                    ? PreviewCanvasScaleSnap(
                        scale: start.scale.baseValue.x,
                        lockX: nil,
                        lockY: nil
                    )
                    : snappedScale(
                        scale: start.scale.baseValue.x * value,
                        text: text,
                        selectedClipID: text.id
                    )
                applySnappedScaleFeedback(snapped)
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
                    ? PreviewRotationSnapResult(
                        degrees: start.rotationDegrees.baseValue,
                        guideDegrees: nil
                    )
                    : snappedRotation(start.rotationDegrees.baseValue + value.degrees)
                applyRotationSnapFeedback(snapped)
                updateLiveTransform {
                    $0.rotationDegrees.baseValue = snapped.degrees
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.rotation, itemID: text.id)
            }
    }

    private func dragGesture(
        for adjustment: AdjustmentTimelineItem,
        frame: PreviewClipFrame
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard activatePreviewGesture(.drag, for: adjustment) else { return }
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
                    selectedClipID: adjustment.id
                )
                applyPositionSnapFeedback(snapped)
                updateLiveTransform {
                    $0.positionX.baseValue = snapped.positionX
                    $0.positionY.baseValue = snapped.positionY
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.drag, itemID: adjustment.id)
            }
    }

    private func scaleGesture(for adjustment: AdjustmentTimelineItem) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.magnification, for: adjustment) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value - 1) > 0.001 || editedTransformComponents.contains(.scale)
                else { return }
                editedTransformComponents.insert(.scale)
                let snapped =
                    abs(value - 1) <= 0.001
                    ? PreviewCanvasScaleSnap(
                        scale: start.scale.baseValue.x,
                        lockX: nil,
                        lockY: nil
                    )
                    : snappedScale(
                        scale: start.scale.baseValue.x * value,
                        adjustment: adjustment,
                        selectedClipID: adjustment.id
                    )
                applySnappedScaleFeedback(snapped)
                updateLiveTransform {
                    $0.scale.baseValue = proportionalScale(
                        x: snapped.scale,
                        from: start.scale.baseValue
                    )
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.magnification, itemID: adjustment.id)
            }
    }

    private func rotationGesture(for adjustment: AdjustmentTimelineItem) -> some Gesture {
        RotationGesture()
            .onChanged { value in
                guard activatePreviewGesture(.rotation, for: adjustment) else { return }
                guard let start = dragStartTransform else { return }
                guard abs(value.degrees) > 0.05 || editedTransformComponents.contains(.rotation)
                else { return }
                editedTransformComponents.insert(.rotation)
                let snapped =
                    abs(value.degrees) <= 0.05
                    ? PreviewRotationSnapResult(
                        degrees: start.rotationDegrees.baseValue,
                        guideDegrees: nil
                    )
                    : snappedRotation(start.rotationDegrees.baseValue + value.degrees)
                applyRotationSnapFeedback(snapped)
                updateLiveTransform {
                    $0.rotationDegrees.baseValue = snapped.degrees
                }
            }
            .onEnded { _ in
                finishPreviewGesture(.rotation, itemID: adjustment.id)
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
            transform.rotationDegrees.baseValue = rotation.degrees
        }

        let stableScaleFactor = max(scaleFactor, Self.minimumCombinedHandleScaleFactor)
        let shouldUpdateScale = abs(stableScaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        guard rotation != nil || shouldUpdateScale else { return }

        if shouldUpdateScale {
            editedTransformComponents.insert(.scale)
            let snapped = snappedScale(
                scale: start.scale.baseValue.x * stableScaleFactor,
                clip: clip,
                selectedClipID: clip.id,
                transform: transform
            )
            applySnappedScaleFeedback(snapped)
            transform.scale.baseValue = proportionalScale(
                x: snapped.scale,
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
            transform.rotationDegrees.baseValue = rotation.degrees
        }

        let stableScaleFactor = max(scaleFactor, Self.minimumCombinedHandleScaleFactor)
        let shouldUpdateScale = abs(stableScaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        guard rotation != nil || shouldUpdateScale else { return }

        if shouldUpdateScale {
            editedTransformComponents.insert(.scale)
            let snapped = snappedScale(
                scale: start.scale.baseValue.x * stableScaleFactor,
                text: text,
                selectedClipID: text.id,
                transform: transform
            )
            applySnappedScaleFeedback(snapped)
            transform.scale.baseValue = proportionalScale(
                x: snapped.scale,
                from: start.scale.baseValue
            )
        }

        setLiveTransform(transform)
    }

    private func updateCombinedHandle(
        scaleFactor: Double,
        rotationDelta: Double,
        for adjustment: AdjustmentTimelineItem
    ) {
        guard activatePreviewGesture(.combinedHandle, for: adjustment) else { return }
        guard let start = dragStartTransform else { return }

        var transform = liveTransform ?? start
        let rotation = combinedRotation(rotationDelta, from: start)
        if let rotation {
            transform.rotationDegrees.baseValue = rotation.degrees
        }

        let stableScaleFactor = max(scaleFactor, Self.minimumCombinedHandleScaleFactor)
        let shouldUpdateScale =
            abs(stableScaleFactor - 1) > 0.001
            || editedTransformComponents.contains(.scale)
        guard rotation != nil || shouldUpdateScale else { return }

        if shouldUpdateScale {
            editedTransformComponents.insert(.scale)
            let snapped = snappedScale(
                scale: start.scale.baseValue.x * stableScaleFactor,
                adjustment: adjustment,
                selectedClipID: adjustment.id,
                transform: transform
            )
            applySnappedScaleFeedback(snapped)
            transform.scale.baseValue = proportionalScale(
                x: snapped.scale,
                from: start.scale.baseValue
            )
        }

        setLiveTransform(transform)
    }

    private func combinedRotation(
        _ deltaDegrees: Double,
        from start: ClipTransform
    ) -> PreviewRotationSnapResult? {
        guard abs(deltaDegrees) > 0.05 || editedTransformComponents.contains(.rotation) else {
            return nil
        }
        editedTransformComponents.insert(.rotation)
        let snapped =
            abs(deltaDegrees) <= 0.05
            ? PreviewRotationSnapResult(
                degrees: start.rotationDegrees.baseValue,
                guideDegrees: nil
            )
            : snappedRotation(start.rotationDegrees.baseValue + deltaDegrees)
        applyRotationSnapFeedback(snapped)
        return snapped
    }

    private func applyPositionSnapFeedback(_ snapped: PreviewCanvasPositionSnap) {
        snapInteractionState.positionLockX = snapped.lockX
        snapInteractionState.positionLockY = snapped.lockY
        snapGuideX = snapped.guideX
        snapGuideY = snapped.guideY
        updatePreviewSnapHaptic(
            kind: "position",
            snapped: snapped.guideX != nil || snapped.guideY != nil,
            value: snapFeedbackValue(x: snapped.guideX, y: snapped.guideY)
        )
    }

    private func applySnappedScaleFeedback(_ snapped: PreviewCanvasScaleSnap) {
        snapInteractionState.scaleLockX = snapped.lockX
        snapInteractionState.scaleLockY = snapped.lockY
        snapGuideX = snapped.guideX
        snapGuideY = snapped.guideY
        updatePreviewSnapHaptic(
            kind: "scale",
            snapped: snapped.guideX != nil || snapped.guideY != nil,
            value: snapFeedbackValue(x: snapped.guideX, y: snapped.guideY)
        )
    }

    private func applyRotationSnapFeedback(_ snapped: PreviewRotationSnapResult) {
        snapInteractionState.rotationGuideDegrees = snapped.guideDegrees
        snapRotationGuideDegrees = snapped.guideDegrees
        updatePreviewSnapHaptic(
            kind: "rotation",
            snapped: snapped.didSnap,
            value: String(format: "%.2f", snapped.guideDegrees ?? snapped.degrees)
        )
    }

    private func snapFeedbackValue(x: CGFloat?, y: CGFloat?) -> String {
        "\(Int((x ?? -1).rounded())):\(Int((y ?? -1).rounded()))"
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
    ) -> PreviewCanvasPositionSnap {
        let proposedCenter = geometryMapper.center(
            positionX: positionX,
            positionY: positionY,
            displayOffset: displayOffset
        )
        let snapped = PreviewSnapEngine.position(
            center: proposedCenter,
            anchorOffsets: rotatedAnchorOffsets(
                size: frame.rect.size,
                rotationDegrees: frame.rotationDegrees
            ),
            targets: resolvedSnapTargets(excluding: selectedClipID),
            lockedX: snapInteractionState.positionLockX,
            lockedY: snapInteractionState.positionLockY
        )

        let normalized = geometryMapper.normalizedPosition(
            from: snapped.center,
            displayOffset: displayOffset
        )
        return PreviewCanvasPositionSnap(
            positionX: normalized.x,
            positionY: normalized.y,
            lockX: snapped.lockX,
            lockY: snapped.lockY
        )
    }

    private func snappedScale(
        scale: Double,
        clip: TimelineClip,
        selectedClipID: UUID,
        transform overrideTransform: ClipTransform? = nil
    ) -> PreviewCanvasScaleSnap {
        guard let baseSize = previewBaseSize(for: clip) else {
            return PreviewCanvasScaleSnap(
                scale: min(max(scale, Self.minimumScaleSnap), 100),
                lockX: nil,
                lockY: nil
            )
        }

        let proposedScale = CGFloat(min(max(scale, Self.minimumScaleSnap), 100))
        let transform = overrideTransform ?? liveTransform ?? clip.transform
        let center = previewCenter(for: clip, transform: transform)
        let localTime = localTime(for: clip)
        let currentScale = transform.scale.value(at: localTime)
        let yToXRatio = max(currentScale.y, 0.000_001) / max(currentScale.x, 0.000_001)
        let scaleBasis = CGSize(
            width: baseSize.width,
            height: baseSize.height * CGFloat(yToXRatio)
        )
        let snapped = PreviewSnapEngine.scale(
            center: center,
            baseAnchorOffsets: rotatedAnchorOffsets(
                size: scaleBasis,
                rotationDegrees: transform.rotationDegrees.value(at: localTime)
            ),
            proposedScale: proposedScale,
            targets: resolvedSnapTargets(excluding: selectedClipID),
            lockedX: snapInteractionState.scaleLockX,
            lockedY: snapInteractionState.scaleLockY,
            minimumScale: Self.minimumScaleSnap,
            maximumScale: 100,
            maximumSnapRatio: Self.maximumScaleSnapRatio
        )
        return PreviewCanvasScaleSnap(
            scale: Double(snapped.scale),
            lockX: snapped.lockX,
            lockY: snapped.lockY
        )
    }

    private func snappedScale(
        scale: Double,
        text: TextTimelineItem,
        selectedClipID: UUID,
        transform overrideTransform: ClipTransform? = nil
    ) -> PreviewCanvasScaleSnap {
        guard let baseSize = previewBaseSize(for: text) else {
            return PreviewCanvasScaleSnap(
                scale: min(max(scale, Self.minimumScaleSnap), 100),
                lockX: nil,
                lockY: nil
            )
        }

        let animationScale = max(textAnimationSample(for: text).scale, 0.001)
        let proposedDisplayScale = CGFloat(min(max(scale * animationScale, Self.minimumScaleSnap), 100))
        let transform = overrideTransform ?? liveTransform ?? text.visuals.transform
        let center = previewCenter(for: text, transform: transform)
        let currentScale = transform.scale.value(at: localTime(for: text))
        let yToXRatio = max(currentScale.y, 0.000_001) / max(currentScale.x, 0.000_001)
        let scaleBasis = CGSize(
            width: baseSize.width,
            height: baseSize.height * CGFloat(yToXRatio)
        )
        let snapped = PreviewSnapEngine.scale(
            center: center,
            baseAnchorOffsets: rotatedAnchorOffsets(
                size: scaleBasis,
                rotationDegrees: previewRotationDegrees(for: text, transform: transform)
            ),
            proposedScale: proposedDisplayScale,
            targets: resolvedSnapTargets(excluding: selectedClipID),
            lockedX: snapInteractionState.scaleLockX,
            lockedY: snapInteractionState.scaleLockY,
            minimumScale: Self.minimumScaleSnap,
            maximumScale: 100,
            maximumSnapRatio: Self.maximumScaleSnapRatio
        )
        return PreviewCanvasScaleSnap(
            scale: min(max(Double(snapped.scale) / animationScale, Self.minimumScaleSnap), 100),
            lockX: snapped.lockX,
            lockY: snapped.lockY
        )
    }

    private func snappedScale(
        scale: Double,
        adjustment: AdjustmentTimelineItem,
        selectedClipID: UUID,
        transform overrideTransform: ClipTransform? = nil
    ) -> PreviewCanvasScaleSnap {
        let proposedScale = CGFloat(min(max(scale, Self.minimumScaleSnap), 100))
        let transform = overrideTransform ?? liveTransform ?? adjustment.visuals.transform
        let localTime = localTime(for: adjustment)
        let currentScale = transform.scale.value(at: localTime)
        let yToXRatio = max(currentScale.y, 0.000_001) / max(currentScale.x, 0.000_001)
        let scaleBasis = CGSize(
            width: canvasRect.width,
            height: canvasRect.height * CGFloat(yToXRatio)
        )
        let snapped = PreviewSnapEngine.scale(
            center: previewCenter(for: adjustment, transform: transform),
            baseAnchorOffsets: rotatedAnchorOffsets(
                size: scaleBasis,
                rotationDegrees: transform.rotationDegrees.value(at: localTime)
            ),
            proposedScale: proposedScale,
            targets: resolvedSnapTargets(excluding: selectedClipID),
            lockedX: snapInteractionState.scaleLockX,
            lockedY: snapInteractionState.scaleLockY,
            minimumScale: Self.minimumScaleSnap,
            maximumScale: 100,
            maximumSnapRatio: Self.maximumScaleSnapRatio
        )
        return PreviewCanvasScaleSnap(
            scale: Double(snapped.scale),
            lockX: snapped.lockX,
            lockY: snapped.lockY
        )
    }

    private func snappedRotation(_ degrees: Double) -> PreviewRotationSnapResult {
        PreviewSnapEngine.rotation(
            degrees: degrees,
            lockedGuideDegrees: snapInteractionState.rotationGuideDegrees
        )
    }

    private func resolvedSnapTargets(excluding selectedClipID: UUID) -> PreviewSnapTargets {
        if interactionClipID == selectedClipID, !interactionSnapTargets.isEmpty {
            return interactionSnapTargets
        }
        return makeSnapTargets(excluding: selectedClipID)
    }

    private func makeSnapTargets(excluding selectedClipID: UUID) -> PreviewSnapTargets {
        var xTargets = [canvasRect.minX, canvasRect.midX, canvasRect.maxX]
        var yTargets = [canvasRect.minY, canvasRect.midY, canvasRect.maxY]

        for info in activeVisualInfos where info.id != selectedClipID {
            let frame: PreviewClipFrame?
            switch info {
            case .clip(let clipInfo):
                frame = previewFrame(for: clipInfo)
            case .text(let textInfo):
                frame = previewFrame(for: textInfo.item)
            case .adjustment(let adjustmentInfo):
                frame = previewFrame(for: adjustmentInfo.item)
            }
            guard let frame else { continue }
            let anchors = rotatedAnchors(for: frame)
            xTargets.append(contentsOf: anchors.map(\.x))
            yTargets.append(contentsOf: anchors.map(\.y))
        }

        return PreviewSnapTargets(x: xTargets, y: yTargets)
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
        previewFrame(
            for: clip,
            transform: transform,
            localTime: localTime(for: clip)
        )
    }

    private func previewFrame(for info: PreviewClipInfo) -> PreviewClipFrame? {
        previewFrame(
            for: info.clip,
            transform: nil,
            localTime: min(
                max(playbackState.currentTime - info.clip.timelineStart, 0),
                info.timelineDuration
            )
        )
    }

    private func previewFrame(
        for clip: TimelineClip,
        transform: ClipTransform?,
        localTime: Double
    ) -> PreviewClipFrame? {
        let transform = transform ?? clip.transform
        if let shape = clip.shape {
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

    private func previewFrame(
        for adjustment: AdjustmentTimelineItem,
        transform: ClipTransform? = nil
    ) -> PreviewClipFrame {
        geometryMapper.adjustmentFrame(
            transform: transform ?? adjustment.visuals.transform,
            at: localTime(for: adjustment)
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
        let geometry = textGeometryRenderer.cachedGeometry(
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

    private func previewCenter(
        for adjustment: AdjustmentTimelineItem,
        transform: ClipTransform? = nil
    ) -> CGPoint {
        let transform = transform ?? adjustment.visuals.transform
        let localTime = localTime(for: adjustment)
        return geometryMapper.center(
            positionX: transform.positionX.value(at: localTime),
            positionY: transform.positionY.value(at: localTime)
        )
    }

    private func localTime(for clip: TimelineClip) -> Double {
        min(
            max(playbackState.currentTime - clip.timelineStart, 0),
            viewModel.timelinePlacementDuration(for: clip)
        )
    }

    private func localTime(for text: TextTimelineItem) -> Double {
        min(max(playbackState.currentTime - text.timelineStart, 0), text.duration)
    }

    private func localTime(for adjustment: AdjustmentTimelineItem) -> Double {
        min(max(playbackState.currentTime - adjustment.timelineStart, 0), adjustment.duration)
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
        let geometry = textGeometryRenderer.cachedGeometry(
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

    private func activatePreviewGesture(
        _ gesture: PreviewTransformGesture,
        for adjustment: AdjustmentTimelineItem
    ) -> Bool {
        guard interactionClipID == nil || interactionClipID == adjustment.id else {
            return false
        }
        if dragStartTransform == nil {
            beginPreviewInteraction(for: adjustment)
        }
        prepareForTwoFingerTransformIfNeeded(gesture)
        activeTransformGestures.insert(gesture)
        return interactionClipID == adjustment.id && dragStartTransform != nil
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
            if let shape = clip.shape {
                let token = PreviewRasterRequestToken(
                    itemID: clip.id,
                    assetKey: assetKey,
                    loadID: UUID()
                )
                livePreviewLoadID = token.loadID
                let localTime = localTime(for: clip)
                let transform = clip.transform.resolved(at: localTime)
                let renderSize = viewModel.project.renderSettings.size
                let timelineTime = playbackState.currentTime
                let project = viewModel.project
                async let backgroundImage = try? viewModel.renderService.makePreviewBackgroundImage(
                    for: project,
                    at: timelineTime,
                    excluding: clip.id
                )
                async let rasterImage = shapeRasterizer.image(
                    for: shape,
                    at: localTime,
                    transform: transform,
                    renderSize: renderSize,
                    maximumTextureDimension: Self.interactionStartTextureDimension
                )
                let (background, image) = await (backgroundImage, rasterImage)
                guard !Task.isCancelled,
                    PreviewRasterDeliveryPolicy.shouldApply(
                        token,
                        currentLoadID: livePreviewLoadID,
                        currentSelectedItemID: viewModel.selectedTimelineItemID,
                        currentAssetKey: livePreviewPreparationKey,
                        isTransforming: isTransforming
                    )
                else { return }
                livePreviewImage = image
                liveTextPreviewImage = nil
                liveBackgroundImage = background
                livePreviewAssetKey = assetKey
                return
            }

            let resolved = clip.transform.resolved(at: localTime(for: clip))
            loadLivePreviewAssets(
                for: clip,
                transform: resolved,
                assetKey: assetKey
            )
            return
        }

        if let text = selectedTextItem {
            let token = PreviewRasterRequestToken(
                itemID: text.id,
                assetKey: assetKey,
                loadID: UUID()
            )
            livePreviewLoadID = token.loadID
            let localTime = localTime(for: text)
            let resolved = text.visuals.transform.resolved(at: localTime)
            let renderSize = viewModel.project.renderSettings.size
            let glyphReveal = textAnimationSample(for: text).glyphReveal
            let timelineTime = playbackState.currentTime
            let project = viewModel.project
            async let backgroundImage = try? viewModel.renderService.makePreviewBackgroundImage(
                for: project,
                at: timelineTime,
                excluding: text.id
            )
            async let rasterImage = textRasterizer.image(
                for: text,
                renderSize: renderSize,
                transform: resolved,
                localTime: localTime,
                glyphReveal: glyphReveal,
                maximumTextureDimension: Self.interactionStartTextureDimension
            )
            let (background, image) = await (backgroundImage, rasterImage)
            guard !Task.isCancelled,
                PreviewRasterDeliveryPolicy.shouldApply(
                    token,
                    currentLoadID: livePreviewLoadID,
                    currentSelectedItemID: viewModel.selectedTimelineItemID,
                    currentAssetKey: livePreviewPreparationKey,
                    isTransforming: isTransforming
                )
            else { return }
            livePreviewImage = nil
            liveTextPreviewImage = image
            liveBackgroundImage = background
            livePreviewAssetKey = assetKey
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

    private func baselineTransform(for adjustment: AdjustmentTimelineItem) -> ClipTransform {
        if interactionClipID == adjustment.id,
            livePreviewCommitRevision != nil,
            let liveTransform
        {
            return liveTransform
        }
        return adjustment.visuals.transform.resolved(at: localTime(for: adjustment))
    }

    private func hasUsableLiveProxy(
        for itemID: UUID,
        assetKey: String,
        isText: Bool
    ) -> Bool {
        guard canUseRasterProxy(for: itemID), liveBackgroundImage != nil else {
            return false
        }
        let hasMatchingPreparedProxy =
            livePreviewAssetKey == assetKey
            && (isText ? liveTextPreviewImage != nil : livePreviewImage != nil)
        let hasCommitHandoffProxy =
            interactionClipID == itemID
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
        isCommitPresenting = false
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
        prepareInteractionSnapping(excluding: clip.id)
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
    }

    private func beginPreviewInteraction(for text: TextTimelineItem) {
        let resolved = baselineTransform(for: text)
        let assetKey = livePreviewAssetKey(for: text.id)
        let hasPreparedProxy = hasUsableLiveProxy(for: text.id, assetKey: assetKey, isText: true)
        livePreviewCommitRevision = nil
        livePreviewLoadID = UUID()
        isCommitPresenting = false
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
        prepareInteractionSnapping(excluding: text.id)
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
    }

    private func beginPreviewInteraction(for adjustment: AdjustmentTimelineItem) {
        let resolved = baselineTransform(for: adjustment)
        livePreviewCommitRevision = nil
        livePreviewLoadID = UUID()
        isCommitPresenting = false
        isLivePreviewSourceHidden = false
        viewModel.beginLivePreviewInteraction()
        dragStartTransform = resolved
        liveTransform = resolved
        livePreviewImage = nil
        liveTextPreviewImage = nil
        liveBackgroundImage = nil
        livePreviewAssetKey = nil
        interactionClipID = adjustment.id
        prepareInteractionSnapping(excluding: adjustment.id)
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        isTransforming = true
        EditorHaptics.dragStart()
        viewModel.beginInteractiveEdit()
        viewModel.updateLivePreviewTransform(
            resolved,
            for: adjustment.id,
            hidden: false,
            immediate: true
        )
    }

    private func prepareInteractionSnapping(excluding itemID: UUID) {
        interactionSnapTargets = makeSnapTargets(excluding: itemID)
        snapInteractionState.reset()
        snapGuideX = nil
        snapGuideY = nil
        snapRotationGuideDegrees = nil
        previewSnapKeys.removeAll(keepingCapacity: true)
    }

    private func loadLivePreviewAssets(
        for clip: TimelineClip,
        transform: ClipTransform,
        assetKey: String
    ) {
        guard clip.shape == nil,
            let media = viewModel.project.mediaDescriptor(for: clip)
        else { return }

        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = playbackState.currentTime
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

    private func updateLiveTransform(_ update: (inout ClipTransform) -> Void) {
        guard var transform = liveTransform else { return }
        update(&transform)
        setLiveTransform(transform)
    }

    private func setLiveTransform(_ transform: ClipTransform) {
        liveTransform = transform
        if let interactionClipID {
            viewModel.updateLivePreviewTransform(transform, for: interactionClipID)
        }
    }

    private func applyLiveTransformToProject(_ transform: ClipTransform) {
        if selectedAdjustmentItem != nil {
            viewModel.setSelectedAdjustmentTransform(
                positionX: editedTransformComponents.contains(.position)
                    ? transform.positionX.baseValue : nil,
                positionY: editedTransformComponents.contains(.position)
                    ? transform.positionY.baseValue : nil,
                scale: editedTransformComponents.contains(.scale)
                    ? transform.scale.baseValue : nil,
                rotationDegrees: editedTransformComponents.contains(.rotation)
                    ? transform.rotationDegrees.baseValue : nil,
                interactive: true
            )
            return
        }
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
        snapRotationGuideDegrees = nil
        snapInteractionState.reset()
        interactionSnapTargets = .empty
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
        viewModel.prepareLivePreviewCommitPresentation(for: committedItemID)
        isTransforming = false
        isCommitPresenting = true
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
        interactionClipID = nil
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        snapGuideX = nil
        snapGuideY = nil
        snapRotationGuideDegrees = nil
        snapInteractionState.reset()
        interactionSnapTargets = .empty
        previewSnapKeys = [:]
        isTransforming = false
        isCommitPresenting = false
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

private struct PreviewSnapGuideOverlay: View {
    let canvasRect: CGRect
    let guideX: CGFloat?
    let guideY: CGFloat?
    let rotationDegrees: Double?
    let rotationCenter: CGPoint?

    var body: some View {
        ZStack {
            if let guideX {
                guideLine
                    .frame(width: 1.5, height: canvasRect.height)
                    .position(x: guideX, y: canvasRect.midY)
            }

            if let guideY {
                guideLine
                    .frame(width: canvasRect.width, height: 1.5)
                    .position(x: canvasRect.midX, y: guideY)
            }

            if let rotationDegrees, let rotationCenter {
                guideLine
                    .frame(width: hypot(canvasRect.width, canvasRect.height) * 1.25, height: 1.5)
                    .rotationEffect(.degrees(rotationDegrees))
                    .position(x: rotationCenter.x, y: rotationCenter.y)

                Circle()
                    .fill(MotionaryTheme.accent)
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                    }
                    .position(x: rotationCenter.x, y: rotationCenter.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var guideLine: some View {
        Rectangle()
            .fill(MotionaryTheme.accent)
            .shadow(color: Color.black.opacity(0.55), radius: 1, x: 0, y: 0)
    }
}

enum PreviewSelectionStyle: Equatable {
    case content
    case adjustment
}

private struct PreviewSelectionHitShape: Shape {
    let style: PreviewSelectionStyle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        return path
    }
}

struct PreviewSelectionBox: View {
    let frame: PreviewClipFrame
    var style: PreviewSelectionStyle = .content
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onTap: (CGPoint) -> Void
    let onTransformChanged: (_ scaleFactor: Double, _ rotationDelta: Double) -> Void
    let onTransformEnded: () -> Void

    @State private var combinedHandleState: CombinedHandleInteractionState?

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(
                    PreviewSelectionHitShape(style: style),
                    eoFill: true
                )
                .gesture(
                    SpatialTapGesture(
                        coordinateSpace: .named("PreviewTransformCanvasRoot")
                    )
                    .onEnded { value in
                        onTap(value.location)
                    }
                )

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(
                    MotionaryTheme.accent,
                    style: StrokeStyle(
                        lineWidth: 1.5
                    )
                )
                .allowsHitTesting(false)

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
        .contentShape(
            PreviewSelectionHitShape(style: style),
            eoFill: true
        )
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

private func previewRasterScale(
    transform: ClipTransform,
    logicalSize: CGSize,
    renderSize: CGSize,
    maximumTextureDimension: Int
) -> CGSize {
    let scale = transform.scale.baseValue
    return GeneratedRasterPolicy.generatedLayerRasterScale(
        transformScale: CGSize(
            width: max(abs(CGFloat(scale.x)), 1),
            height: max(abs(CGFloat(scale.y)), 1)
        ),
        qualityScale: 1,
        logicalSize: logicalSize,
        renderSize: renderSize,
        maximumTextureDimension: maximumTextureDimension
    )
}

private actor PreviewTextRasterizer {
    private var renderer: TextLayerRenderer?
    private var context: CIContext?

    func image(
        for item: TextTimelineItem,
        renderSize: CGSize,
        transform: ClipTransform,
        localTime: Double,
        glyphReveal: Double,
        maximumTextureDimension: Int
    ) -> UIImage? {
        let renderer: TextLayerRenderer
        if let existing = self.renderer {
            renderer = existing
        } else {
            let created = TextLayerRenderer()
            self.renderer = created
            renderer = created
        }
        let context: CIContext
        if let existing = self.context {
            context = existing
        } else {
            let created = CIContext(options: [.cacheIntermediates: false])
            self.context = created
            context = created
        }
        let geometry = renderer.cachedGeometry(
            for: item,
            renderSize: renderSize,
            renderScale: 1,
            at: localTime
        )
        let result = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 1,
            rasterScale: previewRasterScale(
                transform: transform,
                logicalSize: geometry.layerSize,
                renderSize: renderSize,
                maximumTextureDimension: maximumTextureDimension
            ),
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

private actor PreviewShapeRasterizer {
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

    private var renderer: MetalFrameRenderer?
    private var context: CIContext?

    func image(
        for shape: ClipShape,
        at localTime: Double,
        transform: ClipTransform,
        renderSize: CGSize,
        maximumTextureDimension: Int
    ) -> UIImage? {
        if renderer == nil {
            renderer = try? MetalFrameRenderer()
        }
        if context == nil {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        let logicalSize = CGSize(
            width: max(CGFloat(shape.width.value(at: localTime)), 1),
            height: max(CGFloat(shape.height.value(at: localTime)), 1)
        )
        let layout = ShapeRasterLayout(
            shape: shape,
            at: localTime,
            logicalRenderScale: 1,
            rasterScale: previewRasterScale(
                transform: transform,
                logicalSize: logicalSize,
                renderSize: renderSize,
                maximumTextureDimension: maximumTextureDimension
            )
        )
        let key = cacheKey(shape: shape, layout: layout, localTime: localTime)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }

        guard let renderer,
            let context,
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
