// Timeline track row presentation, selection, deletion, and reorder interactions.

import SwiftUI

struct TimelineTrackRow: View {
    let track: TimelineTrack
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
    var workspaceContext: TimelineWorkspaceContext? = nil

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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MotionaryTheme.surfaceSubtle)
                    .frame(
                        width: max(
                            10 + CGFloat(backgroundRange.upperBound - backgroundRange.lowerBound)
                                * pixelsPerSecond,
                            10
                        ),
                        height: height
                    )
                    .offset(
                        x: centerPadding
                            + CGFloat(backgroundRange.lowerBound) * pixelsPerSecond
                            - 5
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
                    height: height - 8,
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
        let timelineEnd = max(projectDuration, 0)
        guard timelineEnd > 0 else { return nil }
        let lowerBound = min(max(visibleTimelineRange.lowerBound, 0), timelineEnd)
        let upperBound = min(max(visibleTimelineRange.upperBound, lowerBound), timelineEnd)
        guard upperBound > lowerBound else { return nil }
        return lowerBound...upperBound
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
