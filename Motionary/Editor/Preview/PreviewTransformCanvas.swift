// Preview clip geometry, selection, snapping, and direct manipulation.

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

private struct SelectedTextBackgroundKey: Equatable {
    let itemID: UUID
    let previewRevision: Int
    let frameTime: Double
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
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let canvasFrame: CGRect

    @State private var dragStartTransform: ClipTransform?
    @State private var liveTransform: ClipTransform?
    @State private var livePreviewImage: UIImage?
    @State private var liveTextPreviewImage: UIImage?
    @State private var liveBackgroundImage: UIImage?
    @State private var livePreviewLoadID: UUID?
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
    @State private var isAwaitingPreviewCommit = false
    @State private var inlineEditingTextID: UUID?
    @State private var inlineTextDraft = ""
    @State private var isInlineTextEditorFocused = false
    @State private var textRasterizer = PreviewTextRasterizer()
    @State private var selectedTextBackgroundImage: UIImage?

    init(viewModel: EditorViewModel, canvasFrame: CGRect) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
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
                            .fill(Color.white.opacity(0.001))
                            .frame(width: frame.rect.width, height: frame.rect.height)
                            .rotationEffect(.degrees(frame.rotationDegrees))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                            .onTapGesture {
                                EditorHaptics.selection()
                                viewModel.selectClip(clipInfo.clip.id, trackID: clipInfo.trackID)
                            }
                    }

                case .text(let textInfo):
                    if let frame = previewFrame(for: textInfo.item) {
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .frame(
                                width: max(frame.rect.width, 44),
                                height: max(frame.rect.height, 44)
                            )
                            .rotationEffect(.degrees(frame.rotationDegrees))
                            .position(x: frame.rect.midX, y: frame.rect.midY)
                            .accessibilityLabel("Text layer \(textInfo.item.name)")
                            .highPriorityGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        viewModel.selectTimelineItem(
                                            textInfo.item.id,
                                            trackID: textInfo.trackID
                                        )
                                        beginInlineEditing(for: textInfo.item)
                                    }
                            )
                            .onTapGesture {
                                EditorHaptics.selection()
                                viewModel.selectTimelineItem(
                                    textInfo.item.id,
                                    trackID: textInfo.trackID
                                )
                            }
                    }
                }
            }

            if (isTransforming || inlineEditingTextID != nil),
                let liveBackgroundImage
            {
                Image(uiImage: liveBackgroundImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .clipped()
                    .allowsHitTesting(false)
            }

            if showsLiveTextPreview,
                let selectedTextBackgroundImage
            {
                Image(uiImage: selectedTextBackgroundImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .clipped()
                    .allowsHitTesting(false)
            }

            if showsLiveTextPreview,
                let text = selectedTextItem,
                let image = renderPreviewImage(for: text),
                let frame = previewFrame(for: text)
            {
                let transform = text.visuals.transform
                LiveTransformTextProxy(
                    image: image,
                    frame: frame,
                    opacity: transform.opacity.value(at: localTime(for: text))
                        * textAnimationSample(for: text).opacity,
                    clipReveal: textAnimationSample(for: text).clipReveal,
                    isFlippedHorizontally: transform.isFlippedHorizontally,
                    isFlippedVertically: transform.isFlippedVertically
                )
                .allowsHitTesting(false)
            }

            if isTransforming,
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
            }

            if isTransforming,
                let text = selectedTextItem,
                let transform = liveTransform,
                let image = liveTextPreviewImage,
                let frame = previewFrame(for: text, transform: transform)
            {
                LiveTransformTextProxy(
                    image: image,
                    frame: frame,
                    opacity: transform.opacity.baseValue * textAnimationSample(for: text).opacity,
                    clipReveal: textAnimationSample(for: text).clipReveal,
                    isFlippedHorizontally: transform.isFlippedHorizontally,
                    isFlippedVertically: transform.isFlippedVertically
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

            }
            .frame(width: canvasRect.width, height: canvasRect.height)
            .clipped()
            .contentShape(Rectangle())
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
                if inlineEditingTextID == text.id {
                    InlineTextEditingOverlay(
                        item: text,
                        draft: $inlineTextDraft,
                        isFocused: $isInlineTextEditorFocused,
                        placement: inlineTextPlacement(for: text),
                        onTextChange: { value in
                            updateInlineText(value, itemID: text.id)
                        },
                        onEditingEnd: finishInlineEditing
                    )
                    .id(text.id)
                } else {
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
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .onEnded { beginInlineEditing(for: text) }
                        )
                        .id(text.id)
                }
            }
        }
        .onChange(of: viewModel.selectedClipID) { _, selectedID in
            if let inlineEditingTextID, inlineEditingTextID != selectedID {
                finishInlineEditing()
            }
            if isAwaitingPreviewCommit {
                clearLivePreview()
            } else {
                resetPreviewInteraction(finishEdit: isTransforming)
            }
        }
        .onChange(of: viewModel.previewContentRevision) { _, _ in
            guard isAwaitingPreviewCommit else { return }
            clearLivePreview()
        }
        .onDisappear {
            finishInlineEditing()
            if isAwaitingPreviewCommit {
                clearLivePreview()
            } else {
                resetPreviewInteraction(finishEdit: isTransforming)
            }
        }
        .task(id: selectedTextBackgroundKey) {
            await loadSelectedTextBackground()
        }
    }

    private var canvasRect: CGRect {
        CGRect(origin: .zero, size: canvasFrame.size)
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

    private var showsLiveTextPreview: Bool {
        guard inlineEditingTextID == nil,
            !isTransforming,
            !playbackState.isScrubbing,
            !playbackState.isPlaying,
            let selectedTextItem
        else { return false }
        return viewModel.liveTextPreviewID == selectedTextItem.id
    }

    private var selectedTextBackgroundKey: SelectedTextBackgroundKey? {
        guard showsLiveTextPreview, let selectedTextItem else { return nil }
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let frameTime = (playbackState.currentTime * frameRate).rounded() / frameRate
        return SelectedTextBackgroundKey(
            itemID: selectedTextItem.id,
            previewRevision: viewModel.previewContentRevision,
            frameTime: frameTime
        )
    }

    @MainActor
    private func loadSelectedTextBackground() async {
        guard let key = selectedTextBackgroundKey else {
            selectedTextBackgroundImage = nil
            return
        }
        let image = try? await viewModel.renderService.makePreviewBackgroundImage(
            for: viewModel.project,
            at: key.frameTime,
            excluding: key.itemID
        )
        guard !Task.isCancelled, selectedTextBackgroundKey == key else { return }
        selectedTextBackgroundImage = image
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
                    : snappedRotation(start.rotationDegrees.baseValue - value.degrees)
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
                    : snappedRotation(start.rotationDegrees.baseValue - value.degrees)
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

        updateCombinedRotation(rotationDelta, from: start)
        guard abs(scaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        else { return }

        editedTransformComponents.insert(.scale)
        let snapped =
            abs(scaleFactor - 1) <= 0.001
            ? (scale: start.scale.baseValue.x, guideX: nil, guideY: nil)
            : snappedScale(
                scale: start.scale.baseValue.x * scaleFactor,
                clip: clip,
                selectedClipID: clip.id
            )
        applySnappedScale(snapped, from: start.scale.baseValue)
    }

    private func updateCombinedHandle(
        scaleFactor: Double,
        rotationDelta: Double,
        for text: TextTimelineItem
    ) {
        guard activatePreviewGesture(.combinedHandle, for: text) else { return }
        guard let start = dragStartTransform else { return }

        updateCombinedRotation(rotationDelta, from: start)
        guard abs(scaleFactor - 1) > 0.001 || editedTransformComponents.contains(.scale)
        else { return }

        editedTransformComponents.insert(.scale)
        let snapped =
            abs(scaleFactor - 1) <= 0.001
            ? (scale: start.scale.baseValue.x, guideX: nil, guideY: nil)
            : snappedScale(
                scale: start.scale.baseValue.x * scaleFactor,
                text: text,
                selectedClipID: text.id
            )
        applySnappedScale(snapped, from: start.scale.baseValue)
    }

    private func updateCombinedRotation(_ deltaDegrees: Double, from start: ClipTransform) {
        guard abs(deltaDegrees) > 0.05 || editedTransformComponents.contains(.rotation) else {
            return
        }
        editedTransformComponents.insert(.rotation)
        let snapped =
            abs(deltaDegrees) <= 0.05
            ? (rotation: start.rotationDegrees.baseValue, snapped: false)
            : snappedRotation(start.rotationDegrees.baseValue - deltaDegrees)
        updatePreviewSnapHaptic(
            kind: "rotation",
            snapped: snapped.snapped,
            value: String(format: "%.0f", snapped.rotation)
        )
        updateLiveTransform { $0.rotationDegrees.baseValue = snapped.rotation }
    }

    private func applySnappedScale(
        _ snapped: (scale: Double, guideX: CGFloat?, guideY: CGFloat?),
        from start: ScaleValue
    ) {
        snapGuideX = snapped.guideX
        snapGuideY = snapped.guideY
        updatePreviewSnapHaptic(
            kind: "scale",
            snapped: snapped.guideX != nil || snapped.guideY != nil,
            value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
        )
        updateLiveTransform {
            $0.scale.baseValue = proportionalScale(x: snapped.scale, from: start)
        }
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
        let proposedCenter = CGPoint(
            x: canvasRect.midX + CGFloat(positionX) * canvasRect.width * 0.5 + displayOffset.x,
            y: canvasRect.midY - CGFloat(positionY) * canvasRect.height * 0.5 + displayOffset.y
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

        let normalizedX = Double(
            (snappedX.center - displayOffset.x - canvasRect.midX)
                / max(canvasRect.width * 0.5, 1)
        )
        let normalizedY = Double(
            -(snappedY.center - displayOffset.y - canvasRect.midY)
                / max(canvasRect.height * 0.5, 1)
        )
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
        let center = previewCenter(for: clip, transform: liveTransform ?? clip.transform)
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10
        let rotation = -(liveTransform ?? clip.transform).rotationDegrees.value(at: localTime(for: clip))

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

    private func snappedScale(
        scale: Double,
        text: TextTimelineItem,
        selectedClipID: UUID
    ) -> (scale: Double, guideX: CGFloat?, guideY: CGFloat?) {
        guard let baseSize = previewBaseSize(for: text) else {
            return (min(max(scale, 0.01), 100), nil, nil)
        }

        let animationScale = max(textAnimationSample(for: text).scale, 0.001)
        let proposedDisplayScale = CGFloat(min(max(scale * animationScale, 0.01), 100))
        let transform = liveTransform ?? text.visuals.transform
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
            return (Double(proposedDisplayScale) / animationScale, nil, nil)
        }

        return (
            min(max(Double(best.scale) / animationScale, 0.01), 100),
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

    private func previewFrame(
        for clip: TimelineClip,
        transform: ClipTransform? = nil
    ) -> PreviewClipFrame? {
        let transform = transform ?? clip.transform
        if let shape = clip.shape {
            let renderSize = viewModel.project.renderSettings.size
            guard renderSize.width > 0, renderSize.height > 0,
                canvasRect.width > 0, canvasRect.height > 0
            else { return nil }
            let localTime = localTime(for: clip)
            let scale = transform.scale.value(at: localTime)
            let size = CGSize(
                width: CGFloat(shape.width.value(at: localTime)) * canvasRect.width / renderSize.width
                    * max(scale.x, 0.01),
                height: CGFloat(shape.height.value(at: localTime)) * canvasRect.height / renderSize.height
                    * max(scale.y, 0.01)
            )
            let center = previewCenter(for: clip, transform: transform)
            return PreviewClipFrame(
                rect: CGRect(
                    x: center.x - size.width * 0.5,
                    y: center.y - size.height * 0.5,
                    width: size.width,
                    height: size.height
                ),
                rotationDegrees: -transform.rotationDegrees.value(at: localTime)
            )
        }

        let sourceSize = viewModel.project.naturalSize(for: clip)?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        let localTime = localTime(for: clip)
        let scale = transform.scale.value(at: localTime)
        let size = CGSize(
            width: sourceSize.width * fitScale * max(scale.x, 0.01),
            height: sourceSize.height * fitScale * max(scale.y, 0.01)
        )
        let center = previewCenter(for: clip, transform: transform)

        return PreviewClipFrame(
            rect: CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            ),
            rotationDegrees: -transform.rotationDegrees.value(at: localTime)
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
        let size = CGSize(
            width: baseSize.width * max(scale.x * animationScale, 0.001),
            height: baseSize.height * max(scale.y * animationScale, 0.001)
        )
        let center = previewCenter(for: text, transform: transform)
        return PreviewClipFrame(
            rect: CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            ),
            rotationDegrees: previewRotationDegrees(for: text, transform: transform)
        )
    }

    private func previewBaseSize(for clip: TimelineClip) -> CGSize? {
        if let shape = clip.shape {
            let renderSize = viewModel.project.renderSettings.size
            guard renderSize.width > 0, renderSize.height > 0,
                canvasRect.width > 0, canvasRect.height > 0
            else { return nil }
            return CGSize(
                width: CGFloat(shape.width.value(at: localTime(for: clip))) * canvasRect.width / renderSize.width,
                height: CGFloat(shape.height.value(at: localTime(for: clip))) * canvasRect.height / renderSize.height
            )
        }

        let sourceSize = viewModel.project.naturalSize(for: clip)?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }
        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        return CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
    }

    private func previewBaseSize(for text: TextTimelineItem) -> CGSize? {
        let renderSize = viewModel.project.renderSettings.size
        guard renderSize.width > 0, renderSize.height > 0,
            canvasRect.width > 0, canvasRect.height > 0
        else { return nil }
        let geometry = TextLayerRenderer.geometry(
            for: text,
            renderSize: renderSize,
            renderScale: 1
        )
        return CGSize(
            width: geometry.layerSize.width * canvasRect.width / renderSize.width,
            height: geometry.layerSize.height * canvasRect.height / renderSize.height
        )
    }

    private func previewCenter(
        for clip: TimelineClip,
        transform: ClipTransform? = nil
    ) -> CGPoint {
        let transform = transform ?? clip.transform
        let localTime = localTime(for: clip)
        return CGPoint(
            x: canvasRect.midX + CGFloat(transform.positionX.value(at: localTime)) * canvasRect.width * 0.5,
            y: canvasRect.midY - CGFloat(transform.positionY.value(at: localTime)) * canvasRect.height * 0.5
        )
    }

    private func previewCenter(
        for text: TextTimelineItem,
        transform: ClipTransform? = nil
    ) -> CGPoint {
        let transform = transform ?? text.visuals.transform
        let localTime = localTime(for: text)
        let animationOffset = textAnimationOffset(for: text)
        return CGPoint(
            x: canvasRect.midX
                + CGFloat(transform.positionX.value(at: localTime)) * canvasRect.width * 0.5
                + animationOffset.x,
            y: canvasRect.midY
                - CGFloat(transform.positionY.value(at: localTime)) * canvasRect.height * 0.5
                + animationOffset.y
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
        return CGPoint(
            x: CGFloat(sample.translationX) * geometry.layerSize.width
                * canvasRect.width / renderSize.width,
            y: CGFloat(sample.translationY) * geometry.layerSize.height
                * canvasRect.height / renderSize.height
        )
    }

    private func previewRotationDegrees(
        for text: TextTimelineItem,
        transform: ClipTransform
    ) -> Double {
        let baseRotation = transform.rotationDegrees.value(at: localTime(for: text))
        let animationRotation = textAnimationSample(for: text).rotationRadians * 180 / .pi
        return -(baseRotation + animationRotation)
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

    private func finishPreviewGesture(
        _ gesture: PreviewTransformGesture,
        itemID: UUID
    ) {
        guard interactionClipID == itemID else { return }
        guard activeTransformGestures.remove(gesture) != nil else { return }
        guard activeTransformGestures.isEmpty else { return }
        resetPreviewInteraction(finishEdit: true)
    }

    private func beginPreviewInteraction(for clip: TimelineClip) {
        let resolved = clip.transform.resolved(at: localTime(for: clip))
        dragStartTransform = resolved
        liveTransform = resolved
        livePreviewImage = nil
        liveBackgroundImage = nil
        interactionClipID = clip.id
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        isTransforming = true
        isAwaitingPreviewCommit = false
        EditorHaptics.dragStart()
        viewModel.beginInteractiveEdit()

        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = viewModel.currentTime
        let targetHeight = max(previewFrame(for: clip, transform: resolved)?.rect.height ?? 80, 80)
        let media = viewModel.project.mediaDescriptor(for: clip)
        let speedMap: SpeedMap
        if case .media(let item) = viewModel.project.item(id: clip.id) {
            speedMap = item.speedMap
        } else {
            speedMap = .constant
        }
        Task {
            async let backgroundImage = viewModel.renderService.makePreviewBackgroundImage(
                for: viewModel.project,
                at: timelineTime,
                excluding: clip.id
            )
            async let clipImage: UIImage? =
                clip.shape == nil && media != nil
                ? TimelineThumbnailLoader.image(
                    for: clip,
                    media: media!,
                    speedMap: speedMap,
                    timelineTime: timelineTime,
                    targetHeight: targetHeight
                )
                : nil
            let (background, image) = await (try? backgroundImage, clipImage)
            guard livePreviewLoadID == loadID else { return }
            liveBackgroundImage = background
            livePreviewImage = image
        }
    }

    private func beginPreviewInteraction(for text: TextTimelineItem) {
        let resolved = text.visuals.transform.resolved(at: localTime(for: text))
        dragStartTransform = resolved
        liveTransform = resolved
        livePreviewImage = nil
        liveTextPreviewImage = renderPreviewImage(for: text)
        liveBackgroundImage = nil
        interactionClipID = text.id
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        isTransforming = true
        isAwaitingPreviewCommit = false
        EditorHaptics.dragStart()
        viewModel.beginInteractiveEdit()

        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = viewModel.currentTime
        Task {
            let background = try? await viewModel.renderService.makePreviewBackgroundImage(
                for: viewModel.project,
                at: timelineTime,
                excluding: text.id
            )
            guard livePreviewLoadID == loadID else { return }
            liveBackgroundImage = background
        }
    }

    private func renderPreviewImage(for text: TextTimelineItem) -> UIImage? {
        textRasterizer.image(
            for: text,
            renderSize: viewModel.project.renderSettings.size,
            glyphReveal: textAnimationSample(for: text).glyphReveal
        )
    }

    private func beginInlineEditing(for text: TextTimelineItem) {
        if inlineEditingTextID == text.id {
            isInlineTextEditorFocused = true
            return
        }
        if inlineEditingTextID != nil {
            finishInlineEditing()
        }
        if isTransforming || isAwaitingPreviewCommit {
            resetPreviewInteraction(finishEdit: isTransforming)
            clearLivePreview()
        }

        inlineTextDraft = text.text
        inlineEditingTextID = text.id
        isInlineTextEditorFocused = false
        liveBackgroundImage = nil
        viewModel.beginInteractiveEdit()
        EditorHaptics.selection()

        let loadID = UUID()
        livePreviewLoadID = loadID
        let timelineTime = viewModel.currentTime
        Task {
            async let background = viewModel.renderService.makePreviewBackgroundImage(
                for: viewModel.project,
                at: timelineTime,
                excluding: text.id
            )
            await Task.yield()
            guard inlineEditingTextID == text.id else { return }
            isInlineTextEditorFocused = true
            let image = try? await background
            guard inlineEditingTextID == text.id, livePreviewLoadID == loadID else { return }
            liveBackgroundImage = image
        }
    }

    private func updateInlineText(_ value: String, itemID: UUID) {
        guard inlineEditingTextID == itemID, value != inlineTextDraft else { return }
        inlineTextDraft = value
        viewModel.updateTextItem(itemID, interactive: true) { item in
            item.text = value
            let firstLine = value
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item.name = firstLine.map { String($0.prefix(32)) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Text"
        }
    }

    private func finishInlineEditing() {
        guard inlineEditingTextID != nil else { return }
        inlineEditingTextID = nil
        isInlineTextEditorFocused = false
        inlineTextDraft = ""
        livePreviewLoadID = nil
        liveBackgroundImage = nil
        viewModel.finishTextEditing()
        EditorHaptics.editCommit()
    }

    private func inlineTextPlacement(for text: TextTimelineItem) -> InlineTextPlacement {
        let renderSize = viewModel.project.renderSettings.size
        let renderWidth = max(renderSize.width, 1)
        let renderHeight = max(renderSize.height, 1)
        let horizontalScale = canvasRect.width / renderWidth
        let verticalScale = canvasRect.height / renderHeight
        let geometry = TextLayerRenderer.geometry(
            for: text,
            renderSize: renderSize,
            renderScale: 1
        )
        let transform = text.visuals.transform
        let localTime = localTime(for: text)
        let transformScale = transform.scale.value(at: localTime)
        let animationScale = max(textAnimationSample(for: text).scale, 0.001)
        let textRect = geometry.textRect
        let layerSize = CGSize(
            width: geometry.layerSize.width * horizontalScale,
            height: geometry.layerSize.height * verticalScale
        )
        let backgroundRect = geometry.backgroundRect.map {
            CGRect(
                x: $0.minX * horizontalScale,
                y: $0.minY * verticalScale,
                width: $0.width * horizontalScale,
                height: $0.height * verticalScale
            )
        }
        let localCenter = previewCenter(for: text, transform: transform)
        return InlineTextPlacement(
            layerSize: layerSize,
            center: CGPoint(
                x: localCenter.x + canvasFrame.minX,
                y: localCenter.y + canvasFrame.minY
            ),
            scaleX: CGFloat(transformScale.x * animationScale)
                * (transform.isFlippedHorizontally ? -1 : 1),
            scaleY: CGFloat(transformScale.y * animationScale)
                * (transform.isFlippedVertically ? -1 : 1),
            rotationDegrees: previewRotationDegrees(for: text, transform: transform),
            opacity: min(max(transform.opacity.value(at: localTime), 0), 1),
            textInsets: UIEdgeInsets(
                top: textRect.minY * verticalScale,
                left: textRect.minX * horizontalScale,
                bottom: max(geometry.layerSize.height - textRect.maxY, 0) * verticalScale,
                right: max(geometry.layerSize.width - textRect.maxX, 0) * horizontalScale
            ),
            backgroundRect: backgroundRect,
            backgroundCornerRadius: CGFloat(text.style.background?.cornerRadius ?? 0)
                * min(horizontalScale, verticalScale),
            fontScale: horizontalScale
        )
    }

    private func updateLiveTransform(_ update: (inout ClipTransform) -> Void) {
        guard var transform = liveTransform else { return }
        update(&transform)
        liveTransform = transform
    }

    private func resetPreviewInteraction(finishEdit: Bool) {
        let committedTransform =
            finishEdit && interactionClipID == viewModel.selectedTimelineItemID
            ? liveTransform
            : nil
        let committedItemID = interactionClipID
        let committedComponents = editedTransformComponents
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKeys.removeAll()
        activeTransformGestures.removeAll()
        hasTwoFingerTransformInSession = false
        dragStartTransform = nil

        guard finishEdit, let committedTransform, !committedComponents.isEmpty else {
            clearLivePreview()
            if finishEdit {
                viewModel.finishInteractiveEdit()
            }
            return
        }

        isAwaitingPreviewCommit = true
        if let committedItemID,
            let selectedItem = viewModel.project.item(id: committedItemID),
            case .text(let selectedText) = selectedItem
        {
            let keyframeTime = min(
                viewModel.snappedKeyframeTime(viewModel.currentTime - selectedText.timelineStart),
                selectedText.duration
            )
            let keyframeTolerance = viewModel.keyframeTimeTolerance
            viewModel.updateTextItem(committedItemID, interactive: true) { item in
                if committedComponents.contains(.position) {
                    Self.setTransformValue(
                        committedTransform.positionX.baseValue,
                        on: &item.visuals.transform.positionX,
                        at: keyframeTime,
                        tolerance: keyframeTolerance
                    )
                    Self.setTransformValue(
                        committedTransform.positionY.baseValue,
                        on: &item.visuals.transform.positionY,
                        at: keyframeTime,
                        tolerance: keyframeTolerance
                    )
                }
                if committedComponents.contains(.scale) {
                    if item.visuals.transform.scale.keyframes.isEmpty {
                        item.visuals.transform.scale.baseValue = committedTransform.scale.baseValue
                    } else {
                        _ = item.visuals.transform.scale.setKeyframe(
                            at: keyframeTime,
                            value: committedTransform.scale.baseValue,
                            tolerance: keyframeTolerance
                        )
                    }
                }
                if committedComponents.contains(.rotation) {
                    Self.setTransformValue(
                        committedTransform.rotationDegrees.baseValue,
                        on: &item.visuals.transform.rotationDegrees,
                        at: keyframeTime,
                        tolerance: keyframeTolerance
                    )
                }
            }
        } else {
            viewModel.setSelectedTransform(
                positionX: committedComponents.contains(.position)
                    ? committedTransform.positionX.baseValue : nil,
                positionY: committedComponents.contains(.position)
                    ? committedTransform.positionY.baseValue : nil,
                scale: committedComponents.contains(.scale)
                    ? committedTransform.scale.baseValue.x : nil,
                rotationDegrees: committedComponents.contains(.rotation)
                    ? committedTransform.rotationDegrees.baseValue : nil,
                interactive: true
            )
        }
        viewModel.finishInteractiveEdit()
        EditorHaptics.editCommit()
    }

    private static func setTransformValue(
        _ value: Double,
        on property: inout AnimatableProperty<Double>,
        at time: Double,
        tolerance: Double
    ) {
        if property.keyframes.isEmpty {
            property.baseValue = value
        } else {
            _ = property.setKeyframe(at: time, value: value, tolerance: tolerance)
        }
    }

    private func clearLivePreview() {
        dragStartTransform = nil
        liveTransform = nil
        livePreviewImage = nil
        liveTextPreviewImage = nil
        liveBackgroundImage = nil
        livePreviewLoadID = nil
        interactionClipID = nil
        activeTransformGestures = []
        hasTwoFingerTransformInSession = false
        editedTransformComponents = []
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKeys = [:]
        isTransforming = false
        isAwaitingPreviewCommit = false
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

struct LiveTransformClipProxy: View {
    let clip: TimelineClip
    let frame: PreviewClipFrame
    let transform: ClipTransform
    let image: UIImage?
    let localTime: Double

    var body: some View {
        Group {
            if let shape = clip.shape {
                PreviewShapeProxy(
                    shape: shape,
                    frameSize: frame.rect.size,
                    localTime: localTime
                )
            } else if let image {
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
            x: transform.isFlippedHorizontally ? -1 : 1,
            y: transform.isFlippedVertically ? -1 : 1
        )
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .opacity(transform.opacity.baseValue)
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
        glyphReveal: Double
    ) -> UIImage? {
        let result = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 1,
            glyphReveal: glyphReveal
        )
        let extent = result.image.extent.integral
        guard extent.width > 0, extent.height > 0,
            let image = context.createCGImage(result.image, from: extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct InlineTextPlacement {
    let layerSize: CGSize
    let center: CGPoint
    let scaleX: CGFloat
    let scaleY: CGFloat
    let rotationDegrees: Double
    let opacity: Double
    let textInsets: UIEdgeInsets
    let backgroundRect: CGRect?
    let backgroundCornerRadius: CGFloat
    let fontScale: CGFloat
}

private struct InlineTextEditingOverlay: View {
    let item: TextTimelineItem
    @Binding var draft: String
    @Binding var isFocused: Bool
    let placement: InlineTextPlacement
    let onTextChange: (String) -> Void
    let onEditingEnd: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let background = item.style.background,
                let backgroundRect = placement.backgroundRect
            {
                RoundedRectangle(
                    cornerRadius: placement.backgroundCornerRadius,
                    style: .continuous
                )
                .fill(background.color.swiftUIColor)
                .frame(width: backgroundRect.width, height: backgroundRect.height)
                .position(x: backgroundRect.midX, y: backgroundRect.midY)
                .allowsHitTesting(false)
            }

            InlineMultilineTextView(
                text: $draft,
                isFocused: $isFocused,
                style: item.style,
                renderScale: placement.fontScale,
                textInsets: placement.textInsets,
                onTextChange: onTextChange,
                onEditingEnd: onEditingEnd
            )
            .frame(width: placement.layerSize.width, height: placement.layerSize.height)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(MotionaryTheme.accent, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .frame(width: placement.layerSize.width, height: placement.layerSize.height)
        .scaleEffect(x: placement.scaleX, y: placement.scaleY)
        .rotationEffect(.degrees(placement.rotationDegrees))
        .position(x: placement.center.x, y: placement.center.y)
        .opacity(placement.opacity)
        .accessibilityLabel("Editing text")
    }
}

private struct InlineMultilineTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let style: TextStyle
    let renderScale: CGFloat
    let textInsets: UIEdgeInsets
    let onTextChange: (String) -> Void
    let onEditingEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isScrollEnabled = false
        textView.clipsToBounds = false
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInset = .zero
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.tintColor = UIColor(MotionaryTheme.accent)
        textView.accessibilityLabel = "Text content"

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(
                barButtonSystemItem: .done,
                target: context.coordinator,
                action: #selector(Coordinator.finishEditing)
            )
        ]
        textView.inputAccessoryView = toolbar
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.textContainerInset = textInsets
        let attributes = textAttributes
        textView.typingAttributes = attributes
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.attributedText = NSAttributedString(string: text, attributes: attributes)
            let caret = min(selectedRange.location, textView.text.utf16.count)
            textView.selectedRange = NSRange(location: caret, length: 0)
        }

        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, !textView.isFirstResponder else { return }
                textView.becomeFirstResponder()
            }
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let font = TextLayerRenderer.resolvedFont(for: style, renderScale: renderScale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = CGFloat(style.lineSpacing) * renderScale
        switch style.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.uiColor(style.color),
            .paragraphStyle: paragraph,
            .kern: CGFloat(style.letterSpacing) * renderScale
        ]
        if let stroke = style.stroke, stroke.width > 0 {
            let width = CGFloat(stroke.width) * renderScale
            attributes[.strokeColor] = Self.uiColor(stroke.color)
            attributes[.strokeWidth] = -(width / max(font.pointSize, 1)) * 100
        }
        if let shadow = style.shadow {
            let value = NSShadow()
            value.shadowColor = Self.uiColor(shadow.color)
            value.shadowOffset = CGSize(
                width: CGFloat(shadow.offsetX) * renderScale,
                height: CGFloat(shadow.offsetY) * renderScale
            )
            value.shadowBlurRadius = CGFloat(shadow.blur) * renderScale
            attributes[.shadow] = value
        }
        return attributes
    }

    private static func uiColor(_ color: RGBAColor) -> UIColor {
        UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineMultilineTextView
        weak var textView: UITextView?

        init(parent: InlineMultilineTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onTextChange(textView.text)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
            parent.onEditingEnd()
        }

        @objc func finishEditing() {
            textView?.resignFirstResponder()
        }
    }
}

private struct PreviewShapeProxy: View {
    let shape: ClipShape
    let frameSize: CGSize
    let localTime: Double

    var body: some View {
        switch shape.kind {
        case .rectangle:
            Rectangle()
                .fill(shape.color.swiftUIColor)
        case .roundedRectangle:
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(shape.color.swiftUIColor)
        case .circle:
            Ellipse()
                .fill(shape.color.swiftUIColor)
        }
    }

    private var cornerRadius: CGFloat {
        let sourceWidth = max(CGFloat(shape.width.value(at: localTime)), 1)
        let sourceHeight = max(CGFloat(shape.height.value(at: localTime)), 1)
        let scale = min(frameSize.width / sourceWidth, frameSize.height / sourceHeight)
        return min(
            CGFloat(shape.cornerRadius.value(at: localTime)) * scale,
            min(frameSize.width, frameSize.height) * 0.5
        )
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
