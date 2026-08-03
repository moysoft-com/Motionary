// Timeline track content and clip/track drag coordination.

import SwiftUI

private struct VisibleTimelineTrack: Identifiable {
    let index: Int
    let track: TimelineTrack

    var id: UUID { track.id }
}

struct TimelineTracksContent: View {
    let snapshot: TimelineRenderSnapshot
    let viewModel: EditorViewModel
    @Binding var activeClipDrag: TimelineClipDragState?
    @Binding var activeTrackDrag: TimelineTrackDragState?
    @Binding var activeTrimSnapTime: Double?
    @Binding var activeClipSnapKey: String?
    @ObservedObject var viewportState: TimelineViewportState
    let scrollPresentationState: TimelineScrollPresentationState
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let centerPadding: CGFloat
    let pixelsPerSecond: CGFloat
    let trackHeight: CGFloat
    let rowSpacing: CGFloat
    @Binding var clipDragScrollOffset: CGSize

    @State private var clipDragPlacementSession: TimelinePlacementDragSession?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.deselectTimeline()
                }

            ZStack(alignment: .topLeading) {
                ForEach(visibleTracks) { visible in
                    trackRow(track: visible.track, index: visible.index)
                        .offset(y: CGFloat(visible.index) * (trackHeight + rowSpacing))
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
                let ghostItem = dragGhostItem(for: activeClipDrag)
                TimelineItemBlock(
                    item: ghostItem,
                    media: mediaDescriptor(for: ghostItem),
                    keyframeTimes: ghostItem.allKeyframeTimes,
                    visibleTimelineRange: viewportState.window.timeRange,
                    isSelected: activeClipDrag.selectedClipIDBeforeDrag == activeClipDrag.clipID,
                    isDragSourceHidden: false,
                    isDragGhost: true,
                    currentTime: 0,
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
        if activeClipDrag != nil {
            involvedTrackIndices.append(
                contentsOf: clipDragPlacementSession?.trackIndices(alignedAt: time) ?? []
            )
        } else {
            for (index, track) in snapshot.tracks.enumerated() {
                let containsSnapTarget = track.items.contains { item in
                    item.id != movingClipID
                        && (abs(item.timelineStart - time) < 0.001
                            || abs(item.timelineEnd - time) < 0.001)
                }
                if containsSnapTarget {
                    involvedTrackIndices.append(index)
                }
            }
        }

        let minimumIndex = involvedTrackIndices.min() ?? movingTrackIndex
        let maximumIndex = involvedTrackIndices.max() ?? movingTrackIndex
        let minY = 30 + CGFloat(minimumIndex) * (trackHeight + rowSpacing) + 4
        let height = CGFloat(maximumIndex - minimumIndex) * (trackHeight + rowSpacing) + trackHeight - 8
        return (time, minY, height)
    }

    private func trackIndex(containing clipID: UUID) -> Int? {
        snapshot.tracks.firstIndex { track in
            track.items.contains { $0.id == clipID }
        }
    }

    private var visibleTrackIndices: [Int] {
        var indices = Set(viewportState.window.trackRange)
        if let selectedClipID = snapshot.selectedClipID,
            let selectedTrackIndex = trackIndex(containing: selectedClipID)
        {
            indices.insert(selectedTrackIndex)
        }
        if let activeClipDrag {
            indices.insert(activeClipDrag.sourceTrackIndex)
            indices.insert(activeClipDrag.resolvedPlacement.trackIndex)
        }
        if let activeTrackDrag {
            indices.insert(activeTrackDrag.sourceIndex)
            indices.insert(activeTrackDrag.targetIndex)
        }
        return indices
            .filter { snapshot.tracks.indices.contains($0) }
            .sorted()
    }

    private var visibleTracks: [VisibleTimelineTrack] {
        visibleTrackIndices.map {
            VisibleTimelineTrack(index: $0, track: snapshot.tracks[$0])
        }
    }

    private func trackRow(track: TimelineTrack, index: Int) -> some View {
        let retainedItemIDs = Set(
            [
                snapshot.selectedClipID,
                activeClipDrag?.clipID
            ].compactMap { $0 }
        )
        return TimelineTrackRow(
            track: track,
            items: snapshot.items(
                in: track.id,
                intersecting: viewportState.window.timeRange,
                retaining: retainedItemIDs
            ),
            trackIndex: index,
            trackCount: snapshot.tracks.count,
            selectedClipID: snapshot.selectedClipID,
            activeClipDrag: activeClipDrag,
            activeTrackDrag: activeTrackDrag,
            currentTime: 0,
            keyframeTolerance: snapshot.keyframeTolerance,
            projectDuration: snapshot.duration,
            pixelsPerSecond: pixelsPerSecond,
            centerPadding: centerPadding,
            visibleTimelineRange: viewportState.window.timeRange,
            scrollPresentationState: scrollPresentationState,
            height: trackHeight,
            rowStride: trackHeight + rowSpacing,
            onSelectTrack: { viewModel.selectClip(nil, trackID: track.id) },
            onTapEmptySpace: { viewModel.deselectTimeline() },
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
            onClipDragChanged: { clip, value in
                updateClipDrag(clip, dragValue: value)
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
            mediaForItem: mediaDescriptor,
            onSnapGuideChanged: { time in
                activeTrimSnapTime = time
            },
            onTrackDragBegan: {
                beginTrackDrag(trackID: track.id, sourceIndex: index)
            },
            onTrackDragChanged: { value in
                updateTrackDrag(trackID: track.id, translation: value.translation)
            },
            onTrackDragEnded: { commit in
                finishTrackDrag(commit: commit)
            }
        )
    }

    private func dragGhostItem(for drag: TimelineClipDragState) -> TimelineItem {
        var item = drag.itemSnapshot
        item.timelineStart = drag.resolvedPlacement.start
        return item
    }

    private func mediaDescriptor(for item: TimelineItem) -> ClipMediaDescriptor? {
        guard let clip = item.legacyClip() else { return nil }
        return viewModel.project.mediaDescriptor(for: clip)
    }

    private func beginClipDrag(_ clip: TimelineItem, sourceTrackIndex: Int, trackID: UUID) {
        guard let placementSession = viewModel.makeClipPlacementDragSession(clip.id) else {
            return
        }
        clipDragPlacementSession = placementSession
        let previousClipID = viewModel.selectedClipID
        let previousTrackID = viewModel.selectedTrackID
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
            itemSnapshot: clip,
            selectedClipIDBeforeDrag: previousClipID,
            selectedTrackIDBeforeDrag: previousTrackID,
            fingerLocationInWindow: nil
        )
        viewModel.selectClip(clip.id, trackID: trackID)
        EditorHaptics.dragStart()
    }

    private func updateClipDrag(_ clip: TimelineItem, dragValue: TimelineLongPressDragValue) {
        guard let currentDrag = activeClipDrag,
            currentDrag.clipID == clip.id,
            let placementSession = clipDragPlacementSession,
            placementSession.itemID == clip.id
        else { return }
        let adjustedTranslation = CGSize(
            width: dragValue.translation.width + clipDragScrollOffset.width,
            height: dragValue.translation.height + clipDragScrollOffset.height
        )
        let rawStart = currentDrag.startTimelineStart + Double(adjustedTranslation.width / max(pixelsPerSecond, 1))
        let targetIndex = targetTrackIndex(
            sourceTrackIndex: currentDrag.sourceTrackIndex,
            translationY: adjustedTranslation.height,
            currentTargetIndex: currentDrag.resolvedPlacement.trackIndex
        )
        let placement = placementSession.resolve(
            proposedStart: rawStart,
            proposedTrackIndex: targetIndex
        )
        updateClipSnapHaptic(placement)
        activeClipDrag = TimelineClipDragState(
            clipID: clip.id,
            sourceTrackIndex: currentDrag.sourceTrackIndex,
            startTimelineStart: currentDrag.startTimelineStart,
            resolvedPlacement: placement,
            itemSnapshot: currentDrag.itemSnapshot,
            selectedClipIDBeforeDrag: currentDrag.selectedClipIDBeforeDrag,
            selectedTrackIDBeforeDrag: currentDrag.selectedTrackIDBeforeDrag,
            fingerLocationInWindow: dragValue.locationInWindow
        )
    }

    private func finishClipDrag(commit: Bool) {
        defer {
            activeClipDrag = nil
            activeClipSnapKey = nil
            clipDragPlacementSession = nil
        }
        guard let drag = activeClipDrag else { return }
        if commit {
            _ = viewModel.placeClip(drag.clipID, using: drag.resolvedPlacement, interactive: true)
            viewModel.finishInteractiveEdit()
            viewModel.selectClip(drag.clipID)
            EditorHaptics.editCommit()
        } else {
            viewModel.selectClip(
                drag.selectedClipIDBeforeDrag,
                trackID: drag.selectedClipIDBeforeDrag == nil
                    ? drag.selectedTrackIDBeforeDrag
                    : nil
            )
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
