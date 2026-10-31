// Regression coverage for the native search tab acting on the existing project dashboard.

import XCTest

final class ProjectSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    @MainActor
    func testOpeningSearchResultClosesOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 15))

        let firstProject = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home-project-card-")
        ).firstMatch
        guard firstProject.exists else {
            throw XCTSkip("Opening a search result requires an existing project")
        }

        app.buttons["Search"].firstMatch.tap()
        let searchField = app.textFields["home-project-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        firstProject.tap()

        let back = app.buttons["motionary-editor-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        XCTAssertFalse(searchField.exists, "The search overlay must not cover the editor")
        XCTAssertFalse(app.tabBars.buttons["Motionary"].isHittable, "Editor must hide the native tab bar")
        XCTAssertFalse(app.buttons["Search"].firstMatch.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 5))
        XCTAssertFalse(searchField.exists)
        XCTAssertTrue(app.tabBars.buttons["Motionary"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["Motionary"].isHittable)
    }

    @MainActor
    func testColdLaunchAndRepeatedSearchFromSettingsAndHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.terminate()
        app.launch()

        // A nil controller for the root search tab previously crashed during tab setup.
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
        let homeHeaderFrame = app.staticTexts["Projects"].frame

        let homeTab = app.tabBars.buttons["Motionary"]
        let settingsTab = app.tabBars.buttons["Settings"]
        let searchButton = app.buttons["Search"].firstMatch
        let searchField = app.textFields["home-project-search-field"]
        let dismissSearch = app.buttons["Close search"].firstMatch

        XCTAssertTrue(homeTab.isSelected)
        XCTAssertTrue(searchButton.exists)

        for cycle in 0..<3 {
            settingsTab.tap()
            XCTAssertTrue(app.staticTexts["New projects"].waitForExistence(timeout: 5))
            XCTAssertTrue(settingsTab.isSelected)
            let settingsHeaderFrame = app.staticTexts["Settings"].firstMatch.frame
            XCTAssertEqual(homeHeaderFrame.minY, settingsHeaderFrame.minY, accuracy: 1)
            XCTAssertEqual(homeHeaderFrame.height, settingsHeaderFrame.height, accuracy: 1)
            XCTAssertFalse(searchField.exists)
            XCTAssertEqual(app.searchFields.count, 0, "Settings must not inherit searchable")

            // Search is an action: Home must remain the selected tab, with its overlay visible.
            searchButton.tap()
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            XCTAssertTrue(homeTab.isSelected)
            XCTAssertFalse(settingsTab.isSelected)
            XCTAssertFalse(app.staticTexts["Projects"].exists, "Search replaces the dashboard header")

            let dashboardIsEmpty = app.staticTexts["Create a project"].exists
            let query = "MotionaryUITest-NoMatchingProject-\(UUID().uuidString)"
            searchField.tap()
            searchField.typeText(query)
            XCTAssertEqual(searchField.value as? String, query)

            // Exercise filtering with existing user data without creating or deleting projects.
            // A fresh install has no projects, so its create-project empty state remains valid.
            let emptyResult = dashboardIsEmpty ? "Create a project" : "No projects found"
            XCTAssertTrue(app.staticTexts[emptyResult].waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground, "Search cycle \(cycle) must not crash")

            dismissSearch.tap()
            XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
            XCTAssertTrue(homeTab.isSelected)
            XCTAssertFalse(app.staticTexts["No projects found"].exists)

            // Reopen on Home to verify repeated taps do not select a blank search destination.
            searchButton.tap()
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            XCTAssertTrue(homeTab.isSelected)
            let reopenedText = searchField.value as? String ?? ""
            XCTAssertTrue(reopenedText.isEmpty || reopenedText == "Search projects")
            let closeSearch = app.buttons["Close search"].firstMatch
            XCTAssertTrue(closeSearch.exists)
            closeSearch.tap()
            XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
            XCTAssertTrue(searchButton.exists)
            XCTAssertEqual(app.staticTexts["Projects"].frame.minY, homeHeaderFrame.minY, accuracy: 1)
        }

        settingsTab.tap()
        XCTAssertTrue(app.staticTexts["New projects"].waitForExistence(timeout: 5))
        XCTAssertFalse(searchField.exists)
        XCTAssertEqual(app.searchFields.count, 0)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
