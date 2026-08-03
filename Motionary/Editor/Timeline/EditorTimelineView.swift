// Timeline root layout, scrolling surface, playhead, and empty state.

import SwiftUI
import AVFoundation
import UIKit

struct CoreTimelineView: View {
    let viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat

    var body: some View {
        CoreTimelineObservationBoundary(
            viewModel: viewModel,
            pixelsPerSecond: $pixelsPerSecond
        )
        .equatable()
    }
}

private struct CoreTimelineObservationBoundary: View, Equatable {
    let viewModel: EditorViewModel
    @ObservedObject private var timelineState: TimelineState
    @ObservedObject private var selectionState: SelectionState
    @ObservedObject private var playbackState: PlaybackState
    @Binding var pixelsPerSecond: CGFloat
    @State private var activeClipDrag: TimelineClipDragState?
    @State private var activeTrackDrag: TimelineTrackDragState?
    @State private var activeTrimSnapTime: Double?
    @State private var activeClipSnapKey: String?
    private let trackHeight: CGFloat = 45
    private let rowSpacing: CGFloat = 6

    init(viewModel: EditorViewModel, pixelsPerSecond: Binding<CGFloat>) {
        self.viewModel = viewModel
        _timelineState = ObservedObject(wrappedValue: viewModel.timelineState)
        _selectionState = ObservedObject(wrappedValue: viewModel.selectionState)
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _pixelsPerSecond = pixelsPerSecond
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
    }

    var body: some View {
        GeometryReader { geometry in
            CoreTimelineLayout(
                viewModel: viewModel,
                playbackState: playbackState,
                snapshot: viewModel.timelineRenderSnapshot,
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
    let viewModel: EditorViewModel
    @ObservedObject var playbackState: PlaybackState
    let snapshot: TimelineRenderSnapshot
    @Binding var pixelsPerSecond: CGFloat
    @Binding var activeClipDrag: TimelineClipDragState?
    @Binding var activeTrackDrag: TimelineTrackDragState?
    @Binding var activeTrimSnapTime: Double?
    @Binding var activeClipSnapKey: String?
    @State private var pullToAddDistance: CGFloat = 0
    @State private var pullToAddBounceTrigger = false
    @State private var displayTime: Double = 0
    @State private var horizontalScrollOffset: CGFloat = 0
    @State private var clipDragScrollOffset: CGSize = .zero
    @StateObject private var viewportState = TimelineViewportState()
    @StateObject private var scrollPresentationState = TimelineScrollPresentationState()
    let size: CGSize
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            timelineScroll
            rulerOverlay
            playhead
            pullToAddIndicator
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
        .background {
            TimelineDisplayLink(
                player: viewModel.player,
                isPlaying: playbackState.isPlaying
            ) { time in
                let resolvedTime = min(max(time, 0), max(viewModel.lastPlayableTime, 0))
                displayTime = resolvedTime
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            displayTime = viewModel.currentTime
        }
        .onChange(of: viewModel.playbackState.currentTime) { _, time in
            guard !playbackState.isPlaying else { return }
            displayTime = time
        }
    }

    private var centerPadding: CGFloat { size.width / 2 }
    private var duration: Double { max(viewModel.duration, 0.1) }
    private var visibleTime: Double {
        playbackState.isPlaying ? displayTime : playbackState.currentTime
    }
    private var scrollVisibleTime: Double {
        min(
            max(Double(horizontalScrollOffset / max(pixelsPerSecond, 1)), 0),
            max(viewModel.lastPlayableTime, 0)
        )
    }
    private var contentWidth: CGFloat { max(CGFloat(viewModel.duration) * pixelsPerSecond, 0) + centerPadding * 2 }
    private var rowCount: Int { max(viewModel.project.tracks.count, 1) }
    // Increased contentHeight to make room for the ruler inside the scroll view.
    private var contentHeight: CGFloat { CGFloat(rowCount) * (trackHeight + rowSpacing) + 38 + 30 }

    private var timelineScroll: some View {
        TimelineScrollContainer(
            pixelsPerSecond: $pixelsPerSecond,
            horizontalScrollOffset: $horizontalScrollOffset,
            currentTime: visibleTime,
            duration: viewModel.duration,
            maximumTimelineTime: viewModel.lastPlayableTime,
            contentRevision: timelineContentRevision,
            contentSize: CGSize(width: contentWidth, height: max(contentHeight, size.height)),
            isScrollDisabled: activeClipDrag != nil || activeTrackDrag != nil,
            autoScrollTarget: clipAutoScrollTarget,
            onAutoScroll: { delta in
                clipDragScrollOffset.width += delta.width
                clipDragScrollOffset.height += delta.height
            },
            playbackState: playbackState,
            playerProvider: { [weak viewModel] in viewModel?.player },
            viewportState: viewportState,
            scrollPresentationState: scrollPresentationState,
            virtualizationConfiguration: TimelineVirtualizationConfiguration(
                centerPadding: centerPadding,
                trackOriginY: 38,
                rowStride: trackHeight + rowSpacing,
                trackCount: snapshot.tracks.count,
                duration: snapshot.duration
            ),
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
                snapshot: snapshot,
                viewModel: viewModel,
                activeClipDrag: $activeClipDrag,
                activeTrackDrag: $activeTrackDrag,
                activeTrimSnapTime: $activeTrimSnapTime,
                activeClipSnapKey: $activeClipSnapKey,
                viewportState: viewportState,
                scrollPresentationState: scrollPresentationState,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                containerHeight: size.height,
                centerPadding: centerPadding,
                pixelsPerSecond: pixelsPerSecond,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing,
                clipDragScrollOffset: $clipDragScrollOffset
            )
        }
        .onChange(of: activeClipDrag?.clipID) { _, _ in
            clipDragScrollOffset = .zero
        }
        .mask(alignment: .bottom) {
            Rectangle()
                .frame(height: max(size.height - 38, 0))
        }
    }

    private var rulerOverlay: some View {
        TimelineRulerOverlay(
            duration: snapshot.duration,
            currentTime: scrollVisibleTime,
            maximumTimelineTime: viewModel.lastPlayableTime,
            pixelsPerSecond: pixelsPerSecond,
            centerPadding: centerPadding,
            width: size.width
        )
    }

    private var timelineContentRevision: Int {
        viewModel.timelineHostingRevision
    }

    private var clipAutoScrollTarget: CGPoint? {
        activeClipDrag?.fingerLocationInWindow
    }

    private var playhead: some View {
        Rectangle()
            .fill(MotionaryTheme.selected)
            .frame(width: 2, height: max(size.height - 22, 0))
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
            .foregroundStyle(MotionaryTheme.foregroundOnAccent)
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
                DispatchQueue.main.async {
                    pullToAddBounceTrigger.toggle()
                }
            }
    }

}

private struct TimelineRulerOverlay: View {
    let duration: Double
    let currentTime: Double
    let maximumTimelineTime: Double
    let pixelsPerSecond: CGFloat
    let centerPadding: CGFloat
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let safePixelsPerSecond = max(pixelsPerSecond, 1)
        let rulerContentWidth = max(
            CGFloat(max(duration, 4)) * safePixelsPerSecond + centerPadding * 2,
            width
        )
        let clampedTime = min(max(currentTime, 0), max(maximumTimelineTime, 0))

        EmbeddedTimelineRuler(
            duration: duration,
            pixelsPerSecond: safePixelsPerSecond,
            centerPadding: centerPadding
        )
        .frame(width: rulerContentWidth, height: 30, alignment: .topLeading)
        .offset(x: pixelAligned(-CGFloat(clampedTime) * safePixelsPerSecond), y: 0)
        .frame(width: width, height: 30, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale
    }
}

struct TimelineDisplayLink: UIViewRepresentable {
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
        context.coordinator.screenMaximumFrameRate =
            uiView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        context.coordinator.updateFrameRate()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var parent: TimelineDisplayLink
        private var displayLink: CADisplayLink?
        var screenMaximumFrameRate = 60

        init(parent: TimelineDisplayLink) {
            self.parent = parent
        }

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleFrame))
            configure(link)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func updateFrameRate() {
            guard let displayLink else { return }
            configure(displayLink)
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

        private func configure(_ link: CADisplayLink) {
            let native = max(screenMaximumFrameRate, 1)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(native),
                maximum: Float(native),
                preferred: Float(native)
            )
        }
    }
}
