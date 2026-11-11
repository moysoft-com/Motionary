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
        previous.tap()
        XCTAssertTrue(previous.isEnabled)
        previous.tap()
        XCTAssertTrue(next.isEnabled)
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: play)],
                                      timeout: 8), .completed)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
