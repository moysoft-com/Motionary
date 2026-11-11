// Basic application launch and launch-performance UI coverage.

import XCTest

final class MotionaryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesIntoForeground() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testEditorResumesAtTheLastEditPointAfterBackgrounding() {
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let play = app.buttons["Play"]
        let next = app.buttons["Next edit point"]
        let previous = app.buttons["Previous edit point"]
        let enabled = NSPredicate(format: "exists == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: play)],
                                      timeout: 15), .completed)

        XCTAssertTrue(next.isEnabled)
        for _ in 0..<8 where next.isEnabled { next.tap() }
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(previous.isEnabled)

        XCUIDevice.shared.press(.home)
        // Cross the preview's five-second exact-seek timeout while offscreen.
        Thread.sleep(forTimeInterval: 5.2)
        app.activate()

        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: play)],
                                      timeout: 15), .completed)
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(previous.isEnabled)
        let adjustment = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'timeline-item-' AND label == 'Adjustment'"
        )).firstMatch
        XCTAssertTrue(adjustment.exists)
        let clipEndAtProjectEnd = adjustment.frame.maxX
        previous.tap()
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in adjustment.frame.maxX > clipEndAtProjectEnd + 24 },
            object: adjustment
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 4), .completed)
        XCTAssertTrue(previous.isEnabled)
        previous.tap()
        XCTAssertTrue(next.isEnabled)
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: play)],
                                      timeout: 8), .completed)
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(previous.isEnabled)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
