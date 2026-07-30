// UIKit-backed timeline scrolling, scrubbing, and pull-to-add behavior.

import SwiftUI
import UIKit

enum TimelineScrollContainerPullToAdd {
    static let threshold: CGFloat = 62
}

private final class TimelineUIScrollView: UIScrollView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

struct TimelineScrollContainer<Content: View>: UIViewRepresentable {
    @Binding var pixelsPerSecond: CGFloat
    @Binding var horizontalScrollOffset: CGFloat
    let currentTime: Double
    let duration: Double
    let maximumTimelineTime: Double
    let contentRevision: Int
    let contentSize: CGSize
    let isScrollDisabled: Bool
    let autoScrollTarget: CGPoint?
    let onAutoScroll: (CGSize) -> Void
    let allowsVerticalScrolling: Bool
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onPullToAddChanged: (CGFloat) -> Void
    let onPullToAddEnded: (Bool) -> Void
    let content: Content

    init(
        pixelsPerSecond: Binding<CGFloat>,
        horizontalScrollOffset: Binding<CGFloat> = .constant(0),
        currentTime: Double,
        duration: Double,
        maximumTimelineTime: Double? = nil,
        contentRevision: Int,
        contentSize: CGSize,
        isScrollDisabled: Bool,
        autoScrollTarget: CGPoint? = nil,
        onAutoScroll: @escaping (CGSize) -> Void = { _ in },
        allowsVerticalScrolling: Bool = true,
        onScrubStart: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnd: @escaping (Double) -> Void,
        onPullToAddChanged: @escaping (CGFloat) -> Void,
        onPullToAddEnded: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _pixelsPerSecond = pixelsPerSecond
        _horizontalScrollOffset = horizontalScrollOffset
        self.currentTime = currentTime
        self.duration = duration
        self.maximumTimelineTime = min(max(maximumTimelineTime ?? duration, 0), max(duration, 0))
        self.contentRevision = contentRevision
        self.contentSize = contentSize
        self.isScrollDisabled = isScrollDisabled
        self.autoScrollTarget = autoScrollTarget
        self.onAutoScroll = onAutoScroll
        self.allowsVerticalScrolling = allowsVerticalScrolling
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
        let scrollView = TimelineUIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = !allowsVerticalScrolling
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1

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
            coordinator.synchronizeToCurrentTime(in: scrollView)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateAutoScroll(in: scrollView)
        context.coordinator.clampZoom(in: scrollView)
        let hostedContentChanged = context.coordinator.updateHostedContentIfNeeded(
            content,
            contentSize: contentSize
        )
        context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = context.coordinator.scrollContentSize(
            for: contentSize,
            in: scrollView
        )
        scrollView.layoutIfNeeded()
        scrollView.isScrollEnabled = !isScrollDisabled
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = !allowsVerticalScrolling
        if !allowsVerticalScrolling, abs(scrollView.contentOffset.y) > 0.5 {
            scrollView.contentOffset.y = 0
        }

        let activePixelsPerSecond = context.coordinator.parent.pixelsPerSecond
        let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        let targetX = min(max(CGFloat(currentTime) * activePixelsPerSecond, 0), maxX)
        let targetY = allowsVerticalScrolling
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

        guard !context.coordinator.isUserInteracting else { return }
        guard abs(scrollView.contentOffset.x - targetX) > 0.01 || abs(scrollView.contentOffset.y - targetY) > 0.01 else {
            return
        }

        context.coordinator.isProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
        context.coordinator.isProgrammaticScroll = false
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: TimelineScrollContainer
        let hostingController: UIHostingController<Content>
        var pinchRecognizer: UIPinchGestureRecognizer?
        var pinchStartPixelsPerSecond: CGFloat = 88
        var pinchAnchorTime: Double = 0
        var isProgrammaticScroll = false
        var isUserInteracting = false
        private var isPinching = false
        private var isApplyingPinchScale = false
        private var hostedContentRevision: Int
        private var hostedContentSize: CGSize
        private var hostedPixelsPerSecond: CGFloat
        private var isPullToAddArmed = false
        private let maximumPixelsPerSecond: CGFloat = 280
        private var pendingHorizontalScrollOffset: CGFloat?
        private var isHorizontalScrollOffsetUpdateScheduled = false
        private weak var scrollView: UIScrollView?
        private var autoScrollDisplayLink: CADisplayLink?
        private var lastAutoScrollTimestamp: CFTimeInterval?
        private var scrubDisplayLink: CADisplayLink?
        private var pendingScrubTime: Double?

        init(parent: TimelineScrollContainer) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            self.hostedContentRevision = parent.contentRevision
            self.hostedContentSize = parent.contentSize
            self.hostedPixelsPerSecond = parent.pixelsPerSecond
        }

        deinit {
            autoScrollDisplayLink?.invalidate()
            scrubDisplayLink?.invalidate()
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
                x: scrollView.contentOffset.x + speed(location.x, length: scrollView.bounds.width) * elapsed,
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

        func synchronizeToCurrentTime(in scrollView: UIScrollView) {
            guard !isUserInteracting else { return }
            let resolvedContentSize = scrollContentSize(
                for: parent.contentSize,
                in: scrollView
            )
            if abs(scrollView.contentSize.width - resolvedContentSize.width) > 0.01
                || abs(scrollView.contentSize.height - resolvedContentSize.height) > 0.01
            {
                scrollView.contentSize = resolvedContentSize
            }
            let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
            let targetX = min(
                max(CGFloat(parent.currentTime) * parent.pixelsPerSecond, 0),
                maxX
            )
            let targetY = parent.allowsVerticalScrolling
                ? min(scrollView.contentOffset.y, max(scrollView.contentSize.height - scrollView.bounds.height, 0))
                : 0
            guard abs(scrollView.contentOffset.x - targetX) > 0.01
                || abs(scrollView.contentOffset.y - targetY) > 0.01
            else { return }
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
            isProgrammaticScroll = false
            publishHorizontalScrollOffset(targetX, immediately: true)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserInteracting = true
            parent.onScrubStart()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !isApplyingPinchScale {
                publishHorizontalScrollOffset(
                    scrollView.contentOffset.x,
                    immediately: pinchRecognizer?.state == .began || pinchRecognizer?.state == .changed
                )
            }

            if !parent.allowsVerticalScrolling, abs(scrollView.contentOffset.y) > 0.5 {
                isProgrammaticScroll = true
                scrollView.contentOffset.y = 0
                isProgrammaticScroll = false
            }
            let hasVerticalScrollRange = scrollView.contentSize.height > scrollView.bounds.height + 0.5
            if !hasVerticalScrollRange, scrollView.contentOffset.y > 0 {
                isProgrammaticScroll = true
                scrollView.contentOffset.y = 0
                isProgrammaticScroll = false
            }

            let pullDistance = parent.allowsVerticalScrolling
                ? max(-scrollView.contentOffset.y, 0)
                : 0
            if scrollView.isDragging {
                let wasArmed = isPullToAddArmed
                isPullToAddArmed = pullDistance >= TimelineScrollContainerPullToAdd.threshold
                parent.onPullToAddChanged(pullDistance)
                if isPullToAddArmed && !wasArmed {
                    EditorHaptics.layerReady()
                }
            } else if pullDistance <= 0.5 {
                parent.onPullToAddChanged(0)
            }

            guard !isPinching else { return }
            guard !isProgrammaticScroll, isUserInteracting || scrollView.isDragging || scrollView.isDecelerating else {
                return
            }
            let time = min(
                max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0),
                parent.maximumTimelineTime
            )
            emitScrubTime(time)
        }

        private func publishHorizontalScrollOffset(_ offset: CGFloat, immediately: Bool = false) {
            if immediately {
                pendingHorizontalScrollOffset = nil
                guard abs(parent.horizontalScrollOffset - offset) > 0.01 else { return }
                parent.horizontalScrollOffset = offset
                return
            }

            pendingHorizontalScrollOffset = offset
            guard !isHorizontalScrollOffsetUpdateScheduled else { return }
            isHorizontalScrollOffsetUpdateScheduled = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isHorizontalScrollOffsetUpdateScheduled = false
                guard let offset = pendingHorizontalScrollOffset else { return }
                pendingHorizontalScrollOffset = nil
                guard abs(parent.horizontalScrollOffset - offset) > 0.01 else { return }
                parent.horizontalScrollOffset = offset
            }
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
            parent.onPullToAddChanged(0)
            let time = min(
                max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0),
                parent.maximumTimelineTime
            )
            if pendingScrubTime != nil {
                self.pendingScrubTime = nil
                parent.onScrubChanged(time)
            }
            scrubDisplayLink?.invalidate()
            scrubDisplayLink = nil
            parent.onScrubEnd(time)
            isUserInteracting = false
        }

        private func preferredScrubFrameRate() -> Int {
            let native = scrollView?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            return max(native, 1)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }

            switch recognizer.state {
            case .began:
                isPinching = true
                isUserInteracting = true
                pinchStartPixelsPerSecond = parent.pixelsPerSecond
                pinchAnchorTime = min(
                    max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0),
                    parent.maximumTimelineTime
                )
            case .changed:
                applyPinchScale(recognizer.scale, in: scrollView)
            case .ended, .cancelled, .failed:
                applyPinchScale(recognizer.scale, in: scrollView)
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
            let playableWidth = CGFloat(parent.maximumTimelineTime) * parent.pixelsPerSecond
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
