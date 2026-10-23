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
    @Test func verticalNavigationDoesNotStartScrubbingOrDriftHorizontally() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 2, y: -40), velocity: .zero)
        scroll.contentOffset = CGPoint(x: 12, y: 40)
        coordinator.scrollViewDidScroll(scroll)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(events.isEmpty)
        #expect(scroll.contentOffset.x == 0)
        #expect(!coordinator.isUserInteracting)
    }

    @MainActor
    @Test func horizontalScrubbingEndsOnceAndFlushesTheFinalTime() {
        var events: [String] = []
        let coordinator = makeScrollCoordinator { events.append($0) }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 1_000, height: 1_000)
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: -40, y: 2), velocity: .zero)
        scroll.contentOffset.x = 88
        coordinator.scrollViewDidScroll(scroll)
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
        coordinator.beginScroll(in: scroll, translation: CGPoint(x: 20, y: 0), velocity: .zero)
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
