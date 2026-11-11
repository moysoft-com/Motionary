// UIKit-backed timeline scrolling, scrubbing, and pull-to-add behavior.

import AVFoundation
import Combine
import SwiftUI
import UIKit

enum TimelineScrollContainerPullToAdd {
    static let threshold: CGFloat = 62
}

private final class TimelineUIScrollView: UIScrollView {
    var onLayoutSubviews: (() -> Void)?
    private(set) var isPerformingLayout = false
    private(set) var isChangingSize = false

    override var frame: CGRect {
        get { super.frame }
        set {
            let wasChangingSize = isChangingSize
            isChangingSize = true
            defer { isChangingSize = wasChangingSize }
            super.frame = newValue
        }
    }

    override var bounds: CGRect {
        get { super.bounds }
        set {
            let wasChangingSize = isChangingSize
            isChangingSize = isChangingSize || newValue.size != super.bounds.size
            defer { isChangingSize = wasChangingSize }
            super.bounds = newValue
        }
    }

    override func layoutSubviews() {
        let wasPerformingLayout = isPerformingLayout
        isPerformingLayout = true
        defer { isPerformingLayout = wasPerformingLayout }
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

struct TimelineScrollContainer<Content: View>: UIViewRepresentable {
    @Binding var pixelsPerSecond: CGFloat
    let horizontalScrollOffset: Binding<CGFloat>?
    let currentTime: Double
    let duration: Double
    let maximumTimelineTime: Double
    let contentRevision: Int
    let contentSize: CGSize
    let isScrollDisabled: Bool
    let autoScrollTarget: CGPoint?
    let allowsHorizontalAutoScroll: Bool
    let onAutoScroll: (CGSize) -> Void
    let allowsVerticalScrolling: Bool
    let playbackState: PlaybackState?
    let scrubFrameRate: Int
    let playerProvider: (() -> AVPlayer?)?
    let viewportState: TimelineViewportState?
    let scrollPresentationState: TimelineScrollPresentationState?
    let virtualizationConfiguration: TimelineVirtualizationConfiguration?
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onPullToAddChanged: (CGFloat) -> Void
    let onPullToAddEnded: (Bool) -> Void
    let content: Content

    init(
        pixelsPerSecond: Binding<CGFloat>,
        horizontalScrollOffset: Binding<CGFloat>? = nil,
        currentTime: Double,
        duration: Double,
        maximumTimelineTime: Double? = nil,
        contentRevision: Int,
        contentSize: CGSize,
        isScrollDisabled: Bool,
        autoScrollTarget: CGPoint? = nil,
        allowsHorizontalAutoScroll: Bool = true,
        onAutoScroll: @escaping (CGSize) -> Void = { _ in },
        allowsVerticalScrolling: Bool = true,
        playbackState: PlaybackState? = nil,
        scrubFrameRate: Int = 60,
        playerProvider: (() -> AVPlayer?)? = nil,
        viewportState: TimelineViewportState? = nil,
        scrollPresentationState: TimelineScrollPresentationState? = nil,
        virtualizationConfiguration: TimelineVirtualizationConfiguration? = nil,
        onScrubStart: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnd: @escaping (Double) -> Void,
        onPullToAddChanged: @escaping (CGFloat) -> Void,
        onPullToAddEnded: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _pixelsPerSecond = pixelsPerSecond
        self.horizontalScrollOffset = horizontalScrollOffset
        self.currentTime = currentTime
        self.duration = duration
        self.maximumTimelineTime = min(max(maximumTimelineTime ?? duration, 0), max(duration, 0))
        self.contentRevision = contentRevision
        self.contentSize = contentSize
        self.isScrollDisabled = isScrollDisabled
        self.autoScrollTarget = autoScrollTarget
        self.allowsHorizontalAutoScroll = allowsHorizontalAutoScroll
        self.onAutoScroll = onAutoScroll
        self.allowsVerticalScrolling = allowsVerticalScrolling
        self.playbackState = playbackState
        self.scrubFrameRate = min(max(scrubFrameRate, 1), 120)
        self.playerProvider = playerProvider
        self.viewportState = viewportState
        self.scrollPresentationState = scrollPresentationState
        self.virtualizationConfiguration = virtualizationConfiguration
        self.onScrubStart = onScrubStart
        self.onScrubChanged = onScrubChanged
        self.onScrubEnd = onScrubEnd
        self.onPullToAddChanged = onPullToAddChanged
        self.onPullToAddEnded = onPullToAddEnded
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.isUpdatingUIView = true
        defer { context.coordinator.isUpdatingUIView = false }
        let scrollView = TimelineUIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = true
        scrollView.decelerationRate = .normal
        scrollView.backgroundColor = .clear
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.panGestureRecognizer.addTarget(
            context.coordinator, action: #selector(Coordinator.handleScrollPan(_:))
        )

        let host = context.coordinator.hostingController
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(host.view)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)
        context.coordinator.pinchRecognizer = pinch
        scrollView.onLayoutSubviews = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            // UIKit layout can run inside SwiftUI's layout pass as the editor
            // narrows. Publish viewport changes after that pass, just as in
            // updateUIView, rather than mutating observed state mid-update.
            let wasUpdating = coordinator.isUpdatingUIView
            coordinator.isUpdatingUIView = true
            defer { coordinator.isUpdatingUIView = wasUpdating }
            coordinator.synchronizeToCurrentTime(in: scrollView)
        }
        context.coordinator.attach(to: scrollView)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let previouslyAllowedVerticalScrolling = context.coordinator.parent.allowsVerticalScrolling
        if previouslyAllowedVerticalScrolling && !allowsVerticalScrolling {
            context.coordinator.savedVerticalOffset = max(scrollView.contentOffset.y, 0)
        }
        let restoresVerticalOffset = !previouslyAllowedVerticalScrolling && allowsVerticalScrolling
        context.coordinator.parent = self
        context.coordinator.isUpdatingUIView = true
        defer { context.coordinator.isUpdatingUIView = false }
        context.coordinator.updatePlaybackObservationIfNeeded()
        context.coordinator.updateAutoScroll(in: scrollView)
        context.coordinator.clampZoom(in: scrollView)
        let hostedContentChanged = context.coordinator.updateHostedContentIfNeeded(
            content,
            contentSize: contentSize
        )
        let hostedView = context.coordinator.hostingController.view!
        if hostedView.bounds.size != contentSize {
            hostedView.bounds = CGRect(origin: .zero, size: contentSize)
            hostedView.center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        }
        if !context.coordinator.isPinching {
            let resolvedSize = context.coordinator.scrollContentSize(for: contentSize, in: scrollView)
            if scrollView.contentSize != resolvedSize {
                scrollView.contentSize = resolvedSize
            }
        }
        scrollView.layoutIfNeeded()
        defer { context.coordinator.updateViewport(in: scrollView, force: hostedContentChanged) }
        scrollView.isScrollEnabled = !isScrollDisabled
        context.coordinator.pinchRecognizer?.isEnabled = !isScrollDisabled
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = true
        if !allowsVerticalScrolling, abs(scrollView.contentOffset.y) > 0.5 {
            scrollView.contentOffset.y = 0
        } else if restoresVerticalOffset {
            scrollView.contentOffset.y = min(context.coordinator.savedVerticalOffset,
                max(contentSize.height - scrollView.bounds.height, 0))
        }

        if playbackState?.isPlaying == true {
            context.coordinator.synchronizeToCurrentTime(in: scrollView)
            return
        }
        let resolvedCurrentTime = playbackState?.currentTime ?? currentTime
        let targetX = context.coordinator.horizontalOffset(for: resolvedCurrentTime, in: scrollView)
        let targetY =
            allowsVerticalScrolling
            ? min(
                scrollView.contentOffset.y,
                max(contentSize.height - scrollView.bounds.height, 0)
            )
            : 0

        if hostedContentChanged {
            DispatchQueue.main.async { [weak scrollView, weak coordinator = context.coordinator] in
                guard let scrollView, let coordinator else { return }
                coordinator.synchronizeToCurrentTime(in: scrollView)
            }
        }

        guard !isScrollDisabled, !context.coordinator.isUserInteracting,
            !scrollView.isTracking, !scrollView.isDecelerating,
            !context.coordinator.isOverscrolled(scrollView),
            playbackState?.isPlaying != true
        else { return }
        guard abs(scrollView.contentOffset.x - targetX) > 0.01 || abs(scrollView.contentOffset.y - targetY) > 0.01
        else {
            return
        }

        context.coordinator.isProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
        context.coordinator.isProgrammaticScroll = false
        context.coordinator.publishHorizontalScrollOffset(targetX, immediately: true)
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopInteractions(in: uiView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: TimelineScrollContainer
        let hostingController: UIHostingController<Content>
        var pinchRecognizer: UIPinchGestureRecognizer?
        var pinchStartPixelsPerSecond: CGFloat = 88
        var pinchAnchorTime: Double = 0
        var isProgrammaticScroll = false
        var savedVerticalOffset: CGFloat = 0
        var isUserInteracting = false
        private(set) var isPinching = false
        private var scrollStartX: CGFloat = 0
        private var scrollStartY: CGFloat = 0
        private var scrollAxisIsHorizontal = true
        private var isScrubSession = false
        private var playbackPresentationX: CGFloat?
        private var isApplyingPinchScale = false
        private var hostedContentRevision: Int
        private var hostedContentSize: CGSize
        private var hostedPixelsPerSecond: CGFloat
        private var isPullToAddArmed = false
        private var lastPublishedPullDistance: CGFloat = 0
        private let maximumPixelsPerSecond: CGFloat = 280
        private var pendingHorizontalScrollOffset: CGFloat?
        private var isHorizontalScrollOffsetUpdateScheduled = false
        private var horizontalPresentationGeneration = 0
        private weak var scrollView: UIScrollView?
        private var autoScrollDisplayLink: CADisplayLink?
        private var lastAutoScrollTimestamp: CFTimeInterval?
        private var scrubDisplayLink: CADisplayLink?
        private var pendingScrubTime: Double?
        private var playbackDisplayLink: CADisplayLink?
        private var playbackPosition: TimelinePlaybackPosition?
        private weak var observedPlaybackState: PlaybackState?
        private var playbackCancellables: Set<AnyCancellable> = []
        private var isPlaybackSynchronizationScheduled = false
        var isUpdatingUIView = false
        private var shouldDeferStateUpdates: Bool {
            let view = scrollView as? TimelineUIScrollView
            return isUpdatingUIView || view?.isPerformingLayout == true || view?.isChangingSize == true
        }

        init(parent: TimelineScrollContainer) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            self.hostedContentRevision = parent.contentRevision
            self.hostedContentSize = parent.contentSize
            self.hostedPixelsPerSecond = parent.pixelsPerSecond
            super.init()
            installPlaybackObservation(parent.playbackState)
        }

        deinit {
            autoScrollDisplayLink?.invalidate()
            scrubDisplayLink?.invalidate()
            playbackDisplayLink?.invalidate()
        }

        func stopInteractions(in scrollView: UIScrollView) {
            horizontalPresentationGeneration &+= 1
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            scrubDisplayLink?.invalidate()
            scrubDisplayLink = nil
            stopPlaybackDisplayLink()
            if isScrubSession { finishScrub(scrollView) }
            scrollView.delegate = nil
        }

        func attach(to scrollView: UIScrollView) {
            self.scrollView = scrollView
            updatePlaybackTransport()
            updateViewport(in: scrollView, force: true)
        }

        func updatePlaybackObservationIfNeeded() {
            guard observedPlaybackState !== parent.playbackState else {
                updatePlaybackTransport()
                return
            }
            installPlaybackObservation(parent.playbackState)
        }

        private func installPlaybackObservation(_ playbackState: PlaybackState?) {
            playbackCancellables.removeAll()
            observedPlaybackState = playbackState
            guard let playbackState else {
                stopPlaybackDisplayLink()
                return
            }
            playbackState.$currentTime
                .removeDuplicates()
                .sink { [weak self] _ in
                    guard let self,
                        playbackState.isPlaying == false,
                        let scrollView = self.scrollView
                    else { return }
                    self.schedulePlaybackSynchronization(in: scrollView)
                }
                .store(in: &playbackCancellables)
            playbackState.$isPlaying
                .removeDuplicates()
                .sink { [weak self] playing in
                    self?.updatePlaybackTransport(isPlaying: playing)
                }
                .store(in: &playbackCancellables)
            playbackState.$playbackStartRequestRevision
                .dropFirst()
                .sink { [weak self] _ in self?.interruptScrubForPlayback() }
                .store(in: &playbackCancellables)
            playbackState.$timelineNavigationRevision
                .dropFirst()
                .sink { [weak self] _ in self?.navigateToCurrentTime() }
                .store(in: &playbackCancellables)
        }

        private func updatePlaybackTransport(isPlaying: Bool? = nil) {
            guard isPlaying ?? (parent.playbackState?.isPlaying == true) else {
                stopPlaybackDisplayLink()
                if let scrollView {
                    schedulePlaybackSynchronization(in: scrollView)
                }
                return
            }
            if let playbackDisplayLink {
                configurePlaybackDisplayLink(playbackDisplayLink)
                return
            }
            playbackPosition = nil
            let link = CADisplayLink(
                target: self,
                selector: #selector(handlePlaybackFrame)
            )
            configurePlaybackDisplayLink(link)
            link.add(to: .main, forMode: .common)
            playbackDisplayLink = link
        }

        func interruptScrubForPlayback() {
            guard !isPinching, let scrollView else { return }
            let hadScrub = isScrubSession
            let time = scrubTime(in: scrollView)
            cancelScrollMomentum(in: scrollView)
            // Flush once, before the model invalidates this scrub generation.
            // Calling onScrubEnd here would queue an obsolete exact seek.
            if hadScrub { parent.onScrubChanged(time) }
        }

        private func navigateToCurrentTime() {
            guard let scrollView, !parent.isScrollDisabled else { return }
            let time = clampedTime(parent.playbackState?.currentTime ?? parent.currentTime)
            playbackPosition = TimelinePlaybackPosition(time: time, timestamp: CACurrentMediaTime())
            if isPinching {
                pinchAnchorTime = time
                keepPinchAnchorCentered(pixelsPerSecond: parent.pixelsPerSecond, in: scrollView)
                return
            }
            if !isNavigatingVertically,
                isScrubSession || scrollView.isTracking || scrollView.isDecelerating || scrollView.isScrollAnimating
            {
                cancelScrollMomentum(in: scrollView)
            }
            // Edit-point navigation owns the playhead immediately, including
            // while UIKit is still settling a bounce at the end of the range.
            scroll(to: time, in: scrollView)
        }

        private func cancelScrollMomentum(in scrollView: UIScrollView) {
            pendingHorizontalScrollOffset = nil
            pendingScrubTime = nil
            scrubDisplayLink?.invalidate()
            scrubDisplayLink = nil
            isScrubSession = false
            isUserInteracting = false
            isProgrammaticScroll = true
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.stopScrollingAndZooming()
            scrollView.panGestureRecognizer.isEnabled = true
            isProgrammaticScroll = false
        }

        private func stopPlaybackDisplayLink() {
            playbackDisplayLink?.invalidate()
            playbackDisplayLink = nil
        }

        private func schedulePlaybackSynchronization(in scrollView: UIScrollView) {
            guard !isPlaybackSynchronizationScheduled else { return }
            isPlaybackSynchronizationScheduled = true
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self else { return }
                self.isPlaybackSynchronizationScheduled = false
                guard let scrollView else { return }
                self.synchronizeToCurrentTime(in: scrollView)
            }
        }

        private func configurePlaybackDisplayLink(_ link: CADisplayLink) {
            let native = scrollView?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            let preferred = min(max(native, 1), 60)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(min(preferred, 30)),
                maximum: Float(preferred),
                preferred: Float(preferred)
            )
        }

        @objc func handlePlaybackFrame() {
            guard parent.playbackState?.isPlaying == true,
                !isUserInteracting || isPinching || isNavigatingVertically,
                let scrollView
            else { return }
            if playbackPresentationX != nil, !isUserInteracting,
                !scrollView.isTracking, !scrollView.isDecelerating, !isOverscrolled(scrollView) {
                finishPlaybackPresentation(in: scrollView)
            }
            let time = currentPlaybackTime
            if isPinching {
                pinchAnchorTime = time
                keepPinchAnchorCentered(pixelsPerSecond: parent.pixelsPerSecond, in: scrollView)
            } else {
                scroll(to: time, in: scrollView)
            }
        }

        private var isNavigatingVertically: Bool {
            !isPinching && parent.autoScrollTarget == nil
                && ((isUserInteracting && !scrollAxisIsHorizontal) || playbackPresentationX != nil)
        }

        private var currentPlaybackTime: Double {
            let modelTime = clampedTime(parent.playbackState?.currentTime ?? parent.currentTime)
            let now = CACurrentMediaTime()
            guard let playerProvider = parent.playerProvider,
                parent.playbackState?.isStartingPlayback != true
            else {
                playbackPosition = TimelinePlaybackPosition(time: modelTime, timestamp: now)
                return modelTime
            }
            guard let sample = playerProvider()?.currentTime(), sample.isNumeric else {
                return clampedTime(playbackPosition?.time ?? modelTime)
            }
            let time = clampedTime(sample.seconds)
            var position = playbackPosition ?? TimelinePlaybackPosition(time: time, timestamp: now)
            let accepted = position.accept(time, at: now, frameDuration: 1 / Double(parent.scrubFrameRate))
            playbackPosition = position
            return clampedTime(accepted)
        }

        private func clampedTime(_ time: Double) -> Double {
            min(max(time, 0), parent.maximumTimelineTime)
        }

        private var presentedPlaybackTime: Double {
            clampedTime(playbackPosition?.time ?? parent.playbackState?.currentTime ?? parent.currentTime)
        }

        func horizontalOffset(for time: Double, in scrollView: UIScrollView) -> CGFloat {
            min(CGFloat(clampedTime(time)) * parent.pixelsPerSecond,
                max(scrollView.contentSize.width - scrollView.bounds.width, 0))
        }

        private func scrubTime(in scrollView: UIScrollView) -> Double {
            let pixelsPerSecond = max(parent.pixelsPerSecond, 1)
            let expectedEnd = CGFloat(parent.maximumTimelineTime) * pixelsPerSecond
            let actualEnd = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
            let pixel = 1 / max(scrollView.traitCollection.displayScale, 1)
            let x = scrollView.contentOffset.x
            // UIKit may settle on a rounded content boundary. That position
            // is the last frame even when converting x back to seconds would
            // yield a slightly earlier value.
            if actualEnd > 0, abs(actualEnd - expectedEnd) <= pixel, x >= actualEnd - pixel / 2 {
                return parent.maximumTimelineTime
            }
            return clampedTime(Double(x / pixelsPerSecond))
        }

        func updateAutoScroll(in scrollView: UIScrollView) {
            self.scrollView = scrollView
            if parent.autoScrollTarget != nil {
                isUserInteracting = true
                guard autoScrollDisplayLink == nil else { return }
                let link = CADisplayLink(target: self, selector: #selector(handleAutoScroll(_:)))
                link.add(to: .main, forMode: .common)
                autoScrollDisplayLink = link
            } else if autoScrollDisplayLink != nil {
                autoScrollDisplayLink?.invalidate()
                autoScrollDisplayLink = nil
                lastAutoScrollTimestamp = nil
                isUserInteracting = false
            }
        }

        @objc private func handleAutoScroll(_ link: CADisplayLink) {
            guard let scrollView, let target = parent.autoScrollTarget else { return }
            let elapsed = min(max(link.timestamp - (lastAutoScrollTimestamp ?? link.timestamp), 0), 1.0 / 20.0)
            lastAutoScrollTimestamp = link.timestamp
            guard elapsed > 0 else { return }

            guard let window = scrollView.window else { return }
            let visibleFrameInWindow = scrollView.convert(scrollView.bounds, to: window)
            let location = CGPoint(
                x: target.x - visibleFrameInWindow.minX,
                y: target.y - visibleFrameInWindow.minY
            )
            let edgeZone: CGFloat = 64
            let maxSpeed: CGFloat = 520
            func speed(_ position: CGFloat, length: CGFloat) -> CGFloat {
                if position < edgeZone {
                    return -maxSpeed * min(max((edgeZone - position) / edgeZone, 0), 1)
                }
                if position > length - edgeZone {
                    return maxSpeed * min(max((position - (length - edgeZone)) / edgeZone, 0), 1)
                }
                return 0
            }

            let proposed = CGPoint(
                x: scrollView.contentOffset.x
                    + (parent.allowsHorizontalAutoScroll
                        ? speed(location.x, length: scrollView.bounds.width) * elapsed : 0),
                y: scrollView.contentOffset.y
                    + (parent.allowsVerticalScrolling
                        ? speed(location.y, length: scrollView.bounds.height) * elapsed : 0)
            )
            let clamped = CGPoint(
                x: min(max(proposed.x, 0), max(scrollView.contentSize.width - scrollView.bounds.width, 0)),
                y: min(max(proposed.y, 0), max(scrollView.contentSize.height - scrollView.bounds.height, 0))
            )
            let delta = CGSize(
                width: clamped.x - scrollView.contentOffset.x,
                height: clamped.y - scrollView.contentOffset.y
            )
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else { return }
            isProgrammaticScroll = true
            scrollView.contentOffset = clamped
            isProgrammaticScroll = false
            publishHorizontalScrollOffset(clamped.x, immediately: true)
            updateViewport(in: scrollView)
            parent.onAutoScroll(delta)
        }

        @discardableResult
        func updateHostedContentIfNeeded(_ content: Content, contentSize: CGSize) -> Bool {
            let zoomChanged = abs(hostedPixelsPerSecond - parent.pixelsPerSecond) > 0.1
            guard hostedContentRevision != parent.contentRevision || hostedContentSize != contentSize || zoomChanged
            else { return false }

            hostingController.rootView = content
            hostedContentRevision = parent.contentRevision
            hostedContentSize = contentSize
            hostedPixelsPerSecond = parent.pixelsPerSecond
            return true
        }

        func isOverscrolled(_ scrollView: UIScrollView) -> Bool {
            let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
            let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
            let offset = scrollView.contentOffset
            return offset.x < -0.01 || offset.x > maxX + 0.01
                || offset.y < -0.01 || offset.y > maxY + 0.01
        }

        func synchronizeToCurrentTime(in scrollView: UIScrollView) {
            guard !isProgrammaticScroll, !isApplyingPinchScale else { return }
            if parent.playbackState?.isPlaying == true {
                // A resize or content-size change can displace UIKit's
                // bounds. Restore the last displayed sample before this
                // layout commits, without sampling a second playback clock.
                if !isPinching, !parent.isScrollDisabled, !isUserInteracting || isNavigatingVertically {
                    scroll(to: presentedPlaybackTime, in: scrollView)
                }
                return
            }
            guard !scrollView.isTracking, !scrollView.isDecelerating, !isOverscrolled(scrollView) else { return }
            guard
                TimelineScrollSynchronizationPolicy.shouldSynchronizeOnLayout(
                    isPlaying: parent.playbackState?.isPlaying == true,
                    isUserInteracting: isUserInteracting,
                    isDraggingItem: parent.isScrollDisabled
                )
            else { return }
            let resolvedContentSize = scrollContentSize(
                for: parent.contentSize,
                in: scrollView
            )
            if abs(scrollView.contentSize.width - resolvedContentSize.width) > 0.01
                || abs(scrollView.contentSize.height - resolvedContentSize.height) > 0.01
            {
                scrollView.contentSize = resolvedContentSize
            }
            let currentTime = parent.playbackState?.currentTime ?? parent.currentTime
            scroll(to: currentTime, in: scrollView)
        }

        private func scroll(to time: Double, in scrollView: UIScrollView) {
            let targetX = horizontalOffset(for: time, in: scrollView)
            if isNavigatingVertically {
                // UIKit owns the scroll view throughout dragging, momentum and bounce.
                // Present playback in the hosted content without touching its bounds.
                playbackPresentationX = targetX
                hostingController.view.transform = CGAffineTransform(
                    translationX: scrollView.contentOffset.x - targetX, y: 0
                )
                publishHorizontalScrollOffset(targetX, immediately: true)
                updateViewport(in: scrollView)
                return
            }
            let targetY = parent.allowsVerticalScrolling ? scrollView.contentOffset.y : 0
            guard
                abs(scrollView.contentOffset.x - targetX) > 0.01
                    || abs(scrollView.contentOffset.y - targetY) > 0.01
            else {
                updateViewport(in: scrollView)
                return
            }
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
            isProgrammaticScroll = false
            publishHorizontalScrollOffset(targetX, immediately: true)
            updateViewport(in: scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            beginScroll(
                in: scrollView,
                translation: scrollView.panGestureRecognizer.translation(in: scrollView)
            )
        }

        func beginScroll(in scrollView: UIScrollView, translation: CGPoint) {
            guard !isPinching, scrollView.panGestureRecognizer.numberOfTouches < 2 else { return }
            isUserInteracting = true
            // Lock to the normal range while allowing an interrupted bounce
            // on the other axis to settle naturally.
            let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
            let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
            scrollStartX = min(max(scrollView.contentOffset.x, 0), maxX)
            scrollStartY = min(max(scrollView.contentOffset.y, 0), maxY)
            let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView)
            let direction = translation == .zero ? velocity : translation
            scrollAxisIsHorizontal = !parent.allowsVerticalScrolling || abs(direction.x) >= abs(direction.y)
            isScrubSession = scrollAxisIsHorizontal
            if isScrubSession { parent.onScrubStart() }
        }

        @objc func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .cancelled || recognizer.state == .failed,
                isUserInteracting, !isPinching, parent.autoScrollTarget == nil,
                let scrollView
            else { return }
            finishScrub(scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            if isUserInteracting, !isPinching, !isProgrammaticScroll, parent.autoScrollTarget == nil {
                var offset = scrollView.contentOffset
                let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
                let maxY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
                if scrollAxisIsHorizontal {
                    if offset.y >= 0 && offset.y <= maxY { offset.y = scrollStartY }
                } else if parent.playbackState?.isPlaying != true {
                    if offset.x >= 0 && offset.x <= maxX { offset.x = scrollStartX }
                }
                if offset != scrollView.contentOffset {
                    isProgrammaticScroll = true
                    scrollView.contentOffset = offset
                    isProgrammaticScroll = false
                }
            }
            let followsPlayback = parent.playbackState?.isPlaying == true
                && !isPinching && !parent.isScrollDisabled && (!isUserInteracting || isNavigatingVertically)
            if followsPlayback {
                scroll(to: presentedPlaybackTime, in: scrollView)
            } else if !isApplyingPinchScale {
                publishHorizontalScrollOffset(
                    playbackPresentationX ?? scrollView.contentOffset.x,
                    immediately: scrollView.isDragging
                        || scrollView.isDecelerating
                        || pinchRecognizer?.state == .began
                        || pinchRecognizer?.state == .changed
                )
            }

            if !parent.allowsVerticalScrolling, abs(scrollView.contentOffset.y) > 0.5 {
                isProgrammaticScroll = true
                scrollView.contentOffset.y = 0
                isProgrammaticScroll = false
            }
            let pullDistance =
                parent.allowsVerticalScrolling
                ? max(-scrollView.contentOffset.y, 0)
                : 0
            if scrollView.isDragging {
                let wasArmed = isPullToAddArmed
                isPullToAddArmed = pullDistance >= TimelineScrollContainerPullToAdd.threshold
                publishPullToAddDistance(pullDistance)
                if isPullToAddArmed && !wasArmed {
                    EditorHaptics.layerReady()
                }
            } else if pullDistance <= 0.5 {
                publishPullToAddDistance(0)
            }
            if !followsPlayback { updateViewport(in: scrollView) }

            guard !isPinching, isScrubSession else { return }
            guard !isProgrammaticScroll, isUserInteracting || scrollView.isDragging || scrollView.isDecelerating else {
                return
            }
            emitScrubTime(scrubTime(in: scrollView))
        }

        func publishPullToAddDistance(_ distance: CGFloat) {
            guard abs(lastPublishedPullDistance - distance) > 0.01 else { return }
            lastPublishedPullDistance = distance
            if shouldDeferStateUpdates {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastPublishedPullDistance == distance else { return }
                    self.parent.onPullToAddChanged(distance)
                }
            } else {
                parent.onPullToAddChanged(distance)
            }
        }

        func publishHorizontalScrollOffset(_ offset: CGFloat, immediately: Bool = false) {
            horizontalPresentationGeneration &+= 1
            if shouldDeferStateUpdates {
                let generation = horizontalPresentationGeneration
                DispatchQueue.main.async { [weak self, weak state = parent.scrollPresentationState] in
                    guard self?.horizontalPresentationGeneration == generation else { return }
                    state?.update(horizontalOffset: offset)
                }
            } else {
                parent.scrollPresentationState?.update(horizontalOffset: offset)
            }
            guard let binding = parent.horizontalScrollOffset else { return }
            if immediately {
                pendingHorizontalScrollOffset = nil
                guard abs(binding.wrappedValue - offset) > 0.01 else { return }
                if shouldDeferStateUpdates {
                    pendingHorizontalScrollOffset = offset
                    scheduleDeferredHorizontalScrollOffsetPublish()
                    return
                }
                binding.wrappedValue = offset
                return
            }

            pendingHorizontalScrollOffset = offset
            scheduleDeferredHorizontalScrollOffsetPublish()
        }

        private func scheduleDeferredHorizontalScrollOffsetPublish() {
            guard !isHorizontalScrollOffsetUpdateScheduled else { return }
            isHorizontalScrollOffsetUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isHorizontalScrollOffsetUpdateScheduled = false
                guard let offset = pendingHorizontalScrollOffset,
                    let binding = parent.horizontalScrollOffset else { return }
                pendingHorizontalScrollOffset = nil
                guard abs(binding.wrappedValue - offset) > 0.01 else { return }
                binding.wrappedValue = offset
            }
        }

        func updateViewport(
            in scrollView: UIScrollView,
            force: Bool = false
        ) {
            let verticalOffset = scrollView.contentOffset.y
            let presentedOffset = CGPoint(
                x: playbackPresentationX ?? scrollView.contentOffset.x,
                y: verticalOffset
            )
            if !isApplyingPinchScale || force {
                let scale = parent.pixelsPerSecond
                parent.scrollPresentationState?.presentRuler(TimelineRulerSample(
                    horizontalOffset: min(max(presentedOffset.x, 0), CGFloat(parent.maximumTimelineTime) * scale),
                    verticalOffset: presentedOffset.y,
                    pixelsPerSecond: scale,
                    duration: parent.duration
                ))
            }
            if shouldDeferStateUpdates {
                DispatchQueue.main.async { [weak state = parent.scrollPresentationState] in
                    state?.update(verticalOffset: verticalOffset)
                }
            } else {
                parent.scrollPresentationState?.update(verticalOffset: verticalOffset)
            }
            guard let viewportState = parent.viewportState,
                let configuration = parent.virtualizationConfiguration,
                scrollView.bounds.width > 0,
                scrollView.bounds.height > 0
            else { return }
            if shouldDeferStateUpdates {
                let contentOffset = presentedOffset
                let viewportSize = scrollView.bounds.size
                let pixelsPerSecond = parent.pixelsPerSecond
                DispatchQueue.main.async { [weak viewportState] in
                    viewportState?.update(
                        contentOffset: contentOffset,
                        viewportSize: viewportSize,
                        pixelsPerSecond: pixelsPerSecond,
                        configuration: configuration,
                        force: force
                    )
                }
                return
            }
            viewportState.update(
                contentOffset: presentedOffset,
                viewportSize: scrollView.bounds.size,
                pixelsPerSecond: parent.pixelsPerSecond,
                configuration: configuration,
                force: force
            )
        }

        private func emitScrubTime(_ time: Double) {
            pendingScrubTime = time
            guard scrubDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(flushPendingScrubTime))
            let frameRate = preferredScrubFrameRate()
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(frameRate),
                maximum: Float(frameRate),
                preferred: Float(frameRate)
            )
            link.add(to: .main, forMode: .common)
            scrubDisplayLink = link
        }

        @objc private func flushPendingScrubTime() {
            guard isUserInteracting || pendingScrubTime != nil else {
                scrubDisplayLink?.invalidate()
                scrubDisplayLink = nil
                return
            }
            guard let time = pendingScrubTime else { return }
            pendingScrubTime = nil
            parent.onScrubChanged(time)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let shouldAddLayer =
                isPullToAddArmed && max(-scrollView.contentOffset.y, 0) >= TimelineScrollContainerPullToAdd.threshold
            isPullToAddArmed = false
            parent.onPullToAddEnded(shouldAddLayer)
            guard !decelerate else { return }
            finishScrub(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScrub(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func finishScrub(_ scrollView: UIScrollView) {
            isPullToAddArmed = false
            publishPullToAddDistance(0)
            let time = scrubTime(in: scrollView)
            if isScrubSession, pendingScrubTime != nil {
                self.pendingScrubTime = nil
                parent.onScrubChanged(time)
            }
            scrubDisplayLink?.invalidate()
            scrubDisplayLink = nil
            if isScrubSession { parent.onScrubEnd(time) }
            isScrubSession = false
            isUserInteracting = false
            if !scrollView.isTracking, !scrollView.isDecelerating, !isOverscrolled(scrollView) {
                finishPlaybackPresentation(in: scrollView)
            }
        }

        private func finishPlaybackPresentation(in scrollView: UIScrollView) {
            guard let targetX = playbackPresentationX else { return }
            playbackPresentationX = nil
            isProgrammaticScroll = true
            hostingController.view.transform = .identity
            scrollView.contentOffset.x = targetX
            isProgrammaticScroll = false
            publishHorizontalScrollOffset(targetX, immediately: true)
            updateViewport(in: scrollView)
        }

        private func preferredScrubFrameRate() -> Int {
            let native = scrollView?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            let preferred = max(60, parent.scrubFrameRate)
            return min(max(native, 1), preferred)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }

            updatePinch(state: recognizer.state, scale: recognizer.scale, in: scrollView)
        }

        func updatePinch(state: UIGestureRecognizer.State, scale: CGFloat, in scrollView: UIScrollView) {
            switch state {
            case .began:
                if isUserInteracting { finishScrub(scrollView) }
                finishPlaybackPresentation(in: scrollView)
                isPinching = true
                isUserInteracting = true
                pinchStartPixelsPerSecond = parent.pixelsPerSecond
                pinchAnchorTime = scrubTime(in: scrollView)
            case .changed:
                applyPinchScale(scale, in: scrollView)
            case .ended, .cancelled, .failed:
                applyPinchScale(scale, in: scrollView)
                isPinching = false
                isUserInteracting = false
            default:
                break
            }
        }

        func clampZoom(in scrollView: UIScrollView) {
            let clamped = clampedPixelsPerSecond(parent.pixelsPerSecond, in: scrollView)
            guard abs(clamped - parent.pixelsPerSecond) > 0.1 else { return }
            parent.pixelsPerSecond = clamped
        }

        private func clampedPixelsPerSecond(_ value: CGFloat, in scrollView: UIScrollView) -> CGFloat {
            min(max(value, minimumPixelsPerSecond(in: scrollView)), maximumPixelsPerSecond)
        }

        private func minimumPixelsPerSecond(in scrollView: UIScrollView) -> CGFloat {
            4
        }

        func scrollContentSize(
            for hostedContentSize: CGSize,
            in scrollView: UIScrollView
        ) -> CGSize {
            var size = hostedContentSize
            let playableWidth =
                CGFloat(parent.maximumTimelineTime) * parent.pixelsPerSecond
                + scrollView.bounds.width
            size.width = min(hostedContentSize.width, max(playableWidth, scrollView.bounds.width))
            return size
        }

        @discardableResult
        private func applyPinchScale(_ scale: CGFloat, in scrollView: UIScrollView) -> CGFloat {
            isApplyingPinchScale = true
            defer { isApplyingPinchScale = false }
            let pixelsPerSecond = clampedPixelsPerSecond(
                pinchStartPixelsPerSecond * scale,
                in: scrollView
            )
            parent.pixelsPerSecond = pixelsPerSecond
            if parent.playbackState?.isPlaying == true {
                pinchAnchorTime = currentPlaybackTime
            }
            keepPinchAnchorCentered(pixelsPerSecond: pixelsPerSecond, in: scrollView)
            return pixelsPerSecond
        }

        private func keepPinchAnchorCentered(
            pixelsPerSecond: CGFloat,
            in scrollView: UIScrollView
        ) {
            let targetX = CGFloat(pinchAnchorTime) * pixelsPerSecond
            // `parent.contentSize` is updated by SwiftUI on the next render pass. During a
            // pinch it therefore still describes the previous scale. Derive the horizontal
            // range from the new scale immediately so the playhead cannot be clamped backward
            // at the end of the timeline.
            let maxX = max(CGFloat(parent.maximumTimelineTime) * pixelsPerSecond, 0)
            let clampedX = min(max(targetX, 0), maxX)
            let zoomedContentWidth = maxX + scrollView.bounds.width
            isProgrammaticScroll = true
            if abs(scrollView.contentSize.width - zoomedContentWidth) > 0.01 {
                scrollView.contentSize.width = zoomedContentWidth
            }
            scrollView.setContentOffset(
                CGPoint(
                    x: clampedX,
                    y: parent.allowsVerticalScrolling ? scrollView.contentOffset.y : 0
                ),
                animated: false
            )
            isProgrammaticScroll = false
            publishHorizontalScrollOffset(clampedX, immediately: true)
            updateViewport(in: scrollView, force: true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

func timelineTrackIcon(for kind: TrackKind) -> String {
    switch kind {
    case .undefined:
        "square.dashed"
    case .visual:
        "square.stack.3d.up"
    case .shape:
        "square.fill"
    case .text:
        "textformat"
    case .audio:
        "waveform"
    }
}

func timelineTrackColor(for kind: TrackKind) -> Color {
    switch kind {
    case .undefined:
        MotionaryTheme.accent
    case .visual:
        MotionaryTheme.video
    case .shape:
        .orange
    case .text:
        Color(red: 0.96, green: 0.48, blue: 0.70)
    case .audio:
        MotionaryTheme.audio
    }
}
