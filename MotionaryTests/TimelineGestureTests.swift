// Regression coverage for timeline gesture intent, ownership, and cancellation.

import SwiftUI
import Testing
import UIKit

@testable import Motionary

struct TimelineGestureTests {
    @Test func movingOutAndBackDoesNotBecomeATap() {
        var intent = TimelineGestureIntent()
        intent.record(CGSize(width: 8, height: 0))
        intent.record(.zero)
        #expect(!intent.permitsSelection)
    }

    @Test func selectionSlopAppliesInEveryDirection() {
        for translation in [CGSize(width: 0, height: 7), CGSize(width: 5, height: 5), CGSize(width: -7, height: 0)] {
            var intent = TimelineGestureIntent()
            intent.record(translation)
            #expect(!intent.permitsSelection)
        }
        var intent = TimelineGestureIntent()
        intent.record(CGSize(width: 2, height: -2))
        #expect(intent.permitsSelection)
        #expect(TimelineGestureIntent.axis(for: CGSize(width: 1, height: 2)) == nil)
        #expect(TimelineGestureIntent.axis(for: CGSize(width: 4, height: 3)) == .horizontal)
        #expect(TimelineGestureIntent.axis(for: CGSize(width: 3, height: 4)) == .vertical)
    }

    @MainActor
    @Test func pureVerticalNavigationDoesNotStartScrubbing() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 0, y: -40))
        scroll.contentOffset = CGPoint(x: 0, y: 40)
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(events.isEmpty)
        #expect(scroll.contentOffset.x == 0)
        #expect(!coordinator.isUserInteracting)
    }

    @MainActor
    @Test func diagonalPanLocksToDominantVerticalAxis() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -20, y: -40))
        scroll.contentOffset = CGPoint(x: 88, y: 120)
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(scroll.contentOffset == CGPoint(x: 0, y: 120))
        #expect(events.isEmpty)
    }

    @MainActor
    @Test func verticalPanStaysLockedWhenDirectionChanges() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 0, y: -40))
        scroll.contentOffset = CGPoint(x: 0, y: 40)
        coordinator.scrollViewDidScroll(scroll)
        #expect(events.isEmpty)
        scroll.contentOffset = CGPoint(x: 88, y: 120)
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(scroll.contentOffset == CGPoint(x: 0, y: 120))
        #expect(events.isEmpty)
    }

    @MainActor
    @Test func changingAxisDuringOverscrollPreservesBounce() {
        let coordinator = makeScrollCoordinator { _ in }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        scroll.contentOffset = CGPoint(x: 0, y: -40)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -40, y: 2))
        scroll.contentOffset = CGPoint(x: 88, y: -40)
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset == CGPoint(x: 88, y: -40))
        scroll.contentOffset = CGPoint(x: 90, y: -10)
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset == CGPoint(x: 90, y: -10))
        scroll.contentOffset = CGPoint(x: 92, y: 0)
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset == CGPoint(x: 92, y: 0))
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
    }

    @MainActor
    @Test func horizontalScrubbingEndsOnceAndFlushesTheFinalTime() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -40, y: 2))
        scroll.contentOffset = CGPoint(x: 88, y: 80)
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset.y == 0)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        coordinator.stopInteractions(in: scroll)
        #expect(events == ["start", "change:1.0", "end:1.0"])
        #expect(!coordinator.isUserInteracting)
    }

    @MainActor
    @Test func removingTimelineFinishesAnActiveScrub() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView()
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 20, y: 0))
        coordinator.stopInteractions(in: scroll)
        coordinator.stopInteractions(in: scroll)
        #expect(events == ["start", "end:0.0"])
    }

    @MainActor
    @Test func interruptedTrimCancelsExactlyOnce() {
        var outcomes: [Bool] = []
        let target = TimelineTrimInteractionTarget(
            accessibilityIdentifier: "test-trim", onChanged: { _ in },
            onEnded: { _, commit in outcomes.append(commit) }
        )
        let coordinator = target.makeCoordinator()
        coordinator.update(state: .began, translation: 4)
        coordinator.update(state: .cancelled, translation: 4)
        coordinator.finish(translation: 0, commit: false)
        #expect(outcomes == [false])
    }

    @MainActor
    @Test func trimHasPriorityOverScrollButDoesNotBlockPinch() {
        let target = TimelineTrimInteractionTarget(
            accessibilityIdentifier: "test-trim", onChanged: { _ in }, onEnded: { _, _ in }
        )
        let coordinator = target.makeCoordinator()
        let recognizer = TimelineTrimGestureRecognizer(target: nil, action: nil)
        let scroll = UIScrollView()
        #expect(coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        #expect(!coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: UIPinchGestureRecognizer()))
    }

    @MainActor
    @Test func pullFeedbackDoesNotMutateSwiftUIStateDuringViewUpdates() async {
        var distances: [CGFloat] = []
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 0, duration: 10,
            contentRevision: 0, contentSize: CGSize(width: 1_000, height: 1_000), isScrollDisabled: false,
            onScrubStart: {}, onScrubChanged: { _ in }, onScrubEnd: { _ in },
            onPullToAddChanged: { distances.append($0) }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        coordinator.publishPullToAddDistance(20)
        coordinator.isUpdatingUIView = true
        coordinator.publishPullToAddDistance(0)
        #expect(distances == [20])
        coordinator.isUpdatingUIView = false
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(distances == [20, 0])
        coordinator.publishPullToAddDistance(0)
        #expect(distances == [20, 0])
    }

    @MainActor
    @Test func aDeferredLayoutSampleCannotRewindTheTrackOverlay() async {
        let state = TimelineScrollPresentationState()
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 118, duration: 120,
            contentRevision: 0, contentSize: CGSize(width: 10_860, height: 200),
            isScrollDisabled: false, scrollPresentationState: state,
            onScrubStart: {}, onScrubChanged: { _ in }, onScrubEnd: { _ in },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        coordinator.isUpdatingUIView = true
        coordinator.publishHorizontalScrollOffset(10_384)
        coordinator.isUpdatingUIView = false
        coordinator.publishHorizontalScrollOffset(10_472, immediately: true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(state.horizontalOffset == 10_472)
    }

    @MainActor
    @Test func previousEditPointMovesTracksAndRulerDuringEndBounce() async throws {
        let playback = PlaybackState()
        let state = TimelineScrollPresentationState()
        let ruler = TimelineRulerSurface()
        ruler.frame = CGRect(x: 0, y: 0, width: 300, height: 30)
        state.attachRuler(ruler)
        var scrubCallbacks: [Double] = []
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 120, duration: 120,
            maximumTimelineTime: 119.9667, contentRevision: 0,
            contentSize: CGSize(width: 10_860, height: 400), isScrollDisabled: false,
            playbackState: playback, scrollPresentationState: state,
            onScrubStart: {}, onScrubChanged: { scrubCallbacks.append($0) },
            onScrubEnd: { scrubCallbacks.append($0) },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = coordinator.scrollContentSize(for: CGSize(width: 10_860, height: 400), in: scroll)
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 40)
        scroll.delegate = coordinator
        coordinator.attach(to: scroll)
        defer { coordinator.stopInteractions(in: scroll) }
        let band = try #require(ruler.layer.sublayers?.first)
        let endpointPosition = band.position
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -40, y: 0))
        scroll.contentOffset.x += 15
        #expect(coordinator.isOverscrolled(scroll))

        playback.currentTime = 118
        playback.timelineNavigationRevision &+= 1
        #expect(scroll.contentOffset == CGPoint(x: 10_384, y: 40))
        #expect(state.horizontalOffset == scroll.contentOffset.x)
        #expect(band.position != endpointPosition)

        coordinator.scrollViewDidEndDecelerating(scroll)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(scroll.contentOffset == CGPoint(x: 10_384, y: 40))
        #expect(scrubCallbacks.isEmpty)
    }

    @Test func playbackClockRejectsBriefJumpsInEitherDirection() {
        var clock = TimelinePlaybackPosition(time: 100, timestamp: 0)
        #expect(clock.accept(100.016, at: 0.016, frameDuration: 1 / 30) == 100.016)
        #expect(clock.accept(100.25, at: 0.032, frameDuration: 1 / 30) == 100.016)
        #expect(clock.accept(99.97, at: 0.048, frameDuration: 1 / 30) == 100.016)
        #expect(clock.accept(100.064, at: 0.064, frameDuration: 1 / 30) == 100.064)
        // A missed display callback may legitimately cover more than one frame.
        #expect(clock.accept(100.2, at: 0.2, frameDuration: 1 / 30) == 100.2)
    }

    @Test func persistentClockCorrectionCatchesUpWithoutJumpingOrFreezing() {
        var clock = TimelinePlaybackPosition(time: 20, timestamp: 0)
        #expect(clock.accept(20.25, at: 0.02, frameDuration: 1 / 30) == 20)
        var previous = clock.time
        for frame in 2...80 {
            let elapsed = Double(frame) / 50
            let time = clock.accept(20.23 + elapsed, at: elapsed, frameDuration: 1 / 30)
            #expect(time > previous)
            #expect(time - previous < 0.06)
            previous = time
        }
        #expect(abs(clock.time - 21.83) < 0.000_001)
    }

    @MainActor
    @Test func rulerWindowRebuildKeepsTheSameTickCoordinates() throws {
        let ruler = TimelineRulerSurface()
        ruler.frame = CGRect(x: 0, y: 0, width: 300, height: 30)
        func visibleTickPositions(offset: CGFloat) throws -> [CGFloat] {
            ruler.present(TimelineRulerSample(horizontalOffset: offset, verticalOffset: 0,
                                              pixelsPerSecond: 88, duration: 7_200))
            let band = try #require(ruler.layer.sublayers?.first)
            let ticks = try #require(band.sublayers?.compactMap { $0 as? CAShapeLayer }
                .first(where: { $0.lineWidth == 1.1 })?.path)
            var positions: [CGFloat] = []
            ticks.applyWithBlock { element in
                guard element.pointee.type == .moveToPoint else { return }
                let x = element.pointee.points[0].x + band.position.x
                if (20...280).contains(x) { positions.append(x) }
            }
            return positions
        }
        let previous = try visibleTickPositions(offset: 599_999)
        let next = try visibleTickPositions(offset: 600_001)
        #expect(!previous.isEmpty)
        #expect(next == previous.map { $0 - 2 })
    }

    @MainActor
    @Test func rulerClipsTicksAndLabelsAtTheActualEndOfAShortProject() throws {
        let ruler = TimelineRulerSurface()
        ruler.frame = CGRect(x: 0, y: 0, width: 300, height: 30)
        ruler.present(TimelineRulerSample(horizontalOffset: 84, verticalOffset: 0,
                                          pixelsPerSecond: 280, duration: 0.4))
        let band = try #require(ruler.layer.sublayers?.first)
        #expect(band.masksToBounds)
        #expect(band.position.x + band.bounds.maxX == 178)
        let layers = try #require(band.sublayers)
        for label in layers.compactMap({ $0 as? CATextLayer }) where !label.isHidden {
            #expect(label.frame.maxX <= band.bounds.maxX)
        }
        for ticks in layers.compactMap({ $0 as? CAShapeLayer }) {
            #expect((ticks.path?.boundingBox.maxX ?? 0) <= band.bounds.maxX + 0.5)
        }
    }

    @MainActor
    @Test func layoutAndNativeScrollCallbacksKeepTheLastPlaybackPosition() {
        let playback = PlaybackState()
        playback.currentTime = 116
        playback.isPlaying = true
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 116, duration: 120,
            contentRevision: 0, contentSize: CGSize(width: 10_860, height: 400),
            isScrollDisabled: false, playbackState: playback,
            onScrubStart: {}, onScrubChanged: { _ in }, onScrubEnd: { _ in },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 10_860, height: 400)
        coordinator.attach(to: scroll)
        defer { coordinator.stopInteractions(in: scroll) }
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset.x == 10_208)

        playback.currentTime = 115.5
        scroll.contentOffset.x = 10_000
        coordinator.synchronizeToCurrentTime(in: scroll)
        #expect(scroll.contentOffset.x == 10_208)
        scroll.contentOffset.x = 10_500
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset.x == 10_208)

        playback.currentTime = 117
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset.x == 10_296)
    }

    @MainActor
    @Test func playingTimelineAdvancesWhilePinchingEvenWithoutScaleChanges() {
        let playback = PlaybackState()
        playback.currentTime = 2
        playback.isPlaying = true
        var zoom: CGFloat = 88
        var scrubStarted = false
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: Binding(get: { zoom }, set: { zoom = $0 }),
            currentTime: 2, duration: 10, contentRevision: 0,
            contentSize: CGSize(width: 1_180, height: 200), isScrollDisabled: false,
            playbackState: playback,
            onScrubStart: { scrubStarted = true }, onScrubChanged: { _ in }, onScrubEnd: { _ in },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_180, height: 200)
        scroll.contentOffset.x = 176
        coordinator.attach(to: scroll)
        defer { coordinator.stopInteractions(in: scroll) }

        coordinator.updatePinch(state: .began, scale: 1, in: scroll)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 20, y: 0))
        playback.currentTime = 3
        coordinator.updatePinch(state: .changed, scale: 2, in: scroll)
        #expect(abs(scroll.contentOffset.x - 528) < 0.01)

        playback.currentTime = 4
        coordinator.handlePlaybackFrame()
        #expect(abs(scroll.contentOffset.x - 704) < 0.01)
        #expect(playback.isPlaying)
        #expect(!scrubStarted)

        coordinator.updatePinch(state: .ended, scale: 2, in: scroll)
        playback.currentTime = 5
        coordinator.handlePlaybackFrame()
        #expect(abs(scroll.contentOffset.x - 880) < 0.01)
    }

    @MainActor
    @Test func playingTimelineAdvancesDuringVerticalDragAndDeceleration() {
        let playback = PlaybackState()
        playback.currentTime = 2
        playback.isPlaying = true
        var events: [String] = []
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 2, duration: 10,
            contentRevision: 0, contentSize: CGSize(width: 1_180, height: 1_000),
            isScrollDisabled: false, playbackState: playback,
            onScrubStart: { events.append("start") },
            onScrubChanged: { _ in events.append("change") },
            onScrubEnd: { _ in events.append("end") },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        let scroll = PlaybackTrackingScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_180, height: 1_000)
        scroll.contentOffset = CGPoint(x: 176, y: 40)
        scroll.delegate = coordinator
        coordinator.attach(to: scroll)
        defer { coordinator.stopInteractions(in: scroll) }

        scroll.offsetAnimationRequests = 0
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -10, y: -40))
        playback.currentTime = 3
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset == CGPoint(x: 176, y: 40))
        #expect(coordinator.hostingController.view.transform.tx == -88)
        // A subsequent UIKit pan update must not restore the original X anchor.
        scroll.contentOffset = CGPoint(x: 180, y: 120)
        coordinator.scrollViewDidScroll(scroll)
        #expect(scroll.contentOffset == CGPoint(x: 180, y: 120))
        #expect(coordinator.hostingController.view.transform.tx == -84)

        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: true)
        playback.currentTime = 4
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset == CGPoint(x: 180, y: 120))
        #expect(coordinator.hostingController.view.transform.tx == -172)

        // Playback must preserve the vertical rubber band as well.
        scroll.contentOffset.y = -30
        playback.currentTime = 5
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset == CGPoint(x: 180, y: -30))
        #expect(coordinator.hostingController.view.transform.tx == -260)
        #expect(scroll.offsetAnimationRequests == 0)
        scroll.contentOffset.y = 0
        coordinator.scrollViewDidEndDecelerating(scroll)
        #expect(scroll.contentOffset == CGPoint(x: 440, y: 0))
        #expect(coordinator.hostingController.view.transform == .identity)
        #expect(events.isEmpty)
        #expect(playback.isPlaying)
        #expect(!coordinator.isUserInteracting)
    }

    @MainActor
    @Test func pausedPinchKeepsItsOriginalTimeAnchor() {
        let coordinator = makeScrollCoordinator { _ in }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_180, height: 200)
        scroll.contentOffset.x = 176
        coordinator.updatePinch(state: .began, scale: 1, in: scroll)
        coordinator.updatePinch(state: .changed, scale: 2, in: scroll)
        #expect(abs(scroll.contentOffset.x - 352) < 0.01)
        coordinator.updatePinch(state: .cancelled, scale: 2, in: scroll)
        #expect(!coordinator.isUserInteracting)
    }

    @MainActor
    @Test func playRequestDiscardsMomentumAndLateScrubEndCallbacks() {
        let playback = PlaybackState()
        var events: [String] = []
        let coordinator = TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 0, duration: 10, contentRevision: 0,
            contentSize: CGSize(width: 1180, height: 200), isScrollDisabled: false, playbackState: playback,
            onScrubStart: { events.append("start") },
            onScrubChanged: { playback.currentTime = $0; events.append("change:\($0)") },
            onScrubEnd: { events.append("end:\($0)") },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1180, height: 200)
        coordinator.attach(to: scroll)
        defer { coordinator.stopInteractions(in: scroll) }
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 30, y: 0))
        scroll.contentOffset.x = 264
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: true)
        playback.playbackStartRequestRevision += 1
        #expect(!coordinator.isUserInteracting)
        #expect(playback.currentTime == 3)
        #expect(events == ["start", "change:3.0"])
        scroll.contentOffset.x = 88
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDecelerating(scroll)
        #expect(events == ["start", "change:3.0"])
        playback.isPlaying = true
        coordinator.handlePlaybackFrame()
        #expect(scroll.contentOffset.x == 264)
    }

    @MainActor
    private func makeScrollCoordinator(_ record: @escaping (String) -> Void)
        -> TimelineScrollContainer<Color>.Coordinator
    {
        TimelineScrollContainer(
            pixelsPerSecond: .constant(88), currentTime: 0, duration: 10,
            contentRevision: 0, contentSize: CGSize(width: 1_000, height: 1_000),
            isScrollDisabled: false,
            onScrubStart: { record("start") },
            onScrubChanged: { record("change:\($0)") },
            onScrubEnd: { record("end:\($0)") },
            onPullToAddChanged: { _ in }, onPullToAddEnded: { _ in }
        ) { Color.clear }.makeCoordinator()
    }
}

// Track calls that cancel UIKit's existing deceleration / bounce animation.
private final class PlaybackTrackingScrollView: UIScrollView {
    var offsetAnimationRequests = 0

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        offsetAnimationRequests += 1
        super.setContentOffset(contentOffset, animated: animated)
    }
}
