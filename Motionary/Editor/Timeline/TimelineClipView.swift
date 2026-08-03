// Typed timeline item block, trim handles, and item-level gesture state.

import SwiftUI

struct TimelineTrimPreview {
    let item: TimelineItem
    let result: TimelineTrimResult
}

struct TimelineItemBlock: View {
    let item: TimelineItem
    let media: ClipMediaDescriptor?
    let keyframeTimes: [Double]
    let visibleTimelineRange: ClosedRange<Double>
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
    let onClipDragChanged: (TimelineLongPressDragValue) -> Void
    let onClipDragEnded: (Bool) -> Void
    let onTrimStart: (Double, TimelineItem?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (Double, TimelineItem?) -> TimelineTrimResult?
    let onTrimEnd: (Double, TimelineItem?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (Double, TimelineItem?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let onSnapGuideChanged: (Double?) -> Void

    @State private var trimBaseline: TimelineItem?
    @State private var trimPreview: TimelineTrimPreview?
    @State private var committedInteractiveEdit = false
    @State private var activeSnapKey: String?
    @State private var lastSnapFeedbackKey: String?
    @State private var lastSnapFeedbackAt: Date = .distantPast

    var body: some View {
        let previewItem = displayedItem
        let mediaClip = (trimBaseline ?? previewItem).legacyClip()
        let mediaSampleWidth = trimBaseline.map {
            CGFloat(timelineDisplayDuration(for: $0)) * pixelsPerSecond
        }
        let mediaSampleOffsetX = trimBaseline.map {
            CGFloat($0.timelineStart - previewItem.timelineStart) * pixelsPerSecond
        } ?? 0
        let displayDuration = timelineDisplayDuration(for: previewItem)
        let displayWidth = max(CGFloat(displayDuration) * pixelsPerSecond, 6)
        let displayOffsetX =
            isDragSourceHidden ? 0 : CGFloat(previewItem.timelineStart - item.timelineStart) * pixelsPerSecond
        let isEditing = trimBaseline != nil
        let visualOpacity = isDragSourceHidden ? 0 : (isDragGhost ? 0.58 : 1)
        let selectionExtension: CGFloat = 9

        ZStack {
            if isSelected && !isDragSourceHidden && !isDragGhost {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(MotionaryTheme.selected)
                    .frame(width: displayWidth + selectionExtension * 2, height: height + 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(MotionaryTheme.selected, lineWidth: 2)
                    }
                    .allowsHitTesting(false)
                    .zIndex(0)
            }

            TimelineItemVisualFill(
                item: previewItem,
                media: media,
                mediaClip: mediaClip,
                width: displayWidth,
                height: height,
                pixelsPerSecond: pixelsPerSecond,
                sampleWidth: mediaSampleWidth,
                sampleOffsetX: mediaSampleOffsetX,
                visibleTimelineRange: visibleTimelineRange
            )
            .frame(width: displayWidth, height: height)
            .foregroundStyle(Color.black.opacity(0.88))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(timelineItemTint(for: previewItem))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected && !isDragSourceHidden && isDragGhost ? MotionaryTheme.selected : .clear,
                        lineWidth: 2
                    )
            }
            .opacity(visualOpacity)
            .shadow(color: .black.opacity(isDragGhost ? 0.24 : 0), radius: 10, y: 4)
            .zIndex(1)

            if !isDragSourceHidden && !isDragGhost {
                if case .media(let mediaItem) = previewItem,
                    mediaItem.mediaType == .audio,
                    !mediaItem.visibleBeatMarkers.isEmpty
                {
                    TimelineBeatMarkers(
                        markers: mediaItem.visibleBeatMarkers,
                        duration: displayDuration,
                        width: displayWidth,
                        height: height,
                        itemTimelineStart: previewItem.timelineStart,
                        visibleTimelineRange: visibleTimelineRange
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)
                }

                TimelineKeyframeMarkers(
                    times: displayedKeyframeTimes(for: previewItem),
                    duration: displayDuration,
                    width: displayWidth,
                    height: height,
                    itemTimelineStart: previewItem.timelineStart,
                    visibleTimelineRange: visibleTimelineRange
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
                    onLongPressChanged: onClipDragChanged,
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
            DispatchQueue.main.async {
                finishTimelineGesture()
            }
        }
    }

    private var displayedItem: TimelineItem {
        trimPreview?.item ?? item
    }

    private func displayedKeyframeTimes(for item: TimelineItem) -> [Double] {
        trimBaseline == nil ? keyframeTimes : item.allKeyframeTimes
    }

    private func timelineDisplayDuration(for item: TimelineItem) -> Double {
        switch item {
        case .media(let mediaItem): mediaItem.timelineDuration
        case .shape(let shapeItem): shapeItem.sourceRange.duration
        case .text(let textItem): textItem.duration
        case .caption(let caption): caption.duration
        case .adjustment(let adjustment): adjustment.duration
        case .compound(let compound): compound.duration
        }
    }

    private var trimStartGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let baseline = beginTrimIfNeeded()
                let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                guard let result = onPreviewTrimStart(seconds, baseline) else { return }
                trimPreview = TimelineTrimPreview(
                    item: baseline.trimmingStart(by: result.appliedDelta),
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
                    item: baseline.trimmingEnd(by: result.appliedDelta),
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

    private func beginTrimIfNeeded() -> TimelineItem {
        if let trimBaseline {
            return trimBaseline
        }

        trimBaseline = item
        EditorHaptics.trimStart()
        onBeginEdit()
        return item
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

private struct TimelineItemLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct TimelineKeyframeMarkers: View {
    let times: [Double]
    let duration: Double
    let width: CGFloat
    let height: CGFloat
    let itemTimelineStart: Double
    let visibleTimelineRange: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let localVisibleStart = max(visibleTimelineRange.lowerBound - itemTimelineStart, 0)
            let localVisibleEnd = min(
                visibleTimelineRange.upperBound - itemTimelineStart,
                duration
            )
            guard localVisibleEnd >= localVisibleStart else { return }

            let firstIndex = lowerBoundIndex(in: times, value: localVisibleStart)
            var index = firstIndex
            while index < times.count, times[index] <= localVisibleEnd {
                let x = min(
                    max(CGFloat(times[index] / max(duration, 0.001)) * size.width, 7),
                    max(size.width - 7, 7)
                )
                let y = size.height * 0.5
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: y - 4.5))
                diamond.addLine(to: CGPoint(x: x + 4.5, y: y))
                diamond.addLine(to: CGPoint(x: x, y: y + 4.5))
                diamond.addLine(to: CGPoint(x: x - 4.5, y: y))
                diamond.closeSubpath()
                context.stroke(
                    diamond,
                    with: .color(MotionaryTheme.control.opacity(0.72)),
                    lineWidth: 1.2
                )
                index += 1
            }
        }
        .frame(width: width, height: height)
    }

    private func lowerBoundIndex(in values: [Double], value: Double) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if values[midpoint] < value {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }
}

private struct TimelineBeatMarkers: View {
    let markers: [TimelineBeatMarker]
    let duration: Double
    let width: CGFloat
    let height: CGFloat
    let itemTimelineStart: Double
    let visibleTimelineRange: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let localVisibleStart = max(
                visibleTimelineRange.lowerBound - itemTimelineStart,
                0
            )
            let localVisibleEnd = min(
                visibleTimelineRange.upperBound - itemTimelineStart,
                duration
            )
            guard localVisibleEnd >= localVisibleStart else { return }

            var index = lowerBoundIndex(
                in: markers,
                localTimelineTime: localVisibleStart
            )
            while index < markers.count,
                markers[index].localTimelineTime <= localVisibleEnd
            {
                let marker = markers[index]
                let x = min(
                    max(CGFloat(marker.localTimelineTime / max(duration, 0.001)) * size.width, 1),
                    max(size.width - 1, 1)
                )
                var path = Path()
                path.move(to: CGPoint(x: x, y: 6))
                path.addLine(to: CGPoint(x: x, y: max(size.height - 6, 6)))
                context.stroke(
                    path,
                    with: .color(.yellow),
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round
                    )
                )
                index += 1
            }
        }
        .frame(width: width, height: height)
    }

    private func lowerBoundIndex(
        in values: [TimelineBeatMarker],
        localTimelineTime: Double
    ) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if values[midpoint].localTimelineTime < localTimelineTime {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }
}

enum TrimHandleEdge {
    case leading
    case trailing
}

struct TimelineItemVisualFill: View {
    let item: TimelineItem
    let media: ClipMediaDescriptor?
    let mediaClip: TimelineClip?
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat
    let sampleWidth: CGFloat?
    let sampleOffsetX: CGFloat
    var visibleTimelineRange: ClosedRange<Double>? = nil

    @ViewBuilder
    var body: some View {
        switch item {
        case .shape:
            if let mediaClip, let media {
                TimelineClipFill(
                    clip: mediaClip,
                    media: media,
                    speedMap: .constant,
                    width: width,
                    height: height,
                    pixelsPerSecond: pixelsPerSecond,
                    sampleWidth: sampleWidth,
                    sampleOffsetX: sampleOffsetX,
                    visibleTimelineRange: visibleTimelineRange
                )
            } else {
                Color.orange
            }
        case .media(let mediaItem):
            if let mediaClip, let media {
                TimelineClipFill(
                    clip: mediaClip,
                    media: media,
                    speedMap: mediaItem.speedMap,
                    width: width,
                    height: height,
                    pixelsPerSecond: pixelsPerSecond,
                    sampleWidth: sampleWidth,
                    sampleOffsetX: sampleOffsetX,
                    visibleTimelineRange: visibleTimelineRange
                )
            } else {
                TimelineItemLabel(icon: timelineItemIcon(for: item), title: timelineItemTitle(for: item))
            }
        case .text, .caption, .adjustment, .compound:
            TimelineItemLabel(icon: timelineItemIcon(for: item), title: timelineItemTitle(for: item))
        }
    }
}

func timelineItemTint(for item: TimelineItem) -> Color {
    switch item {
    case .media(let mediaItem):
        mediaItem.mediaType == .audio ? MotionaryTheme.audio : MotionaryTheme.video
    case .shape:
        .orange
    case .text:
        Color(red: 0.96, green: 0.48, blue: 0.70)
    case .caption:
        Color(red: 0.96, green: 0.68, blue: 0.32)
    case .adjustment:
        Color(red: 0.38, green: 0.82, blue: 0.64)
    case .compound:
        Color(red: 0.48, green: 0.70, blue: 0.96)
    }
}

private func timelineItemIcon(for item: TimelineItem) -> String {
    switch item {
    case .media(let mediaItem): mediaItem.mediaType == .audio ? "waveform" : "film"
    case .shape: "square.on.circle"
    case .text: "textformat"
    case .caption: "captions.bubble"
    case .adjustment: "slider.horizontal.3"
    case .compound: "rectangle.stack"
    }
}

private func timelineItemTitle(for item: TimelineItem) -> String {
    switch item {
    case .media(let mediaItem): mediaItem.name
    case .shape(let shapeItem): shapeItem.name
    case .text(let textItem): timelineFirstLine(of: textItem.text)
    case .caption(let caption): timelineFirstLine(of: caption.text)
    case .adjustment(let adjustment): adjustment.name
    case .compound(let compound): compound.name
    }
}

private func timelineFirstLine(of text: String) -> String {
    let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    return firstLine.isEmpty ? "Text" : firstLine
}

struct TimelineClipFill: View {
    let clip: TimelineClip
    let media: ClipMediaDescriptor
    let speedMap: SpeedMap
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat
    let sampleWidth: CGFloat?
    let sampleOffsetX: CGFloat
    var visibleTimelineRange: ClosedRange<Double>? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var waveformSamples: [CGFloat] = []

    var body: some View {
        let thumbnailWidth = timelineThumbnailWidth
        let secondsPerThumbnail = Double(thumbnailWidth / thumbnailSamplingPixelsPerSecond)
        let waveformCount = quantizedWaveformSampleCount

        ZStack {
            if clip.shape != nil {
                Color.orange
            } else if clip.mediaType == .audio {
                TimelineWaveformView(samples: activeWaveformSamples)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .frame(width: sampleWidth ?? width, height: height)
                    .offset(x: sampleOffsetX)
                    .frame(width: width, height: height, alignment: .leading)
                    .clipped()
            } else {
                ZStack(alignment: .leading) {
                    ForEach(visibleThumbnailIndices, id: \.self) { index in
                        TimelineThumbnailTile(
                            clip: clip,
                            media: media,
                            speedMap: speedMap,
                            tileIndex: index,
                            tileWidth: thumbnailWidth,
                            height: height,
                            secondsPerTile: secondsPerThumbnail,
                            displayScale: displayScale
                        )
                        .offset(x: CGFloat(index) * thumbnailWidth)
                    }
                }
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
                    media: media,
                    speedMap: speedMap,
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
        return [0.02]
    }

    private var timelineThumbnailWidth: CGFloat {
        let storedSize = media.naturalSize?.cgSize ?? CGSize(width: 16, height: 9)
        let naturalSize = CGSize(width: max(abs(storedSize.width), 1), height: max(abs(storedSize.height), 1))
        let aspectRatio = min(max(naturalSize.width / max(naturalSize.height, 1), 0.35), 4)
        return max(height * aspectRatio, 24)
    }

    private var quantizedWaveformSampleCount: Int {
        let rawCount = min(max(Int((sampleWidth ?? width) / 2), 80), 900)
        return max(Int((Double(rawCount) / 24).rounded()) * 24, 72)
    }

    private var thumbnailSamplingPixelsPerSecond: CGFloat {
        max((pixelsPerSecond / 4).rounded() * 4, 4)
    }

    private var visibleThumbnailIndices: Range<Int> {
        let thumbnailWidth = max(timelineThumbnailWidth, 1)
        let totalCount = max(Int(ceil(width / thumbnailWidth)) + 1, 1)
        guard let visibleTimelineRange else { return 0..<totalCount }
        let localStart = max(
            CGFloat(visibleTimelineRange.lowerBound - clip.timelineStart) * pixelsPerSecond,
            0
        )
        let localEnd = min(
            max(
                CGFloat(visibleTimelineRange.upperBound - clip.timelineStart) * pixelsPerSecond,
                localStart
            ),
            width
        )
        let first = max(Int(floor(localStart / thumbnailWidth)) - 1, 0)
        let end = min(Int(ceil(localEnd / thumbnailWidth)) + 2, totalCount)
        return first..<max(first, end)
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(Int(ceil(width / max(timelineThumbnailWidth, 1))))",
            "\(Int(timelineThumbnailWidth.rounded()))",
            "\(quantizedWaveformSampleCount)",
            "\(Int(displayScale.rounded()))",
            media.mediaID.rawValue.uuidString,
            "\(speedMap.topologySignature)",
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
