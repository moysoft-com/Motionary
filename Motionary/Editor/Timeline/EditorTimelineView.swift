// Timeline root layout, scrolling surface, playhead, and empty state.

import SwiftUI

struct CoreTimelineView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat
    @State private var activeClipDrag: TimelineClipDragState?
    @State private var activeTrackDrag: TimelineTrackDragState?
    @State private var activeTrimSnapTime: Double?
    @State private var activeClipSnapKey: String?
    private let trackHeight: CGFloat = 45
    private let rowSpacing: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            CoreTimelineLayout(
                viewModel: viewModel,
                pixelsPerSecond: $pixelsPerSecond,
                activeClipDrag: $activeClipDrag,
                activeTrackDrag: $activeTrackDrag,
                activeTrimSnapTime: $activeTrimSnapTime,
                activeClipSnapKey: $activeClipSnapKey,
                size: geometry.size,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing
            )
        }
    }
}

struct CoreTimelineLayout: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat
    @Binding var activeClipDrag: TimelineClipDragState?
    @Binding var activeTrackDrag: TimelineTrackDragState?
    @Binding var activeTrimSnapTime: Double?
    @Binding var activeClipSnapKey: String?
    @State private var pullToAddDistance: CGFloat = 0
    @State private var pullToAddBounceTrigger = false
    let size: CGSize
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack {
            timelineScroll
            fixedRuler
            playhead
            pullToAddIndicator
            emptyState
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
    }

    private var centerPadding: CGFloat { size.width / 2 }
    private var duration: Double { max(viewModel.duration, 0.1) }
    private var contentWidth: CGFloat { max(CGFloat(viewModel.duration) * pixelsPerSecond, 0) + centerPadding * 2 }
    private var rowCount: Int { max(viewModel.project.tracks.count, 1) }
    private var contentHeight: CGFloat { CGFloat(rowCount) * (trackHeight + rowSpacing) + 38 }

    private var timelineScroll: some View {
        TimelineScrollContainer(
            pixelsPerSecond: $pixelsPerSecond,
            currentTime: viewModel.currentTime,
            duration: viewModel.duration,
            contentRevision: viewModel.timelineContentRevision,
            contentSize: CGSize(width: contentWidth, height: max(contentHeight, size.height)),
            isScrollDisabled: activeClipDrag != nil || activeTrackDrag != nil,
            onScrubStart: { viewModel.beginScrub() },
            onScrubChanged: { viewModel.updateScrub(to: $0) },
            onScrubEnd: { viewModel.endScrub(at: $0) },
            onPullToAddChanged: { pullToAddDistance = $0 },
            onPullToAddEnded: { shouldAddLayer in
                pullToAddDistance = 0
                if shouldAddLayer {
                    viewModel.addLayer()
                }
            }
        ) {
            TimelineTracksContent(
                viewModel: viewModel,
                activeClipDrag: $activeClipDrag,
                activeTrackDrag: $activeTrackDrag,
                activeTrimSnapTime: $activeTrimSnapTime,
                activeClipSnapKey: $activeClipSnapKey,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                containerHeight: size.height,
                centerPadding: centerPadding,
                pixelsPerSecond: pixelsPerSecond,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing
            )
        }
        .mask(alignment: .bottom) {
            Rectangle()
                .frame(height: max(size.height - 38, 0))
        }
    }

    private var fixedRuler: some View {
        VStack(spacing: 0) {
            FixedTimelineRuler(
                duration: duration,
                currentTime: viewModel.currentTime,
                pixelsPerSecond: pixelsPerSecond
            )
            .frame(height: 30)
            .allowsHitTesting(false)

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .allowsHitTesting(false)
    }

    private var playhead: some View {
        Rectangle()
            .fill(MotionaryTheme.selected)
            .frame(width: 2, height: size.height - 22)
            .position(x: size.width / 2, y: size.height / 2 + 8)
            .shadow(color: .black.opacity(0.45), radius: 6)
            .allowsHitTesting(false)
    }

    private var pullToAddIndicator: some View {
        let threshold = TimelineScrollContainerPullToAdd.threshold
        let progress = min(max(pullToAddDistance / threshold, 0), 1)
        let gapCenterY = 30 + max(pullToAddDistance, 0) * 0.5

        return Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(width: 30, height: 30)
            .symbolEffect(.bounce, value: pullToAddBounceTrigger)
            .background {
                Circle()
                    .fill(progress >= 1 ? MotionaryTheme.accent : Color.gray)
            }
            .opacity(min(max((progress - 0.18) / 0.82, 0), 1))
            .scaleEffect(0 + progress)
            .position(x: size.width * 0.5, y: gapCenterY)
            .allowsHitTesting(false)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.82), value: progress)
            .onChange(of: progress >= 1) { wasReady, isReady in
                guard !wasReady, isReady else { return }
                pullToAddBounceTrigger.toggle()
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.duration == 0 {
            Text("Import media to start")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textSecondary)
        }
    }
}
