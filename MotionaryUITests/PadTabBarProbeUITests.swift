// Temporary probe used while tuning the iPad tab bar animation.

import XCTest

final class PadTabBarProbeUITests: XCTestCase {
    @MainActor
    func testSearchBarAnimationProbe() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 15))
        sleep(8)
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.textFields["home-project-search-field"].waitForExistence(timeout: 5))
        sleep(3)
        app.buttons["Close search"].firstMatch.tap()
        sleep(5)
    }
}
