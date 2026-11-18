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
            forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -70)),
            withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        XCTAssertEqual(app.staticTexts["test-playback"].label, "playing")
        XCTAssertEqual(app.staticTexts["test-start"].label, "0.500")
    }

    func testDominantVerticalDiagonalScrollMovesTracksWithoutScrubbing() {
        let item = app.buttons["timeline-item-00000000-0000-0000-0000-000000000003"]
        let originalY = item.frame.minY
        let point = itemPoint(row: 2)
        point.press(forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: -44, dy: -70)))
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        // Match the production direction lock and its domain regression:
        // dominant vertical navigation must not move the playhead.
        XCTAssertEqual(Double(app.staticTexts["test-time"].label) ?? -1, 0, accuracy: 0.01)
        XCTAssertLessThan(item.frame.minY, originalY - 20)
    }

    func testLongPressStillMovesClip() {
        let point = itemPoint(row: 0)
        point.press(forDuration: 0.5, thenDragTo: point.withOffset(CGVector(dx: 44, dy: 0)))
        XCTAssertEqual(app.staticTexts["test-selection"].label, firstID)
        XCTAssertGreaterThan(Double(app.staticTexts["test-start"].label) ?? 0, 0.8)
        XCTAssertEqual(app.staticTexts["test-duration"].label, "2.000")
    }

    func testDeselectAfterDraggingAtTheRightEdgeKeepsTheScrollPosition() {
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        let item = app.buttons["timeline-item-\(firstID)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        let edge = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: timeline.frame.maxX - 12, dy: item.frame.midY))
        itemPoint(row: 0).press(
            forDuration: 0.5, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 1.2
        )

        XCTAssertEqual(app.staticTexts["test-selection"].label, firstID)
        let timeAfterDrag = app.staticTexts["test-time"].label
        XCTAssertGreaterThan(Double(timeAfterDrag) ?? 0, 1)
        let positionAfterDrag = item.frame.minX
        app.buttons["Deselect"].tap()
        XCTAssertEqual(app.staticTexts["test-selection"].label, "none")
        XCTAssertEqual(app.staticTexts["test-time"].label, timeAfterDrag)
        XCTAssertEqual(item.frame.minX, positionAfterDrag, accuracy: 1)
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
            .withOffset(CGVector(dx: frame.maxX - 23, dy: frame.minY + 60))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 23, dy: frame.maxY - 10))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.5)
        XCTAssertGreaterThan(Int(app.staticTexts["test-first-track-index"].label) ?? -1, 5)
    }

    func testTrackDoubleTapStillShowsDeleteConfirmation() {
        let frame = app.descendants(matching: .any)["editor-timeline"].firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + 40, dy: frame.minY + 60)).doubleTap()
        XCTAssertTrue(app.staticTexts["Delete Layer 1?"].waitForExistence(timeout: 3))
    }

    func testLayerTagContextMenuDisablesVisualAndMutesAudio() {
        app.terminate()
        app.launchArguments += ["--layer-mute-tests", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["test-selection"].waitForExistence(timeout: 10))
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let textTag = origin.withOffset(CGVector(dx: timeline.frame.minX + 40, dy: timeline.frame.minY + 60))
        let audioTag = textTag.withOffset(CGVector(dx: 0, dy: 51))

        func choose(_ title: String, on tag: XCUICoordinate) {
            tag.press(forDuration: 0.7)
            let action = app.buttons[title]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.tap()
        }

        choose("Disable Layer", on: textTag)
        choose("Enable Layer", on: textTag)
        choose("Mute Layer", on: audioTag)
        choose("Unmute Layer", on: audioTag)
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

    func testTimelineScrubsToTheVisibleEndAndBack() {
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.swipeLeft()
        timeline.swipeLeft()
        XCTAssertEqual(app.staticTexts["test-time"].label, "2.500")
        timeline.swipeRight()
        XCTAssertLessThan(Double(app.staticTexts["test-time"].label) ?? 2.5, 2.25)
    }

    private func itemPoint(row: Int) -> XCUICoordinate {
        // Use the actual item geometry: row padding, safe-area insets and
        // device size must not move a test gesture onto empty timeline space.
        let suffix = String(format: "%012d", row + 1)
        let item = app.buttons["timeline-item-00000000-0000-0000-0000-\(suffix)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        return item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
}


final class WorkspaceTimelineScrollUITests: XCTestCase {
    @MainActor
    func testUndoAndRedoReceiveTapsAboveTheScrolledTimeline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "--scroll-workspace-tests", "-AppleLanguages", "(en)"]
        app.launch()

        let adjustment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'timeline-item-' AND label == 'Adjustment'"
        )).firstMatch
        XCTAssertTrue(adjustment.waitForExistence(timeout: 10))
        adjustment.tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(adjustment.waitForNonExistence(timeout: 5))

        let undo = app.buttons["Undo"]
        let redo = app.buttons["Redo"]
        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let scroll = origin.withOffset(CGVector(dx: timeline.midX, dy: timeline.maxY - 35))
        // Scroll the first reorder handle up to the toolbar's vertical position.
        let distance = timeline.minY + 60.5 - undo.frame.midY
        scroll.press(forDuration: 0.01, thenDragTo: scroll.withOffset(CGVector(dx: 0, dy: -distance)),
                     withVelocity: .slow, thenHoldForDuration: 0)

        XCTAssertTrue(undo.isEnabled)
        let center = CGVector(dx: 0.5, dy: 0.5)
        undo.coordinate(withNormalizedOffset: center).tap()
        XCTAssertTrue(redo.isEnabled)
        redo.coordinate(withNormalizedOffset: center).tap()
        XCTAssertFalse(redo.isEnabled)
    }

    @MainActor
    func testEditorUndoAndRedoButtonsRestoreAndRemoveDeletedClip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "-AppleLanguages", "(en)"]
        app.launch()

        let adjustment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'timeline-item-' AND label == 'Adjustment'"
        )).firstMatch
        XCTAssertTrue(adjustment.waitForExistence(timeout: 10))
        adjustment.tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(adjustment.waitForNonExistence(timeout: 5))

        let undo = app.buttons["Undo"]
        let redo = app.buttons["Redo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(adjustment.waitForExistence(timeout: 5))
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        XCTAssertTrue(adjustment.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testClosingTransformRestoresTheSelectedLowerTrack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "--scroll-workspace-tests", "-AppleLanguages", "(en)"]
        app.launch()

        let timeline = app.descendants(matching: .any)["editor-timeline"].firstMatch
        let clip = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "timeline-item-", "Rectangle"
        )).firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let topClip = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "timeline-item-", "Adjustment"
        )).firstMatch
        XCTAssertTrue(topClip.waitForExistence(timeout: 5))
        let anchor = topClip.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: anchor.minX + 55, dy: anchor.midY + 145))
        let end = origin.withOffset(CGVector(dx: anchor.minX + 55, dy: anchor.midY))
        for _ in 0..<4 {
            if clip.exists, clip.isHittable { break }
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertTrue(clip.isHittable)
        clip.tap()
        let originalY = clip.frame.midY
        let transform = app.buttons["Transform"].firstMatch
        XCTAssertTrue(transform.waitForExistence(timeout: 5))
        transform.tap()
        let keyframe = app.buttons["Transform keyframe"]
        XCTAssertTrue(keyframe.waitForExistence(timeout: 5))
        transform.tap()
        XCTAssertTrue(keyframe.waitForNonExistence(timeout: 5))
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        XCTAssertTrue(clip.isHittable)
        XCTAssertEqual(clip.frame.midY, originalY, accuracy: 3)
    }
}
