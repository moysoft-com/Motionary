// Timeline track row presentation, selection, deletion, and reorder interactions.

import SwiftUI
import UIKit

enum TimelineTrackBackgroundRange {
    static func visible(projectEnd: Double, visibleRange: ClosedRange<Double>, previewEnd: Double?) -> ClosedRange<Double>? {
        let end = max(projectEnd, previewEnd ?? 0, 0)
        guard end > 0 else { return nil }
        let lower = min(max(visibleRange.lowerBound, 0), end)
        let upper = min(max(visibleRange.upperBound, previewEnd ?? 0, lower), end)
        return upper > lower ? lower...upper : nil
    }
}

enum TimelineTrackBackgroundRadius {
    static func calculate(items: [TimelineItem], range: ClosedRange<Double>, pixelsPerSecond: CGFloat,
                          itemRadius: CGFloat, inset: CGFloat, height: CGFloat) -> CGFloat {
        let maximum = min(8 + inset, max(height, 0) / 2)
        let adjacent = min(maximum, max(itemRadius, 0) + inset)
        let scale = max(pixelsPerSecond, 0)
        let contentWidth = CGFloat(max(range.upperBound - range.lowerBound, 0)) * scale
        var radius = maximum
        for item in items {
            let start = CGFloat(item.timelineStart - range.lowerBound) * scale
            let end = start + max(CGFloat(item.placementDuration) * scale, 6)
            guard end >= 0, start <= contentWidth else { continue }
            let distance = min(max(start, 0), max(contentWidth - end, 0))
            radius = min(radius, adjacent + distance)
        }
        return radius
    }
}

struct TimelineTrackRow: View {
    let track: TimelineTrack
    let trackSnapshot: TimelineRenderTrackSnapshot?
    let items: [TimelineRenderItem]
    let trackIndex: Int
    let trackCount: Int
    let selectedClipID: UUID?
    let activeClipDrag: TimelineClipDragState?
    let activeTrackDrag: TimelineTrackDragState?
    let playbackState: PlaybackState
    let keyframeTolerance: Double
    let projectDuration: Double
    let pixelsPerSecond: CGFloat
    let centerPadding: CGFloat
    let visibleTimelineRange: ClosedRange<Double>
    let scrollPresentationState: TimelineScrollPresentationState
    let height: CGFloat
    let rowStride: CGFloat
    let onSelectTrack: () -> Void
    let onTapEmptySpace: () -> Void
    let onDeleteTrack: () -> Void
    let onCopyTrack: () -> Void
    let onCutTrack: () -> Void
    let onPasteTrack: () -> Void
    let onSelectClip: (UUID) -> Void
    let onBeginEditClip: (UUID) -> Void
    let onClipDragBegan: (TimelineItem) -> Void
    let onClipDragChanged: (TimelineItem, TimelineLongPressDragValue) -> Void
    let onClipDragEnded: (Bool) -> Void
    let onTrimStart: (UUID, Double, TimelineItem?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (UUID, Double, TimelineItem?) -> TimelineTrimResult?
    let onTrimEnd: (UUID, Double, TimelineItem?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (UUID, Double, TimelineItem?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let mediaForClip: (TimelineClip) -> ClipMediaDescriptor?
    let onSnapGuideChanged: (Double?) -> Void
    let onTrackDragBegan: () -> Void
    let onTrackDragChanged: (TimelineLongPressDragValue) -> Void
    let onTrackDragEnded: (Bool) -> Void
    var onTrackTrimPreviewChanged: ((TimelineItem?) -> Void)? = nil
    var workspaceContext: TimelineWorkspaceContext? = nil
    @State private var activeTrimPreview: TimelineItem?

    private let itemInset: CGFloat = 4

    private var isFocusedTrack: Bool {
        guard workspaceContext != nil, let selectedClipID else { return workspaceContext == nil }
        return trackSnapshot?.item(withID: selectedClipID) != nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            TimelineTrackHeader(
                track: track,
                centerPadding: centerPadding,
                height: height,
                scrollPresentationState: scrollPresentationState,
                onSelectTrack: onSelectTrack,
                onDeleteTrack: onDeleteTrack,
                onCopyTrack: onCopyTrack,
                onCutTrack: onCutTrack,
                onPasteTrack: onPasteTrack,
                onTrackDragBegan: onTrackDragBegan,
                onTrackDragChanged: onTrackDragChanged,
                onTrackDragEnded: onTrackDragEnded
            )
            .opacity(isFocusedTrack ? 1 : 0.55)
            .zIndex(300)

            if let backgroundRange = visibleTrackBackgroundRange {
                RoundedRectangle(cornerRadius: backgroundRadius(in: backgroundRange), style: .continuous)
                    .fill(MotionaryTheme.surfaceSubtle)
                    .frame(
                        width: max(
                            itemInset * 2 + CGFloat(backgroundRange.upperBound - backgroundRange.lowerBound)
                                * pixelsPerSecond,
                            itemInset * 2
                        ),
                        height: height
                    )
                    .offset(
                        x: centerPadding
                            + CGFloat(backgroundRange.lowerBound) * pixelsPerSecond
                            - itemInset
                    )
                    .contentShape(Rectangle())
                    .opacity(isFocusedTrack ? 1 : 0.35)
                    .onTapGesture(perform: onTapEmptySpace)
            }

            ForEach(items) { renderItem in
                let item = renderItem.item
                TimelineItemBlock(
                    item: item,
                    media: renderItem.legacyClip.flatMap(mediaForClip),
                    keyframeTimes: renderItem.keyframeTimes,
                    visibleTimelineRange: visibleTimelineRange,
                    isSelected: selectedClipID == item.id,
                    isDragSourceHidden: activeClipDrag?.clipID == item.id,
                    isDragGhost: false,
                    cachedMediaClip: renderItem.legacyClip,
                    playbackState: playbackState,
                    keyframeTolerance: keyframeTolerance,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height - itemInset * 2,
                    cornerRadius: itemCornerRadius,
                    allowsClipInteraction: true,
                    onSelect: { onSelectClip(item.id) },
                    onBeginEdit: { onBeginEditClip(item.id) },
                    onClipDragBegan: { onClipDragBegan(item) },
                    onClipDragChanged: { value in onClipDragChanged(item, value) },
                    onClipDragEnded: onClipDragEnded,
                    onTrimStart: { delta, baseline, interactive in
                        onTrimStart(item.id, delta, baseline, interactive)
                    },
                    onPreviewTrimStart: { delta, baseline in
                        onPreviewTrimStart(item.id, delta, baseline)
                    },
                    onTrimEnd: { delta, baseline, interactive in
                        onTrimEnd(item.id, delta, baseline, interactive)
                    },
                    onPreviewTrimEnd: { delta, baseline in
                        onPreviewTrimEnd(item.id, delta, baseline)
                    },
                    onFinishInteractiveEdit: onFinishInteractiveEdit,
                    onSnapGuideChanged: onSnapGuideChanged,
                    onTrimPreviewChanged: {
                        activeTrimPreview = $0
                        onTrackTrimPreviewChanged?($0)
                    },
                    workspaceContext: workspaceContext
                )
                .saturation(workspaceContext == nil || selectedClipID == item.id ? 1 : 0)
                .opacity(workspaceContext == nil || selectedClipID == item.id ? 1 : 0.28)
                .offset(x: centerPadding + CGFloat(item.timelineStart) * pixelsPerSecond)
            }
        }
        .frame(height: height)
        .offset(y: trackReorderOffset)
        .animation(
            activeTrackDrag?.trackID == track.id
                ? nil
                : .interactiveSpring(response: 0.22, dampingFraction: 0.86),
            value: trackReorderOffset
        )
        .zIndex(
            activeTrackDrag?.trackID == track.id
                ? 200
                : (items.contains { $0.id == selectedClipID } ? 100 : 0)
        )
    }

    private var itemCornerRadius: CGFloat {
        let movingAway = activeClipDrag.map {
            $0.sourceTrackIndex == trackIndex && $0.resolvedPlacement.trackIndex != trackIndex
        } ?? false
        let excludedID = activeTrimPreview?.id ?? (movingAway ? activeClipDrag?.clipID : nil)
        var shortest = trackSnapshot?.minimumItemDuration(excluding: excludedID)
        if let activeTrimPreview {
            shortest = min(shortest ?? activeTrimPreview.placementDuration, activeTrimPreview.placementDuration)
        }
        if let drag = activeClipDrag, drag.sourceTrackIndex != trackIndex,
           drag.resolvedPlacement.trackIndex == trackIndex {
            shortest = min(shortest ?? drag.itemSnapshot.placementDuration, drag.itemSnapshot.placementDuration)
        }
        return TimelineItemCornerRadius.value(shortestDuration: shortest, pixelsPerSecond: pixelsPerSecond,
                                              height: height - itemInset * 2)
    }

    private func backgroundRadius(in range: ClosedRange<Double>) -> CGFloat {
        var displayedItems = items.compactMap { renderItem -> TimelineItem? in
            if renderItem.id == activeClipDrag?.clipID { return nil }
            return activeTrimPreview?.id == renderItem.id ? activeTrimPreview : renderItem.item
        }
        if let drag = activeClipDrag, drag.resolvedPlacement.trackIndex == trackIndex {
            var ghost = drag.itemSnapshot
            ghost.timelineStart = drag.resolvedPlacement.start
            displayedItems.append(ghost)
        }
        return TimelineTrackBackgroundRadius.calculate(items: displayedItems, range: range,
                                                      pixelsPerSecond: pixelsPerSecond,
                                                      itemRadius: itemCornerRadius, inset: itemInset, height: height)
    }

    private var trackReorderOffset: CGFloat {
        guard let activeTrackDrag else { return 0 }
        if activeTrackDrag.trackID == track.id {
            return activeTrackDrag.translationY
        }

        let source = activeTrackDrag.sourceIndex
        let target = activeTrackDrag.targetIndex
        if source < target, trackIndex > source, trackIndex <= target {
            return -rowStride
        }
        if target < source, trackIndex >= target, trackIndex < source {
            return rowStride
        }
        return 0
    }

    private var visibleTrackBackgroundRange: ClosedRange<Double>? {
        let dragEnd = activeClipDrag.flatMap { drag -> Double? in
            guard drag.resolvedPlacement.trackIndex == trackIndex else { return nil }
            return drag.resolvedPlacement.start + drag.itemSnapshot.placementDuration
        }
        let previewEnd = max(dragEnd ?? 0, activeTrimPreview?.timelineEnd ?? 0)
        return TimelineTrackBackgroundRange.visible(projectEnd: projectDuration,
                                                    visibleRange: visibleTimelineRange,
                                                    previewEnd: previewEnd > 0 ? previewEnd : nil)
    }

}

private struct TimelineTrackHeader: View {
    let track: TimelineTrack
    let centerPadding: CGFloat
    let height: CGFloat
    @ObservedObject var scrollPresentationState: TimelineScrollPresentationState
    let onSelectTrack: () -> Void
    let onDeleteTrack: () -> Void
    let onCopyTrack: () -> Void
    let onCutTrack: () -> Void
    let onPasteTrack: () -> Void
    let onTrackDragBegan: () -> Void
    let onTrackDragChanged: (TimelineLongPressDragValue) -> Void
    let onTrackDragEnded: (Bool) -> Void

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        trackLabel
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button("Cut", systemImage: "scissors", action: onCutTrack)
                Button("Copy", systemImage: "doc.on.doc", action: onCopyTrack)
                Button("Paste", systemImage: "doc.on.clipboard", action: onPasteTrack)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
            }
            .onTapGesture(count: 2) { EditorHaptics.tap(); isShowingDeleteConfirmation = true }
            .onTapGesture { onSelectTrack() }
            .accessibilityIdentifier("timeline-track-\(track.id.uuidString)")
            .position(
                x: trackLabelOffset + trackLabelWidth * 0.5,
                y: height * 0.5
            )
    }

    private var trackLabelOffset: CGFloat {
        TimelineTrackHeaderLayout(
            centerPadding: centerPadding,
            horizontalOffset: scrollPresentationState.horizontalOffset
        ).contentOffset
    }

    private var trackLabelWidth: CGFloat { TimelineTrackHeaderLayout.width }

    private var trackLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: timelineTrackIcon(for: track.kind))
                .font(.caption)
            Text(track.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(MotionaryTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(width: trackLabelWidth, height: height, alignment: .leading)
        .background(MotionaryTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .popover(isPresented: $isShowingDeleteConfirmation, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete \(track.name)?")
                    .font(.headline)

                Button(role: .destructive) {
                    EditorHaptics.deleteCommit()
                    isShowingDeleteConfirmation = false
                    onDeleteTrack()
                } label: {
                    HStack {
                        Spacer()
                        Text("Confirm")
                        Spacer()
                    }
                }
                .motionaryProminentButtonStyle()
                .tint(.red)
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct TimelineTrackReorderHandle: View {
    let centerPadding: CGFloat
    let height: CGFloat
    @ObservedObject var scrollState: TimelineScrollPresentationState
    let items: [TimelineRenderItem]
    let pixelsPerSecond: CGFloat
    let hiddenItemID: UUID?
    let mediaForClip: (TimelineClip) -> ClipMediaDescriptor?
    var viewportOverlay = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let onBegan: () -> Void
    let onChanged: (TimelineLongPressDragValue) -> Void
    let onEnded: (Bool) -> Void

    @State private var dragging = false
    @State private var backgroundIsLight: Bool?

    var body: some View {
        handleLines
        .frame(width: height, height: height)
        .contentShape(Rectangle())
        .task(id: sampleKey) {
            await updateBackgroundBrightness()
        }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        onBegan()
                    }
                    onChanged(
                        TimelineLongPressDragValue(
                            translation: value.translation,
                            locationInWindow: value.location
                        )
                    )
                }
                .onEnded { _ in
                    if dragging {
                        dragging = false
                        onEnded(true)
                    }
                }
        )
        .onDisappear {
            if dragging {
                dragging = false
                onEnded(false)
            }
        }
        .accessibilityLabel("Reorder layer")
        .position(
            x: handleX - (viewportOverlay ? scrollState.horizontalOffset : 0),
            y: height / 2
        )
    }

    private var handleX: CGFloat {
        scrollState.horizontalOffset + centerPadding * 2 - 23
    }

    private var handleLines: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(handleColor)
                    .frame(width: 13, height: 1.5)
                    .background {
                        Capsule().stroke(outlineColor, lineWidth: 1.2)
                    }
                    .offset(y: CGFloat(index - 1) * 5)
            }
        }
        .frame(width: height, height: height)
        .animation(.easeInOut(duration: 0.22), value: backgroundIsLight)
        .animation(.easeInOut(duration: 0.22), value: colorScheme)
    }

    private var itemUnderHandle: TimelineRenderItem? {
        items.last { renderItem in
            let item = renderItem.item
            let start = centerPadding + CGFloat(item.timelineStart) * pixelsPerSecond
            let end = start + max(CGFloat(item.placementDuration) * pixelsPerSecond, 6)
            return item.id != hiddenItemID && start <= handleX && end > handleX
        }
    }

    private var handleColor: Color {
        usesOpposite ? oppositeSecondary : MotionaryTheme.textSecondary
    }

    private var outlineColor: Color {
        usesOpposite ? MotionaryTheme.textSecondary : oppositeSecondary
    }

    private var usesOpposite: Bool {
        guard let backgroundIsLight else { return false }
        return backgroundIsLight == (colorScheme == .dark)
    }

    /// Complement the resolved sRGB components while retaining the original alpha.
    private var oppositeSecondary: Color {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let color = UIColor(MotionaryTheme.textSecondary).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return Color(.sRGB, red: Double(1 - red), green: Double(1 - green), blue: Double(1 - blue), opacity: Double(alpha))
        }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return Color(.sRGB, white: Double(1 - white), opacity: Double(alpha))
        }
        return colorScheme == .dark ? .black.opacity(0.66) : .white.opacity(0.66)
    }

    private var sampleKey: String {
        guard let item = itemUnderHandle else { return "empty" }
        let localX = handleX - centerPadding - CGFloat(item.timelineStart) * pixelsPerSecond
        let source: String
        if case .media(let media) = item.item {
            source = "\(media.mediaID.rawValue)-\(media.sourceRange.start)-\(media.sourceRange.duration)-\(media.speedMap.topologySignature)"
        } else {
            source = "generated"
        }
        return "\(item.id)-\(source)-\(Int(localX / 8))-\(pixelsPerSecond)-\(item.item.placementDuration)-\(colorScheme)"
    }

    @MainActor
    private func updateBackgroundBrightness() async {
        guard let renderItem = itemUnderHandle else { backgroundIsLight = nil; return }
        let item = renderItem.item
        guard case .media(let mediaItem) = item, mediaItem.mediaType != .audio,
            let clip = renderItem.legacyClip, let media = mediaForClip(clip)
        else {
            let color = UIColor(timelineItemTint(for: item)).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                updateBrightness(Double(0.2126 * red + 0.7152 * green + 0.0722 * blue))
            } else {
                backgroundIsLight = nil
            }
            return
        }
        let size = media.naturalSize?.cgSize ?? CGSize(width: 16, height: 9)
        let aspect = min(max(abs(size.width) / max(abs(size.height), 1), 0.35), 4)
        let tileHeight = max(height - 8, 1)
        let tileWidth = max(tileHeight * aspect, 24)
        let localX = max(handleX - centerPadding - CGFloat(item.timelineStart) * pixelsPerSecond, 0)
        let index = Int(localX / tileWidth)
        let secondsPerTile = Double(tileWidth / max((pixelsPerSecond / 4).rounded() * 4, 4))
        let image = await TimelineThumbnailLoader.tileImage(
            for: clip, media: media, speedMap: mediaItem.speedMap, tileIndex: index,
            tileWidth: tileWidth, tileHeight: tileHeight,
            secondsPerTile: secondsPerTile, displayScale: displayScale
        )
        guard !Task.isCancelled else { return }
        if let luminance = image.flatMap({ Self.brightness($0, tileX: localX - CGFloat(index) * tileWidth, tileSize: CGSize(width: tileWidth, height: tileHeight)) }) {
            updateBrightness(luminance)
        } else {
            backgroundIsLight = nil
        }
    }

    @MainActor
    private func updateBrightness(_ value: Double) {
        // Keep the current state through the middle range to prevent flicker.
        if value >= 0.62 { backgroundIsLight = true }
        else if value <= 0.38 { backgroundIsLight = false }
        else if backgroundIsLight == nil { backgroundIsLight = value >= 0.5 }
    }

    private static func brightness(_ image: UIImage, tileX: CGFloat, tileSize: CGSize) -> Double? {
        guard let source = image.cgImage, tileSize.width > 0, tileSize.height > 0 else { return nil }
        let imageSize = CGSize(width: source.width, height: source.height)
        let scale = max(tileSize.width / imageSize.width, tileSize.height / imageSize.height)
        let cropX = (imageSize.width * scale - tileSize.width) / 2
        let cropY = (imageSize.height * scale - tileSize.height) / 2
        let region = CGRect(x: (tileX - 8 + cropX) / scale, y: (tileSize.height / 2 - 8 + cropY) / scale,
                            width: 16 / scale, height: 16 / scale)
            .intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard !region.isNull, !region.isEmpty, let crop = source.cropping(to: region) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}

/// Shared by the header's motion and its exemption from the viewport fade.
struct TimelineTrackHeaderLayout {
    static let width: CGFloat = 104
    let centerPadding: CGFloat
    let horizontalOffset: CGFloat

    private var maximumOffset: CGFloat { centerPadding - 5 - Self.width - 8 }
    private var stickyOffset: CGFloat { horizontalOffset + 10 }

    var transitionProgress: CGFloat {
        min(max((stickyOffset - (maximumOffset - 12)) / 24, 0), 1)
    }

    var contentOffset: CGFloat {
        if transitionProgress >= 1 { return maximumOffset }
        return stickyOffset - 12 * transitionProgress * transitionProgress
    }

    var viewportOffset: CGFloat { contentOffset - horizontalOffset }
}
