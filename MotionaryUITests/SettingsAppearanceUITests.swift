import XCTest

final class SettingsAppearanceUITests: XCTestCase {
    func testSettingsDoNotOfferAppearanceOrIconControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["settings.timeline.djScratching"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.appIcon"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance,")).firstMatch.exists)
    }
}
