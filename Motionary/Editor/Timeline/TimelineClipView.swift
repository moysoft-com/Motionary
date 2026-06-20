// Timeline clip block, trim handles, and clip-level gesture state.

import SwiftUI

struct TimelineTrimPreview {
    let clip: TimelineClip
    let result: TimelineTrimResult
}

struct TimelineClipBlock: View {
    let clip: TimelineClip
    let isSelected: Bool
    let isDragSourceHidden: Bool
    let isDragGhost: Bool
    let currentTime: Double
    let keyframeTolerance: Double
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let allowsClipInteraction: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onClipDragBegan: () -> Void
    let onClipDragChanged: (CGSize) -> Void
    let onClipDragEnded: (Bool) -> Void
    let onTrimStart: (Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (Double, TimelineClip?) -> TimelineTrimResult?
    let onTrimEnd: (Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (Double, TimelineClip?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let onSnapGuideChanged: (Double?) -> Void

    @State private var trimBaseline: TimelineClip?
    @State private var trimPreview: TimelineTrimPreview?
    @State private var committedInteractiveEdit = false
    @State private var activeSnapKey: String?
    @State private var lastSnapFeedbackKey: String?
    @State private var lastSnapFeedbackAt: Date = .distantPast

    var body: some View {
        let previewClip = displayedClip
        let mediaClip = trimBaseline ?? previewClip
        let mediaSampleWidth = trimBaseline.map { CGFloat($0.sourceRange.duration) * pixelsPerSecond }
        let displayWidth = max(CGFloat(previewClip.sourceRange.duration) * pixelsPerSecond, 6)
        let displayOffsetX =
            isDragSourceHidden ? 0 : CGFloat(previewClip.timelineStart - clip.timelineStart) * pixelsPerSecond
        let isEditing = trimBaseline != nil
        let visualOpacity = isDragSourceHidden ? 0 : (isDragGhost ? 0.58 : 1)
        let selectionExtension: CGFloat = 9

        ZStack {
            if isSelected && !isDragSourceHidden && !isDragGhost {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white)
                    .frame(width: displayWidth + selectionExtension * 2, height: height + 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white, lineWidth: 2)
                    }
                    .allowsHitTesting(false)
                    .zIndex(0)
            }

            TimelineClipFill(
                clip: mediaClip,
                width: displayWidth,
                height: height,
                pixelsPerSecond: pixelsPerSecond,
                sampleWidth: mediaSampleWidth
            )
            .frame(width: displayWidth, height: height)
            .foregroundStyle(Color.black.opacity(0.88))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(clip.mediaType == .audio ? MotionaryTheme.audio : MotionaryTheme.video)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected && !isDragSourceHidden && isDragGhost ? Color.white : .clear,
                        lineWidth: 2
                    )
            }
            .opacity(visualOpacity)
            .shadow(color: .black.opacity(isDragGhost ? 0.24 : 0), radius: 10, y: 4)
            .zIndex(1)

            if !isDragSourceHidden && !isDragGhost {
                TimelineKeyframeMarkers(
                    times: previewClip.allKeyframeTimes,
                    duration: previewClip.sourceRange.duration,
                    width: displayWidth,
                    height: height
                )
                .allowsHitTesting(false)
                .zIndex(2)
            }

            if allowsClipInteraction {
                TimelineLongPressInteractionTarget(
                    minimumPressDuration: 0.34,
                    allowableMovement: 16,
                    onTap: {
                        guard !isEditing else { return }
                        EditorHaptics.selection()
                        onSelect()
                    },
                    onLongPressBegan: {
                        guard !isEditing else { return }
                        onClipDragBegan()
                    },
                    onLongPressChanged: { translation in
                        onClipDragChanged(translation)
                    },
                    onLongPressEnded: { commit in
                        onClipDragEnded(commit)
                    }
                )
                .frame(width: displayWidth, height: height)
                .zIndex(3)
            }

        }
        .frame(width: displayWidth, height: height)
        .overlay(alignment: .leading) {
            if isSelected && allowsClipInteraction && !isDragSourceHidden {
                TrimHandle(edge: .leading, height: height, visibleWidth: selectionExtension)
                    .offset(x: -(TrimHandle.hitWidth + selectionExtension) * 0.5)
                    .gesture(trimStartGesture)
            }
        }
        .overlay(alignment: .trailing) {
            if isSelected && allowsClipInteraction && !isDragSourceHidden {
                TrimHandle(edge: .trailing, height: height, visibleWidth: selectionExtension)
                    .offset(x: (TrimHandle.hitWidth + selectionExtension) * 0.5)
                    .gesture(trimEndGesture)
            }
        }
        .offset(x: displayOffsetX)
        .shadow(color: .black.opacity(isEditing && !isDragSourceHidden && !isDragGhost ? 0.28 : 0), radius: 12, y: 5)
        .zIndex(isDragGhost ? 120 : (isSelected ? 100 : (isEditing ? 80 : 0)))
        .transaction { transaction in
            if isEditing || isDragSourceHidden || isDragGhost {
                transaction.animation = nil
            }
        }
        .animation(nil, value: displayWidth)
        .animation(nil, value: displayOffsetX)
        .onDisappear {
            finishTimelineGesture()
        }
    }

    private var displayedClip: TimelineClip {
        trimPreview?.clip ?? clip
    }

    private var trimStartGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let baseline = beginTrimIfNeeded()
                let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                guard let result = onPreviewTrimStart(seconds, baseline) else { return }
                trimPreview = TimelineTrimPreview(
                    clip: clipApplyingTrimStart(result, to: baseline),
                    result: result
                )
                onSnapGuideChanged(result.snapped ? result.edgeTime : nil)
                updateSnapHaptic(kind: "trim-start", snapped: result.snapped, value: result.edgeTime)
            }
            .onEnded { value in
                if let trimBaseline {
                    let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                    let committedDelta = trimPreview?.result.appliedDelta ?? seconds
                    let result = onTrimStart(committedDelta, trimBaseline, true)
                    committedInteractiveEdit = true
                    updateSnapHaptic(kind: "trim-start", snapped: result?.snapped == true, value: result?.edgeTime)
                }
                finishTimelineGesture()
            }
    }

    private var trimEndGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let baseline = beginTrimIfNeeded()
                let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                guard let result = onPreviewTrimEnd(seconds, baseline) else { return }
                trimPreview = TimelineTrimPreview(
                    clip: clipApplyingTrimEnd(result, to: baseline),
                    result: result
                )
                onSnapGuideChanged(result.snapped ? result.edgeTime : nil)
                updateSnapHaptic(kind: "trim-end", snapped: result.snapped, value: result.edgeTime)
            }
            .onEnded { value in
                if let trimBaseline {
                    let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                    let committedDelta = trimPreview?.result.appliedDelta ?? seconds
                    let result = onTrimEnd(committedDelta, trimBaseline, true)
                    committedInteractiveEdit = true
                    updateSnapHaptic(kind: "trim-end", snapped: result?.snapped == true, value: result?.edgeTime)
                }
                finishTimelineGesture()
            }
    }

    private func beginTrimIfNeeded() -> TimelineClip {
        if let trimBaseline {
            return trimBaseline
        }

        trimBaseline = clip
        EditorHaptics.trimStart()
        onBeginEdit()
        return clip
    }

    private func clipApplyingTrimStart(_ result: TimelineTrimResult, to baseline: TimelineClip) -> TimelineClip {
        var preview = baseline
        preview.timelineStart = result.edgeTime
        preview.sourceRange = TimeRangeValue(
            start: baseline.sourceRange.start + result.appliedDelta,
            duration: max(baseline.sourceRange.duration - result.appliedDelta, 0.1)
        )
        return preview
    }

    private func clipApplyingTrimEnd(_ result: TimelineTrimResult, to baseline: TimelineClip) -> TimelineClip {
        var preview = baseline
        preview.sourceRange = TimeRangeValue(
            start: baseline.sourceRange.start,
            duration: max(baseline.sourceRange.duration + result.appliedDelta, 0.1)
        )
        return preview
    }

    private func finishTimelineGesture() {
        if committedInteractiveEdit {
            onFinishInteractiveEdit()
            EditorHaptics.editCommit()
        }

        trimBaseline = nil
        trimPreview = nil
        committedInteractiveEdit = false
        activeSnapKey = nil
        onSnapGuideChanged(nil)
    }

    private func updateSnapHaptic(kind: String, snapped: Bool, value: Double?) {
        let key = snapped ? "\(kind)-\(Int(((value ?? 0) * 1000).rounded()))" : nil
        let previousKey = activeSnapKey
        activeSnapKey = key
        guard let key, key != previousKey else { return }

        let now = Date()
        if key == lastSnapFeedbackKey,
            now.timeIntervalSince(lastSnapFeedbackAt) < 0.35
        {
            return
        }

        lastSnapFeedbackKey = key
        lastSnapFeedbackAt = now
        EditorHaptics.snap()
    }
}

private struct TimelineKeyframeMarkers: View {
    let times: [Double]
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(times, id: \.self) { time in
                KeyframeDiamondShape()
                    .fill(Color.clear)
                    .overlay {
                        KeyframeDiamondShape()
                            .stroke(Color.white.opacity(0.72), lineWidth: 1.2)
                    }
                    .frame(width: 9, height: 9)
                    .position(
                        x: min(
                            max(CGFloat(time / max(duration, 0.001)) * width, 7),
                            max(width - 7, 7)
                        ),
                        y: height * 0.5
                    )
                    .shadow(color: .black.opacity(0.55), radius: 1)
            }
        }
        .frame(width: width, height: height)
    }
}

enum TrimHandleEdge {
    case leading
    case trailing
}

struct TimelineClipFill: View {
    let clip: TimelineClip
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat
    let sampleWidth: CGFloat?

    @Environment(\.displayScale) private var displayScale
    @State private var waveformSamples: [CGFloat] = []

    var body: some View {
        let thumbnailWidth = timelineThumbnailWidth
        let thumbnailCount = max(Int(ceil(width / max(thumbnailWidth, 1))) + 1, 1)
        let waveformCount = quantizedWaveformSampleCount

        ZStack {
            if clip.mediaType == .audio {
                TimelineWaveformView(samples: activeWaveformSamples)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<thumbnailCount, id: \.self) { index in
                            TimelineThumbnailTile(
                                clip: clip,
                                tileIndex: index,
                                tileWidth: thumbnailWidth,
                                height: height,
                                pixelsPerSecond: pixelsPerSecond,
                                displayScale: displayScale
                            )
                            .frame(width: thumbnailWidth, height: height)
                        }
                    }
                }
                .scrollDisabled(true)
                .allowsHitTesting(false)
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
            }

        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: taskID) {
            let requestID = taskID
            if clip.mediaType == .audio {
                let samples = await TimelineAudioWaveformLoader.samples(
                    for: clip,
                    targetCount: waveformCount
                )
                guard !Task.isCancelled, requestID == taskID else { return }
                waveformSamples = samples
            }
        }
    }

    private var activeWaveformSamples: [CGFloat] {
        if !waveformSamples.isEmpty {
            return waveformSamples
        }
        return Array(repeating: 0.02, count: quantizedWaveformSampleCount)
    }

    private var timelineThumbnailWidth: CGFloat {
        let storedSize = clip.source.naturalSize?.cgSize ?? CGSize(width: 16, height: 9)
        let naturalSize = CGSize(width: max(abs(storedSize.width), 1), height: max(abs(storedSize.height), 1))
        let aspectRatio = min(max(naturalSize.width / max(naturalSize.height, 1), 0.35), 4)
        return max(height * aspectRatio, 24)
    }

    private var quantizedWaveformSampleCount: Int {
        let rawCount = min(max(Int((sampleWidth ?? width) / 2), 80), 900)
        return max(Int((Double(rawCount) / 24).rounded()) * 24, 72)
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(Int(ceil(width / max(timelineThumbnailWidth, 1))))",
            "\(Int(timelineThumbnailWidth.rounded()))",
            "\(quantizedWaveformSampleCount)",
            "\(Int(displayScale.rounded()))",
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
    }
}

struct TrimHandle: View {
    static let hitWidth: CGFloat = 22

    let edge: TrimHandleEdge
    let height: CGFloat
    let visibleWidth: CGFloat

    var body: some View {
        Color.clear
            .frame(width: Self.hitWidth, height: height + 8)
            .overlay {
                Capsule()
                    .fill(Color.gray.opacity(0.72))
                    .frame(width: 2, height: max(min(height * 0.42, 18), 12))
            }
            .contentShape(Rectangle())
            .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
    }
}
