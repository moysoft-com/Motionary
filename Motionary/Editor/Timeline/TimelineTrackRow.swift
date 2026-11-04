// Timeline track row presentation, selection, deletion, and reorder interactions.

import SwiftUI

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
    let currentTime: Double
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
    let mediaForItem: (TimelineItem) -> ClipMediaDescriptor?
    let onSnapGuideChanged: (Double?) -> Void
    let onTrackDragBegan: () -> Void
    let onTrackDragChanged: (TimelineLongPressDragValue) -> Void
    let onTrackDragEnded: (Bool) -> Void
    var onTrackTrimPreviewChanged: ((TimelineItem?) -> Void)? = nil
    var workspaceContext: TimelineWorkspaceContext? = nil
    @State private var activeTrimPreview: TimelineItem?

    private let itemInset: CGFloat = 4

    private var isFocusedTrack: Bool {
        workspaceContext == nil || track.items.contains { $0.id == selectedClipID }
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
                    media: mediaForItem(item),
                    keyframeTimes: renderItem.keyframeTimes,
                    visibleTimelineRange: visibleTimelineRange,
                    isSelected: selectedClipID == item.id,
                    isDragSourceHidden: activeClipDrag?.clipID == item.id,
                    isDragGhost: false,
                    currentTime: currentTime,
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
    let onTrackDragBegan: () -> Void
    let onTrackDragChanged: (TimelineLongPressDragValue) -> Void
    let onTrackDragEnded: (Bool) -> Void

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        trackLabel
            .overlay {
                TimelineLongPressInteractionTarget(
                    minimumPressDuration: 0.32,
                    allowableMovement: 16,
                    accessibilityIdentifier: "timeline-track-\(track.id.uuidString)",
                    accessibilityLabel: track.name,
                    onTap: onSelectTrack,
                    onDoubleTap: {
                        EditorHaptics.tap()
                        isShowingDeleteConfirmation = true
                    },
                    onLongPressBegan: onTrackDragBegan,
                    onLongPressChanged: onTrackDragChanged,
                    onLongPressEnded: onTrackDragEnded
                )
                .frame(width: trackLabelWidth, height: height)
            }
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
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
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
