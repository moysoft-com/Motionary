import XCTest

final class EffectsGestureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    func testCompactPullAndNavigation() { exercise(side: false) }
    func testSidePullAndNavigation() { exercise(side: true) }

    func testAnimatedLibraryPreviewPlaysWithoutSelectingTheEffect() {
        let app = XCUIApplication()
        app.launchArguments = ["--effects-gesture-tests", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let addEffect = app.buttons["Add effect"]
        XCTAssertTrue(addEffect.waitForExistence(timeout: 15))
        addEffect.tap()
        let search = app.textFields["Search effects"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Camera Wiggle")
        let tile = app.buttons["Camera Wiggle"]
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        // Allow the off-main loop preparation to finish, then compare multiple
        // frames without selecting the tile (the old wipe only ran on selection).
        Thread.sleep(forTimeInterval: 4)
        let first = tile.screenshot()
        Thread.sleep(forTimeInterval: 0.4)
        let second = tile.screenshot()
        Thread.sleep(forTimeInterval: 0.4)
        let third = tile.screenshot()
        XCTAssertNotEqual(first.pngRepresentation, second.pngRepresentation)
        XCTAssertNotEqual(second.pngRepresentation, third.pngRepresentation)
        XCTAssertFalse(tile.isSelected)
        for (index, shot) in [first, second, third].enumerated() {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "Wiggle live preview frame " + String(index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func exercise(side: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--effects-gesture-tests", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if side { app.launchArguments.append("--effects-side") }
        app.launch()
        let peak = app.staticTexts["effects-test-peak"]
        XCTAssertTrue(peak.waitForExistence(timeout: 15))
        let workspace = app.descendants(matching: .any)["effects-test-workspace"].firstMatch
        XCTAssertTrue(workspace.exists)

        func pull(_ distance: CGFloat) {
            let frame = workspace.frame
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY + 75))
            start.press(forDuration: 0.01,
                thenDragTo: start.withOffset(CGVector(dx: -distance, dy: 0)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        pull(70)
        let partial = Double(peak.label) ?? -1
        XCTAssertGreaterThan(partial, 0.1, "Progress must follow the actual native overscroll")
        XCTAssertLessThan(partial, 1)
        XCTAssertFalse(app.navigationBars["Effect Library"].exists)
        app.buttons["Reset peak"].tap()
        pull(240)
        XCTAssertTrue(app.navigationBars["Effect Library"].waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(Double(peak.label) ?? 0, 1, accuracy: 0.01)

        app.buttons["Noir"].firstMatch.tap()
        let back = app.buttons["Back to effects"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["Add effect"].waitForExistence(timeout: 5))
        app.buttons["Reset peak"].tap()
        pull(240)
        XCTAssertTrue(app.navigationBars["Effect Library"].waitForExistence(timeout: 8),
                      "Pull-to-add must still work after returning from effect settings")
    }
}
