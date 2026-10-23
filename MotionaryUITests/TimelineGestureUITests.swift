// End-to-end coverage for production timeline taps, scrolling, trims, and reordering.

import XCTest

final class TimelineGestureUITests: XCTestCase {
    private let firstID = "00000000-0000-0000-0000-000000000001"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--timeline-gesture-tests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["test-selection"].waitForExistence(timeout: 10))
    }

    func testTapSelectsButSmallHorizontalScrollDoesNot() {
        let point = itemPoint(row: 0)
        point.press(forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: -14, dy: 0)))
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        itemPoint(row: 0).tap()
        XCTAssertEqual(app.staticTexts["test-selection"].label, firstID)
    }

    func testSlowVerticalScrollOverItemDoesNotSelectOrPausePlayback() {
        app.buttons["Set playing"].tap()
        let point = itemPoint(row: 2)
        point.press(
            forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: 2, dy: -70)),
            withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        XCTAssertEqual(app.staticTexts["test-playback"].label, "playing")
        XCTAssertEqual(app.staticTexts["test-start"].label, "0.500")
    }

    func testLongPressStillMovesClip() {
        let point = itemPoint(row: 0)
        point.press(forDuration: 0.5, thenDragTo: point.withOffset(CGVector(dx: 44, dy: 0)))
        XCTAssertEqual(app.staticTexts["test-selection"].label, firstID)
        XCTAssertGreaterThan(Double(app.staticTexts["test-start"].label) ?? 0, 0.8)
        XCTAssertEqual(app.staticTexts["test-duration"].label, "2.000")
    }

    func testTrimHandleAllowsVerticalScrollWithoutChangingTheItem() {
        itemPoint(row: 0).tap()
        let handle = app.otherElements["timeline-trim-\(firstID)-start"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let point = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -65)))
        XCTAssertEqual(app.staticTexts["test-start"].label, "0.500")
        XCTAssertEqual(app.staticTexts["test-duration"].label, "2.000")
    }

    func testTrimHandleStillTrimsHorizontally() {
        itemPoint(row: 0).tap()
        let handle = app.otherElements["timeline-trim-\(firstID)-start"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let point = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: 44, dy: 0)))
        XCTAssertGreaterThan(Double(app.staticTexts["test-start"].label) ?? 0, 0.8)
        XCTAssertLessThan(Double(app.staticTexts["test-duration"].label) ?? 2, 1.8)
    }

    func testTrackReorderAutoScrollsWhileFingerIsHeldAtBottom() {
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        let frame = timeline.frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + 40, dy: frame.minY + 60))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + 40, dy: frame.maxY - 10))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.5)
        XCTAssertGreaterThan(Int(app.staticTexts["test-first-track-index"].label) ?? -1, 5)
    }

    func testTrackDoubleTapStillShowsDeleteConfirmation() {
        let frame = app.descendants(matching: .any)["editor-timeline"].firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + 40, dy: frame.minY + 60)).doubleTap()
        XCTAssertTrue(app.staticTexts["Delete Layer 1?"].waitForExistence(timeout: 3))
    }

    func testPinchDoesNotSelectAndTapWorksAfterwards() {
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        timeline.pinch(withScale: 1.5, velocity: 1)
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        let frame = timeline.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX + 120, dy: frame.minY + 60)).tap()
        XCTAssertEqual(app.staticTexts["test-selection"].label, firstID)
    }

    private func itemPoint(row: Int) -> XCUICoordinate {
        let frame = app.descendants(matching: .any)["editor-timeline"].firstMatch.frame
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX + 70, dy: frame.minY + 60 + CGFloat(row) * 51)
        )
    }
}
