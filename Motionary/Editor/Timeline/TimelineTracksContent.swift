// Timeline track content and clip/track drag coordination.

import SwiftUI

struct TimelineTracksContent: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var activeClipDrag: TimelineClipDragState?
    @Binding var activeTrackDrag: TimelineTrackDragState?
    @Binding var activeTrimSnapTime: Double?
    @Binding var activeClipSnapKey: String?
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let centerPadding: CGFloat
    let pixelsPerSecond: CGFloat
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.deselectTimeline()
                }

            VStack(spacing: rowSpacing) {
                ForEach(Array(viewModel.project.tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                }
            }
            .offset(y: 30)

            if let guide = activeSnapGuide {
                TimelineSnapGuideLine(height: guide.height)
                    .offset(
                        x: centerPadding + CGFloat(guide.time) * pixelsPerSecond - 0.75,
                        y: guide.minY
                    )
                    .zIndex(1_000)
                    .allowsHitTesting(false)
            }

            if let activeClipDrag {
                TimelineClipBlock(
                    clip: dragGhostClip(for: activeClipDrag),
                    isSelected: activeClipDrag.selectedClipIDBeforeDrag == activeClipDrag.clipID,
                    isDragSourceHidden: false,
                    isDragGhost: true,
                    currentTime: viewModel.currentTime,
                    keyframeTolerance: viewModel.keyframeTimeTolerance,
                    pixelsPerSecond: pixelsPerSecond,
                    height: trackHeight - 8,
                    allowsClipInteraction: false,
                    onSelect: {},
                    onBeginEdit: {},
                    onClipDragBegan: {},
                    onClipDragChanged: { _ in },
                    onClipDragEnded: { _ in },
                    onTrimStart: { _, _, _ in nil },
                    onPreviewTrimStart: { _, _ in nil },
                    onTrimEnd: { _, _, _ in nil },
                    onPreviewTrimEnd: { _, _ in nil },
                    onFinishInteractiveEdit: {},
                    onSnapGuideChanged: { _ in }
                )
                .allowsHitTesting(false)
                .offset(
                    x: centerPadding + CGFloat(activeClipDrag.resolvedPlacement.start) * pixelsPerSecond,
                    y: 30 + CGFloat(activeClipDrag.resolvedPlacement.trackIndex) * (trackHeight + rowSpacing) + 4
                )
                .zIndex(500)
                .transaction { $0.animation = nil }
            }
        }
        .frame(width: contentWidth, height: max(contentHeight, containerHeight), alignment: .topLeading)
        .offset(y: 8)
    }

    private var activeSnapGuide: (time: Double, minY: CGFloat, height: CGFloat)? {
        let movingClipID: UUID
        let movingTrackIndex: Int
        let time: Double

        if let drag = activeClipDrag, let snapTime = drag.resolvedPlacement.snapTime {
            movingClipID = drag.clipID
            movingTrackIndex = drag.resolvedPlacement.trackIndex
            time = snapTime
        } else if let trimTime = activeTrimSnapTime,
            let selectedClipID = viewModel.selectedClipID,
            let selectedTrackIndex = trackIndex(containing: selectedClipID)
        {
            movingClipID = selectedClipID
            movingTrackIndex = selectedTrackIndex
            time = trimTime
        } else {
            return nil
        }

        var involvedTrackIndices = [movingTrackIndex]
        for (index, track) in viewModel.project.tracks.enumerated() {
            let containsSnapTarget = track.clips.contains { clip in
                clip.id != movingClipID
                    && (abs(clip.timelineStart - time) < 0.001 || abs(clip.timelineEnd - time) < 0.001)
            }
            if containsSnapTarget {
                involvedTrackIndices.append(index)
            }
        }

        let minimumIndex = involvedTrackIndices.min() ?? movingTrackIndex
        let maximumIndex = involvedTrackIndices.max() ?? movingTrackIndex
        let minY = 30 + CGFloat(minimumIndex) * (trackHeight + rowSpacing) + 4
        let height = CGFloat(maximumIndex - minimumIndex) * (trackHeight + rowSpacing) + trackHeight - 8
        return (time, minY, height)
    }

    private func trackIndex(containing clipID: UUID) -> Int? {
        viewModel.project.tracks.firstIndex { track in
            track.clips.contains { $0.id == clipID }
        }
    }

    private func trackRow(track: TimelineTrack, index: Int) -> some View {
        TimelineTrackRow(
            track: track,
            trackIndex: index,
            trackCount: viewModel.project.tracks.count,
            selectedClipID: viewModel.selectedClipID,
            activeClipDrag: activeClipDrag,
            activeTrackDrag: activeTrackDrag,
            currentTime: viewModel.currentTime,
            keyframeTolerance: viewModel.keyframeTimeTolerance,
            projectDuration: viewModel.duration,
            pixelsPerSecond: pixelsPerSecond,
            centerPadding: centerPadding,
            height: trackHeight,
            rowStride: trackHeight + rowSpacing,
            onSelectTrack: { viewModel.selectClip(nil, trackID: track.id) },
            onDeleteTrack: { viewModel.deleteLayer(track.id) },
            onSelectClip: { clipID in
                viewModel.selectClip(clipID, trackID: track.id, revealInPreview: true)
            },
            onBeginEditClip: { clipID in
                viewModel.selectClip(clipID, trackID: track.id)
            },
            onClipDragBegan: { clip in
                beginClipDrag(clip, sourceTrackIndex: index, trackID: track.id)
            },
            onClipDragChanged: { clip, translation in
                updateClipDrag(clip, translation: translation)
            },
            onClipDragEnded: { commit in
                finishClipDrag(commit: commit)
            },
            onTrimStart: { clipID, delta, baseline, interactive in
                viewModel.selectClip(clipID, trackID: track.id)
                return viewModel.trimClipStart(
                    clipID,
                    by: delta,
                    baseline: baseline,
                    interactive: interactive
                )
            },
            onPreviewTrimStart: { clipID, delta, baseline in
                viewModel.previewTrimClipStart(
                    clipID,
                    by: delta,
                    baseline: baseline
                )
            },
            onTrimEnd: { clipID, delta, baseline, interactive in
                viewModel.selectClip(clipID, trackID: track.id)
                return viewModel.trimClipEnd(
                    clipID,
                    by: delta,
                    baseline: baseline,
                    interactive: interactive
                )
            },
            onPreviewTrimEnd: { clipID, delta, baseline in
                viewModel.previewTrimClipEnd(
                    clipID,
                    by: delta,
                    baseline: baseline
                )
            },
            onFinishInteractiveEdit: {
                viewModel.finishInteractiveEdit()
            },
            onSnapGuideChanged: { time in
                activeTrimSnapTime = time
            },
            onTrackDragBegan: {
                beginTrackDrag(trackID: track.id, sourceIndex: index)
            },
            onTrackDragChanged: { translation in
                updateTrackDrag(trackID: track.id, translation: translation)
            },
            onTrackDragEnded: { commit in
                finishTrackDrag(commit: commit)
            }
        )
    }

    private func dragGhostClip(for drag: TimelineClipDragState) -> TimelineClip {
        var clip = drag.clipSnapshot
        clip.timelineStart = drag.resolvedPlacement.start
        return clip
    }

    private func beginClipDrag(_ clip: TimelineClip, sourceTrackIndex: Int, trackID: UUID) {
        activeClipDrag = TimelineClipDragState(
            clipID: clip.id,
            sourceTrackIndex: sourceTrackIndex,
            startTimelineStart: clip.timelineStart,
            resolvedPlacement: TimelinePlacementResult(
                start: clip.timelineStart,
                trackIndex: sourceTrackIndex,
                snapped: false,
                snapTime: nil
            ),
            clipSnapshot: clip,
            selectedClipIDBeforeDrag: viewModel.selectedClipID,
            selectedTrackIDBeforeDrag: viewModel.selectedTrackID
        )
        EditorHaptics.dragStart()
    }

    private func updateClipDrag(_ clip: TimelineClip, translation: CGSize) {
        guard let currentDrag = activeClipDrag, currentDrag.clipID == clip.id else { return }
        let rawStart = currentDrag.startTimelineStart + Double(translation.width / max(pixelsPerSecond, 1))
        let targetIndex = targetTrackIndex(
            sourceTrackIndex: currentDrag.sourceTrackIndex,
            translationY: translation.height,
            currentTargetIndex: currentDrag.resolvedPlacement.trackIndex
        )
        let placement =
            viewModel.resolveClipPlacement(
                clip.id,
                at: rawStart,
                proposedTrackIndex: targetIndex
            )
            ?? TimelinePlacementResult(start: max(0, rawStart), trackIndex: targetIndex, snapped: false, snapTime: nil)
        updateClipSnapHaptic(placement)
        activeClipDrag = TimelineClipDragState(
            clipID: clip.id,
            sourceTrackIndex: currentDrag.sourceTrackIndex,
            startTimelineStart: currentDrag.startTimelineStart,
            resolvedPlacement: placement,
            clipSnapshot: currentDrag.clipSnapshot,
            selectedClipIDBeforeDrag: currentDrag.selectedClipIDBeforeDrag,
            selectedTrackIDBeforeDrag: currentDrag.selectedTrackIDBeforeDrag
        )
    }

    private func finishClipDrag(commit: Bool) {
        defer {
            activeClipDrag = nil
            activeClipSnapKey = nil
        }
        guard let drag = activeClipDrag else { return }
        if commit {
            _ = viewModel.placeClip(drag.clipID, using: drag.resolvedPlacement, interactive: true)
            viewModel.finishInteractiveEdit()
            viewModel.selectClip(
                drag.selectedClipIDBeforeDrag,
                trackID: drag.selectedClipIDBeforeDrag == nil
                    ? drag.selectedTrackIDBeforeDrag
                    : nil
            )
            EditorHaptics.editCommit()
        }
    }

    private func beginTrackDrag(trackID: UUID, sourceIndex: Int) {
        activeTrackDrag = TimelineTrackDragState(
            trackID: trackID,
            sourceIndex: sourceIndex,
            targetIndex: sourceIndex,
            translationY: 0
        )
        timelineDragHaptic()
    }

    private func updateTrackDrag(trackID: UUID, translation: CGSize) {
        guard let drag = activeTrackDrag, drag.trackID == trackID else { return }
        let stride = max(trackHeight + rowSpacing, 1)
        let minimumY = -CGFloat(drag.sourceIndex) * stride
        let maximumY = CGFloat(max(viewModel.project.tracks.count - 1 - drag.sourceIndex, 0)) * stride
        let clampedTranslation = CGSize(
            width: 0,
            height: min(max(translation.height, minimumY), maximumY)
        )
        let targetIndex = targetTrackIndex(
            sourceTrackIndex: drag.sourceIndex,
            translationY: clampedTranslation.height
        )
        if targetIndex != drag.targetIndex {
            EditorHaptics.tap()
        }
        activeTrackDrag = TimelineTrackDragState(
            trackID: trackID,
            sourceIndex: drag.sourceIndex,
            targetIndex: targetIndex,
            translationY: clampedTranslation.height
        )
    }

    private func finishTrackDrag(commit: Bool) {
        guard let drag = activeTrackDrag else { return }
        activeTrackDrag = nil
        if commit {
            viewModel.moveTrack(drag.trackID, to: drag.targetIndex)
        }
    }

    private func targetTrackIndex(
        sourceTrackIndex: Int,
        translationY: CGFloat,
        currentTargetIndex: Int? = nil
    ) -> Int {
        let rowPosition = CGFloat(sourceTrackIndex) + translationY / max(trackHeight + rowSpacing, 1)
        return min(max(Int(rowPosition.rounded()), 0), max(viewModel.project.tracks.count - 1, 0))
    }

    private func updateClipSnapHaptic(_ placement: TimelinePlacementResult) {
        let key =
            placement.snapped
            ? placement.snapTime.map { "drag-\(Int(($0 * 1000).rounded()))" }
            : nil
        let previousKey = activeClipSnapKey
        activeClipSnapKey = key
        if let key, key != previousKey {
            EditorHaptics.snap()
        }
    }
}
