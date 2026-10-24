import XCTest

final class HomeScreenShortcutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    @MainActor
    private func openShortcut(_ title: String, coldLaunch: Bool = false) {
        let app = XCUIApplication()
        app.launch()
        if coldLaunch { app.terminate() }
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var icon = springboard.icons.matching(identifier: "Motionary").allElementsBoundByIndex.first { $0.isHittable }
        for _ in 0..<3 where icon == nil {
            springboard.swipeLeft()
            icon = springboard.icons.matching(identifier: "Motionary").allElementsBoundByIndex.first { $0.isHittable }
        }
        guard let icon else {
            XCTFail("Motionary icon is not visible on the Home Screen")
            return
        }
        icon.press(forDuration: 1.2)
        let action = springboard.buttons[title].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    @MainActor
    func testIconPickerFromColdLaunch() {
        openShortcut("Change App Icon", coldLaunch: true)
        let app = XCUIApplication()
        XCTAssertTrue(app.navigationBars["App Icon"].waitForExistence(timeout: 10))
        let primary = app.buttons["app-icon-MotionaryBW"]
        let alternate = app.buttons["app-icon-MotionaryWB"]
        XCTAssertTrue(primary.exists)
        XCTAssertTrue(alternate.exists)
        let selected = NSPredicate(format: "value == %@", "Selected")
        primary.tap()
        expectation(for: selected, evaluatedWith: primary)
        waitForExpectations(timeout: 10)
        dismissIconConfirmation(in: app)
        alternate.tap()
        expectation(for: selected, evaluatedWith: alternate)
        waitForExpectations(timeout: 10)
        dismissIconConfirmation(in: app)
        primary.tap()
        expectation(for: selected, evaluatedWith: primary)
        waitForExpectations(timeout: 10)
        dismissIconConfirmation(in: app)
    }

    @MainActor
    private func dismissIconConfirmation(in app: XCUIApplication) {
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            app.alerts.firstMatch.buttons.firstMatch.tap()
        }
    }

    @MainActor
    func testIconPickerFromWarmLaunch() {
        openShortcut("Change App Icon")
        XCTAssertTrue(XCUIApplication().navigationBars["App Icon"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSettingsShortcut() {
        openShortcut("Settings")
        XCTAssertTrue(XCUIApplication().staticTexts["New projects"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNewProjectShortcut() {
        openShortcut("New Project")
        // PHPicker is presented by the system photo picker service.
        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        XCTAssertTrue(picker.wait(for: .runningForeground, timeout: 10))
    }
}
