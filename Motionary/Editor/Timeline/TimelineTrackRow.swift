// Timeline track row presentation, selection, deletion, and reorder interactions.

import SwiftUI

struct TimelineTrackRow: View {
    let track: TimelineTrack
    let items: [TimelineItem]
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
    let horizontalScrollOffset: CGFloat
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

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        ZStack(alignment: .leading) {
            trackLabelControl
                .position(
                    x: trackLabelOffset + trackLabelWidth * 0.5,
                    y: height * 0.5
                )
                .zIndex(300)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .frame(width: max(10 + CGFloat(projectDuration) * pixelsPerSecond, 0), height: height)
                .offset(x: centerPadding - 5)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapEmptySpace)

            ForEach(items) { item in
                TimelineItemBlock(
                    item: item,
                    media: mediaForItem(item),
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
                    onSnapGuideChanged: onSnapGuideChanged
                )
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

    private var trackLabelControl: some View {
        trackLabel
            .overlay {
                TimelineLongPressInteractionTarget(
                    minimumPressDuration: 0.32,
                    allowableMovement: 16,
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
    }

    private var trackLabelOffset: CGFloat {
        let viewportLeadingPadding: CGFloat = 10
        let labelWidth: CGFloat = 104
        let layerLeadingEdge = centerPadding - 5
        let layerSpacing: CGFloat = 8
        let maximumOffset = layerLeadingEdge - labelWidth - layerSpacing
        let stickyOffset = horizontalScrollOffset + viewportLeadingPadding
        let transitionWidth: CGFloat = 24
        let transitionHalfWidth = transitionWidth * 0.5
        let transitionStart = maximumOffset - transitionHalfWidth
        let transitionEnd = maximumOffset + transitionHalfWidth

        guard stickyOffset > transitionStart else { return stickyOffset }
        guard stickyOffset < transitionEnd else { return maximumOffset }

        let linearProgress = (stickyOffset - transitionStart) / transitionWidth
        return stickyOffset - transitionHalfWidth * linearProgress * linearProgress
    }

    private var trackLabelWidth: CGFloat { 104 }

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
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .buttonStyle(.glassProminent)
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }
}
