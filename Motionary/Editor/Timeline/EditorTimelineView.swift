// Timeline root layout, scrolling surface, playhead, and empty state.

import SwiftUI
import AVFoundation
import UIKit

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
                playbackState: viewModel.playbackState,
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
    @ObservedObject var playbackState: PlaybackState
    @Binding var pixelsPerSecond: CGFloat
    @Binding var activeClipDrag: TimelineClipDragState?
    @Binding var activeTrackDrag: TimelineTrackDragState?
    @Binding var activeTrimSnapTime: Double?
    @Binding var activeClipSnapKey: String?
    @State private var pullToAddDistance: CGFloat = 0
    @State private var pullToAddBounceTrigger = false
    @State private var displayTime: Double = 0
    @State private var clipDragScrollOffset: CGSize = .zero
    @State private var horizontalScrollOffset: CGFloat = 0
    let size: CGSize
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack {
            timelineScroll
            TimelineRulerOverlay(
                viewModel: viewModel,
                playbackState: playbackState,
                pixelsPerSecond: pixelsPerSecond,
                size: size
            )
            playhead
            pullToAddIndicator
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
        .background {
            TimelineDisplayLink(
                player: viewModel.player,
                isPlaying: viewModel.isPlaying
            ) { time in
                displayTime = min(max(time, 0), max(viewModel.duration, 0))
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            displayTime = viewModel.currentTime
        }
        .onChange(of: playbackState.currentTime) { _, time in
            guard !viewModel.isPlaying else { return }
            displayTime = time
        }
    }

    private var centerPadding: CGFloat { size.width / 2 }
    private var duration: Double { max(viewModel.duration, 0.1) }
    private var contentWidth: CGFloat { max(CGFloat(viewModel.duration) * pixelsPerSecond, 0) + centerPadding * 2 }
    private var rowCount: Int { max(viewModel.project.tracks.count, 1) }
    // Increased contentHeight to make room for the ruler inside the scroll view.
    private var contentHeight: CGFloat { CGFloat(rowCount) * (trackHeight + rowSpacing) + 38 + 30 }

    private var timelineScroll: some View {
        TimelineScrollContainer(
            pixelsPerSecond: $pixelsPerSecond,
            horizontalScrollOffset: $horizontalScrollOffset,
            currentTime: displayTime,
            duration: viewModel.duration,
            contentRevision: timelineContentRevision,
            contentSize: CGSize(width: contentWidth, height: max(contentHeight, size.height)),
            isScrollDisabled: activeClipDrag != nil || activeTrackDrag != nil,
            autoScrollTarget: clipAutoScrollTarget,
            onAutoScroll: { delta in
                clipDragScrollOffset.width += delta.width
                clipDragScrollOffset.height += delta.height
            },
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
                snapshot: viewModel.timelineRenderSnapshot,
                viewModel: viewModel,
                activeClipDrag: $activeClipDrag,
                activeTrackDrag: $activeTrackDrag,
                activeTrimSnapTime: $activeTrimSnapTime,
                activeClipSnapKey: $activeClipSnapKey,
                horizontalScrollOffset: $horizontalScrollOffset,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                containerHeight: size.height,
                centerPadding: centerPadding,
                pixelsPerSecond: pixelsPerSecond,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing,
                clipDragScrollOffset: clipDragScrollOffset
            )
        }
        .mask(alignment: .bottom) {
            Rectangle()
                .frame(height: max(size.height - 38, 0))
        }
        .onChange(of: activeClipDrag?.clipID) { _, _ in
            clipDragScrollOffset = .zero
        }
    }

    private var timelineContentRevision: Int {
        guard let drag = activeClipDrag else { return viewModel.timelineHostingRevision }
        var hasher = Hasher()
        hasher.combine(viewModel.timelineHostingRevision)
        hasher.combine(drag.resolvedPlacement.start)
        hasher.combine(drag.resolvedPlacement.trackIndex)
        return hasher.finalize()
    }

    private var clipAutoScrollTarget: CGPoint? {
        activeClipDrag?.fingerLocationInWindow
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

}

private struct TimelineRulerOverlay: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject var playbackState: PlaybackState
    let pixelsPerSecond: CGFloat
    let size: CGSize
    @State private var displayTime: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            FixedTimelineRuler(
                duration: viewModel.duration,
                currentTime: displayTime,
                pixelsPerSecond: pixelsPerSecond
            )
            .frame(height: 30)
            .allowsHitTesting(false)

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .allowsHitTesting(false)
        .background {
            TimelineDisplayLink(
                player: viewModel.player,
                isPlaying: viewModel.isPlaying
            ) { time in
                displayTime = min(max(time, 0), max(viewModel.duration, 0))
            }
        }
        .onAppear {
            displayTime = viewModel.currentTime
        }
        .onChange(of: playbackState.currentTime) { _, time in
            guard !viewModel.isPlaying else { return }
            displayTime = time
        }
    }
}

private struct TimelineDisplayLink: UIViewRepresentable {
    let player: AVPlayer?
    let isPlaying: Bool
    let onFrame: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var parent: TimelineDisplayLink
        private var displayLink: CADisplayLink?

        init(parent: TimelineDisplayLink) {
            self.parent = parent
        }

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleFrame))
            link.preferredFrameRateRange = .default
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func handleFrame() {
            guard parent.isPlaying, let player = parent.player else { return }
            let time = CMTimeGetSeconds(player.currentTime())
            guard time.isFinite else { return }
            parent.onFrame(time)
        }
    }
}
