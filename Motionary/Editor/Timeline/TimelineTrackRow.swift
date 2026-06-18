// Timeline track row presentation, selection, deletion, and reorder interactions.

import SwiftUI

struct TimelineTrackRow: View {
    let track: TimelineTrack
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
    let height: CGFloat
    let rowStride: CGFloat
    let onSelectTrack: () -> Void
    let onDeleteTrack: () -> Void
    let onSelectClip: (UUID) -> Void
    let onBeginEditClip: (UUID) -> Void
    let onClipDragBegan: (TimelineClip) -> Void
    let onClipDragChanged: (TimelineClip, CGSize) -> Void
    let onClipDragEnded: (Bool) -> Void
    let onTrimStart: (UUID, Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (UUID, Double, TimelineClip?) -> TimelineTrimResult?
    let onTrimEnd: (UUID, Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (UUID, Double, TimelineClip?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let onSnapGuideChanged: (Double?) -> Void
    let onTrackDragBegan: () -> Void
    let onTrackDragChanged: (CGSize) -> Void
    let onTrackDragEnded: (Bool) -> Void

    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        ZStack(alignment: .leading) {
            trackLabel
                .offset(x: 10)
                .overlay(
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
                )
                .zIndex(activeTrackDrag?.trackID == track.id ? 4 : 0)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .frame(width: max(10 + CGFloat(projectDuration) * pixelsPerSecond, 0), height: height)
                .offset(x: centerPadding - 5)

            ForEach(track.clips) { clip in
                TimelineClipBlock(
                    clip: clip,
                    isSelected: selectedClipID == clip.id,
                    isDragSourceHidden: activeClipDrag?.clipID == clip.id,
                    isDragGhost: false,
                    currentTime: currentTime,
                    keyframeTolerance: keyframeTolerance,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height - 8,
                    allowsClipInteraction: true,
                    onSelect: { onSelectClip(clip.id) },
                    onBeginEdit: { onBeginEditClip(clip.id) },
                    onClipDragBegan: { onClipDragBegan(clip) },
                    onClipDragChanged: { translation in onClipDragChanged(clip, translation) },
                    onClipDragEnded: onClipDragEnded,
                    onTrimStart: { delta, baseline, interactive in onTrimStart(clip.id, delta, baseline, interactive) },
                    onPreviewTrimStart: { delta, baseline in onPreviewTrimStart(clip.id, delta, baseline) },
                    onTrimEnd: { delta, baseline, interactive in onTrimEnd(clip.id, delta, baseline, interactive) },
                    onPreviewTrimEnd: { delta, baseline in onPreviewTrimEnd(clip.id, delta, baseline) },
                    onFinishInteractiveEdit: onFinishInteractiveEdit,
                    onSnapGuideChanged: onSnapGuideChanged
                )
                .offset(x: centerPadding + CGFloat(clip.timelineStart) * pixelsPerSecond)
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
                : (track.clips.contains { $0.id == selectedClipID } ? 100 : 0)
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
        .frame(width: 104, height: height, alignment: .leading)
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
