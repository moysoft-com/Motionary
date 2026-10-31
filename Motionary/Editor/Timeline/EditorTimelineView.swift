// Timeline root layout, scrolling surface, playhead, and empty state.

import AVFoundation
import SwiftUI
import UIKit

/// Adds workspace keyframes and emphasis to the normal interactive timeline.
struct TimelineWorkspaceContext: Equatable {
    let itemID: UUID
    let activeSection: KeyframeSection?
    let activeEffectID: UUID?
    let graphSegment: KeyframeSegment?
    var showsOnlySelectedTrack = false

    func track(in tracks: [TimelineTrack]) -> TimelineTrack? {
        tracks.first { $0.items.contains { $0.id == itemID } }
    }

    func displayedTracks(in tracks: [TimelineTrack]) -> [TimelineTrack] {
        showsOnlySelectedTrack ? track(in: tracks).map { [$0] } ?? [] : tracks
    }

    var contentRevision: Int {
        var hasher = Hasher()
        hasher.combine(itemID)
        hasher.combine(showsOnlySelectedTrack)
        hasher.combine(activeSection?.rawValue)
        hasher.combine(activeEffectID)
        hasher.combine(graphSegment?.clipID)
        hasher.combine(graphSegment?.section.rawValue)
        hasher.combine(graphSegment?.effectID)
        hasher.combine(graphSegment?.startTime)
        hasher.combine(graphSegment?.endTime)
        return hasher.finalize()
    }
}

struct CoreTimelineView: View {
    let viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat
    var workspaceContext: TimelineWorkspaceContext? = nil

    var body: some View {
        CoreTimelineObservationBoundary(
            viewModel: viewModel,
            pixelsPerSecond: $pixelsPerSecond,
            workspaceContext: workspaceContext
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
    let workspaceContext: TimelineWorkspaceContext?
    @State private var activeClipDrag: TimelineClipDragState?
    @State private var activeTrackDrag: TimelineTrackDragState?
    @State private var activeTrimSnapTime: Double?
    @State private var activeClipSnapKey: String?
    private let trackHeight: CGFloat = 45
    private let rowSpacing: CGFloat = 6

    init(viewModel: EditorViewModel, pixelsPerSecond: Binding<CGFloat>, workspaceContext: TimelineWorkspaceContext?) {
        self.viewModel = viewModel
        _timelineState = ObservedObject(wrappedValue: viewModel.timelineState)
        _selectionState = ObservedObject(wrappedValue: viewModel.selectionState)
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _pixelsPerSecond = pixelsPerSecond
        self.workspaceContext = workspaceContext
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.workspaceContext == rhs.workspaceContext
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
                rowSpacing: rowSpacing,
                workspaceContext: workspaceContext
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
    var workspaceContext: TimelineWorkspaceContext? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                timelineScroll
                if !showsOnlySelectedTrack { rulerOverlay }
            }
            .mask {
                TimelineTrackViewportMask(
                    scrollState: scrollPresentationState,
                    tracks: workspaceContext?.displayedTracks(in: snapshot.tracks) ?? snapshot.tracks,
                    centerPadding: centerPadding,
                    trackHeight: trackHeight,
                    rowStride: trackHeight + rowSpacing,
                    activeTrackDrag: activeTrackDrag,
                    trackOriginY: trackOriginY
                )
            }
            playhead
            if !showsOnlySelectedTrack { pullToAddIndicator }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
        .accessibilityIdentifier("editor-timeline")
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

    private var showsOnlySelectedTrack: Bool { workspaceContext?.showsOnlySelectedTrack == true }
    private var trackOriginY: CGFloat { showsOnlySelectedTrack ? 4 : 38 }

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
    private var contentHeight: CGFloat {
        showsOnlySelectedTrack ? size.height : CGFloat(rowCount) * (trackHeight + rowSpacing) + 38 + 30
    }

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
            autoScrollTarget: dragAutoScrollTarget,
            allowsHorizontalAutoScroll: activeTrackDrag == nil,
            onAutoScroll: { delta in
                clipDragScrollOffset.width += delta.width
                clipDragScrollOffset.height += delta.height
            },
            allowsVerticalScrolling: !showsOnlySelectedTrack,
            playbackState: playbackState,
            scrubFrameRate: Int(viewModel.project.renderSettings.frameRate),
            playerProvider: { [weak viewModel] in viewModel?.player },
            viewportState: viewportState,
            scrollPresentationState: scrollPresentationState,
            virtualizationConfiguration: TimelineVirtualizationConfiguration(
                centerPadding: centerPadding,
                trackOriginY: trackOriginY,
                rowStride: trackHeight + rowSpacing,
                trackCount: showsOnlySelectedTrack ? 1 : snapshot.tracks.count,
                duration: snapshot.duration
            ),
            onScrubStart: { viewModel.beginScrub() },
            onScrubChanged: { viewModel.updateScrub(to: $0) },
            onScrubEnd: { viewModel.endScrub(at: $0) },
            onPullToAddChanged: { pullToAddDistance = showsOnlySelectedTrack ? 0 : $0 },
            onPullToAddEnded: { shouldAddLayer in
                pullToAddDistance = 0
                if shouldAddLayer && !showsOnlySelectedTrack {
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
                clipDragScrollOffset: $clipDragScrollOffset,
                workspaceContext: workspaceContext,
                currentTime: visibleTime,
                trackOriginY: trackOriginY
            )
        }
        .onChange(of: activeClipDrag?.clipID) { _, _ in
            clipDragScrollOffset = .zero
        }
        .onChange(of: activeTrackDrag?.trackID) { _, _ in
            clipDragScrollOffset = .zero
        }
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: (0...16).map { step in
                        let progress = CGFloat(step) / 16
                        return Gradient.Stop(color: .black.opacity(Double(1 - (1 - progress) * (1 - progress))), location: progress)
                    },
                    startPoint: .top,
                    endPoint: .bottom
                )
                    .frame(height: showsOnlySelectedTrack ? 0 : 19)
                Rectangle()
            }
        }
    }

    private var rulerOverlay: some View {
        TimelineRulerOverlay(
            scrollState: scrollPresentationState,
            duration: snapshot.duration,
            currentTime: scrollVisibleTime,
            maximumTimelineTime: viewModel.lastPlayableTime,
            pixelsPerSecond: pixelsPerSecond,
            centerPadding: centerPadding,
            width: size.width
        )
    }

    private var timelineContentRevision: Int {
        guard let context = workspaceContext else { return viewModel.timelineHostingRevision }
        let frame = playbackState.isPlaying ? 0
            : Int((playbackState.currentTime * Double(max(viewModel.project.renderSettings.frameRate, 1))).rounded())
        return viewModel.timelineHostingRevision &* 10_007 &+ context.contentRevision &+ frame &* 101
    }

    private var dragAutoScrollTarget: CGPoint? {
        activeClipDrag?.fingerLocationInWindow ?? activeTrackDrag?.fingerLocationInWindow
    }

    private var playhead: some View {
        Rectangle()
            .fill(MotionaryTheme.selected)
            .frame(width: 2, height: showsOnlySelectedTrack ? size.height : max(size.height - 22, 0))
            .position(x: size.width / 2, y: size.height / 2 + (showsOnlySelectedTrack ? 0 : 8))
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
    @ObservedObject var scrollState: TimelineScrollPresentationState
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
        let progress = min(max(scrollState.verticalOffset / 60, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)

        EmbeddedTimelineRuler(
            duration: duration,
            pixelsPerSecond: safePixelsPerSecond,
            centerPadding: centerPadding
        )
        .frame(width: rulerContentWidth, height: 30, alignment: .topLeading)
        .offset(x: pixelAligned(-CGFloat(clampedTime) * safePixelsPerSecond), y: -15 * easedProgress)
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

/// Alpha-only fade following the panel contour, with a wider horizontal transition.
struct TimelineHorizontalEdgeMask: View {
    var fadeWidth: CGFloat = 28
    var cornerRadius: CGFloat = 20
    var verticalFade: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let horizontalInset = min(max(fadeWidth, 0), size.width * 0.5)
            let verticalInset = min(max(verticalFade, 0), size.height * 0.5)
            let radius = min(max(cornerRadius, 0), min(size.width, size.height) * 0.5)
            var previousOpacity = 0.0

            // Nested contours sample the same ease-out curve on every edge.
            // Source-over increments preserve that curve without darkening the surface.
            for step in 1...64 {
                let progress = Double(step) / 64
                let opacity = 1 - pow(1 - progress, 2)
                let layerOpacity = (opacity - previousOpacity) / (1 - previousOpacity)
                let insetProgress = CGFloat(step - 1) / 64
                let rect = CGRect(origin: .zero, size: size).insetBy(
                    dx: horizontalInset * insetProgress,
                    dy: verticalInset * insetProgress
                )
                let contour = RoundedRectangle(
                    cornerRadius: radius * (1 - insetProgress),
                    style: .continuous
                ).path(in: rect)
                context.fill(contour, with: .color(.white.opacity(layerOpacity)))
                previousOpacity = opacity
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TimelineTrackViewportMask: View {
    @ObservedObject var scrollState: TimelineScrollPresentationState
    let tracks: [TimelineTrack]
    let centerPadding: CGFloat
    let trackHeight: CGFloat
    let rowStride: CGFloat
    let activeTrackDrag: TimelineTrackDragState?
    var trackOriginY: CGFloat = 38

    var body: some View {
        let header = TimelineTrackHeaderLayout(
            centerPadding: centerPadding,
            horizontalOffset: scrollState.horizontalOffset
        )
        TimelineHorizontalEdgeMask()
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            let reorder = reorderOffset(for: track.id, index: index)
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(Double(1 - header.transitionProgress)))
                                .frame(width: TimelineTrackHeaderLayout.width, height: trackHeight)
                                .offset(
                                    x: header.viewportOffset,
                                    y: trackOriginY + CGFloat(index) * rowStride + reorder - scrollState.verticalOffset
                                )
                                .animation(
                                    activeTrackDrag?.trackID == track.id
                                        ? nil
                                        : .interactiveSpring(response: 0.22, dampingFraction: 0.86),
                                    value: reorder
                                )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: max(geometry.size.height - trackOriginY, 0))
                    }
                }
            }
            .allowsHitTesting(false)
    }

    private func reorderOffset(for trackID: UUID, index: Int) -> CGFloat {
        guard let drag = activeTrackDrag else { return 0 }
        if drag.trackID == trackID { return drag.translationY }
        if drag.sourceIndex < drag.targetIndex,
            index > drag.sourceIndex, index <= drag.targetIndex { return -rowStride }
        if drag.targetIndex < drag.sourceIndex,
            index >= drag.targetIndex, index < drag.sourceIndex { return rowStride }
        return 0
    }
}
