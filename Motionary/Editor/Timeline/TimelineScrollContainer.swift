// UIKit-backed timeline scrolling, scrubbing, and pull-to-add behavior.

import SwiftUI
import UIKit

enum TimelineScrollContainerPullToAdd {
    static let threshold: CGFloat = 62
}

struct TimelineScrollContainer<Content: View>: UIViewRepresentable {
    @Binding var pixelsPerSecond: CGFloat
    let currentTime: Double
    let duration: Double
    let contentRevision: Int
    let contentSize: CGSize
    let isScrollDisabled: Bool
    let allowsVerticalScrolling: Bool
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onPullToAddChanged: (CGFloat) -> Void
    let onPullToAddEnded: (Bool) -> Void
    let content: Content

    init(
        pixelsPerSecond: Binding<CGFloat>,
        currentTime: Double,
        duration: Double,
        contentRevision: Int,
        contentSize: CGSize,
        isScrollDisabled: Bool,
        allowsVerticalScrolling: Bool = true,
        onScrubStart: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnd: @escaping (Double) -> Void,
        onPullToAddChanged: @escaping (CGFloat) -> Void,
        onPullToAddEnded: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _pixelsPerSecond = pixelsPerSecond
        self.currentTime = currentTime
        self.duration = duration
        self.contentRevision = contentRevision
        self.contentSize = contentSize
        self.isScrollDisabled = isScrollDisabled
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
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = !allowsVerticalScrolling
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear

        let host = context.coordinator.hostingController
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(host.view)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)
        context.coordinator.pinchRecognizer = pinch

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.clampZoom(in: scrollView)
        context.coordinator.updateHostedContentIfNeeded(content, contentSize: contentSize)
        context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        scrollView.isScrollEnabled = !isScrollDisabled
        scrollView.alwaysBounceVertical = allowsVerticalScrolling
        scrollView.isDirectionalLockEnabled = !allowsVerticalScrolling
        if !allowsVerticalScrolling, abs(scrollView.contentOffset.y) > 0.5 {
            scrollView.contentOffset.y = 0
        }

        let activePixelsPerSecond = context.coordinator.parent.pixelsPerSecond
        let maxX = max(contentSize.width - scrollView.bounds.width, 0)
        let targetX = min(max(CGFloat(currentTime) * activePixelsPerSecond, 0), maxX)
        let targetY = allowsVerticalScrolling
            ? min(
                scrollView.contentOffset.y,
                max(contentSize.height - scrollView.bounds.height, 0)
            )
            : 0

        guard !context.coordinator.isUserInteracting else { return }
        guard abs(scrollView.contentOffset.x - targetX) > 0.5 || abs(scrollView.contentOffset.y - targetY) > 0.5 else {
            return
        }
        guard context.coordinator.shouldApplyProgrammaticScroll(targetX: targetX, targetY: targetY) else { return }

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
        private var hostedContentRevision: Int
        private var hostedContentSize: CGSize
        private var hostedPixelsPerSecond: CGFloat
        private var lastProgrammaticScrollTime: CFTimeInterval = 0
        private var pendingProgrammaticScrollTarget: CGPoint = .zero
        private var isPullToAddArmed = false
        private let maximumPixelsPerSecond: CGFloat = 280

        init(parent: TimelineScrollContainer) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            self.hostedContentRevision = parent.contentRevision
            self.hostedContentSize = parent.contentSize
            self.hostedPixelsPerSecond = parent.pixelsPerSecond
        }

        func updateHostedContentIfNeeded(_ content: Content, contentSize: CGSize) {
            let zoomChanged = abs(hostedPixelsPerSecond - parent.pixelsPerSecond) > 0.1
            guard hostedContentRevision != parent.contentRevision || hostedContentSize != contentSize || zoomChanged
            else { return }

            hostingController.rootView = content
            hostedContentRevision = parent.contentRevision
            hostedContentSize = contentSize
            hostedPixelsPerSecond = parent.pixelsPerSecond
        }

        func shouldApplyProgrammaticScroll(targetX: CGFloat, targetY: CGFloat) -> Bool {
            let now = CACurrentMediaTime()
            let target = CGPoint(x: targetX, y: targetY)
            let targetChangedMeaningfully =
                abs(target.x - pendingProgrammaticScrollTarget.x) > 8
                || abs(target.y - pendingProgrammaticScrollTarget.y) > 8
            pendingProgrammaticScrollTarget = target
            guard targetChangedMeaningfully || now - lastProgrammaticScrollTime >= 1.0 / 30.0 else {
                return false
            }
            lastProgrammaticScrollTime = now
            return true
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserInteracting = true
            parent.onScrubStart()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
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

            guard !isProgrammaticScroll, isUserInteracting || scrollView.isDragging || scrollView.isDecelerating else {
                return
            }
            let time = min(max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
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
            let time = min(max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
            parent.onScrubEnd(time)
            isUserInteracting = false
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }

            switch recognizer.state {
            case .began:
                isUserInteracting = true
                parent.onScrubStart()
                pinchStartPixelsPerSecond = parent.pixelsPerSecond
                pinchAnchorTime = Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1))
            case .changed:
                parent.pixelsPerSecond = clampedPixelsPerSecond(
                    pinchStartPixelsPerSecond * recognizer.scale, in: scrollView)
                keepPinchAnchorCentered(in: scrollView)
            case .ended, .cancelled, .failed:
                parent.pixelsPerSecond = clampedPixelsPerSecond(
                    pinchStartPixelsPerSecond * recognizer.scale, in: scrollView)
                keepPinchAnchorCentered(in: scrollView)
                let time = min(
                    max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
                parent.onScrubEnd(time)
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

        private func keepPinchAnchorCentered(in scrollView: UIScrollView) {
            let targetX = CGFloat(pinchAnchorTime) * parent.pixelsPerSecond
            let maxX = max(parent.contentSize.width - scrollView.bounds.width, 0)
            let clampedX = min(max(targetX, 0), maxX)
            isProgrammaticScroll = true
            scrollView.setContentOffset(
                CGPoint(
                    x: clampedX,
                    y: parent.allowsVerticalScrolling ? scrollView.contentOffset.y : 0
                ),
                animated: false
            )
            isProgrammaticScroll = false
            let time = min(max(Double(clampedX / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
            parent.onScrubChanged(time)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
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
    case .audio:
        MotionaryTheme.audio
    }
}
