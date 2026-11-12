import XCTest

final class ProjectCreationUITests: XCTestCase {
    @MainActor
    func testNewProjectContextMenuAndEmptyProject() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let button = app.buttons["home-new-project"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Empty Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Project"].exists)
        XCTAssertTrue(app.buttons["Choose from Library"].exists)
        app.buttons["Empty Project"].tap()
        XCTAssertTrue(app.buttons["motionary-editor-back"].waitForExistence(timeout: 15))
        app.buttons["motionary-editor-back"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 10))
    }
}
