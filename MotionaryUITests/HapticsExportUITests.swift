import XCTest

final class HapticsExportUITests: XCTestCase {
    @MainActor
    func testHapticLayerAddsKeyframesAndOffersBothExports() {
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let addHaptics = app.buttons["Add haptics"].firstMatch
        XCTAssertTrue(addHaptics.waitForExistence(timeout: 20))
        addHaptics.tap()

        XCTAssertTrue(timelineItem("Haptic", in: app).waitForExistence(timeout: 10))
        attachScreenshot("Haptics in the timeline")

        app.scrollViews["motionary-editor-toolbar"].buttons["Haptics"].tap()
        let keyframe = app.buttons["Haptics keyframe"]
        XCTAssertTrue(keyframe.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["motionary-property-scrubber-haptics.intensity"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["motionary-property-scrubber-haptics.sharpness"].exists)
        keyframe.tap()
        XCTAssertEqual(keyframe.value as? String, "At playhead")

        app.buttons["Next edit point"].tap()
        XCTAssertTrue(keyframe.isEnabled)
        keyframe.tap()
        let graph = app.buttons["Graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        attachScreenshot("Haptics workspace")
        graph.tap()
        XCTAssertTrue(app.buttons["Graph options"].waitForExistence(timeout: 5))
        app.buttons["Close graphs"].tap()

        app.buttons["motionary-editor-export"].tap()
        let export = app.navigationBars["Export"].buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))

        let watermark = app.switches["Motionary watermark"]
        XCTAssertTrue(watermark.exists)
        // The switch's accessibility element spans the entire settings row.
        watermark.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let keepWatermark = app.alerts.buttons["Keep Watermark"]
        XCTAssertTrue(keepWatermark.waitForExistence(timeout: 5))
        keepWatermark.tap()
        export.tap()

        let dialog = app.alerts["Include Haptics?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.staticTexts["To keep haptics, export a Motionary Video. Haptics play when you open it in Motionary."].exists)
        XCTAssertTrue(dialog.buttons["Export Standard Video"].exists)
        XCTAssertTrue(dialog.buttons["Export Motionary Video"].exists)
    }

    @MainActor
    func testPatternToggleRevealsTimingControlsInTheHapticsWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--adjustment-editor-tests", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let addHaptics = app.buttons["Add haptics"].firstMatch
        XCTAssertTrue(addHaptics.waitForExistence(timeout: 20))
        addHaptics.tap()

        XCTAssertTrue(timelineItem("Haptic", in: app).waitForExistence(timeout: 10))
        app.scrollViews["motionary-editor-toolbar"].buttons["Haptics"].tap()
        let pattern = app.buttons["Pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Haptics"].exists)
        XCTAssertTrue(app.buttons["Haptics keyframe"].exists)
        XCTAssertFalse(app.buttons["Preview Haptics"].exists)
        XCTAssertEqual(pattern.value as? String, "Off")
        XCTAssertFalse(app.staticTexts["Repeat Every"].exists)
        pattern.tap()
        XCTAssertEqual(pattern.value as? String, "On")
        XCTAssertTrue(app.staticTexts["Repeat Every"].exists)
        XCTAssertTrue(app.staticTexts["Length"].exists)
        attachScreenshot("Haptics with Pattern enabled")
        pattern.tap()
        XCTAssertEqual(pattern.value as? String, "Off")
        XCTAssertFalse(app.staticTexts["Length"].exists)
    }

    @MainActor
    private func timelineItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "timeline-item-", title
        )).firstMatch
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
