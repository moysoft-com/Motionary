// Basic application launch and launch-performance UI coverage.

import XCTest

final class MotionaryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Sample the composited screen, including the paused-image overlay.
    /// An AVPlayerItemVideoOutput alone cannot detect a covered player layer.
    @MainActor
    func testVisibleArchivePreviewMovesAfterIdleStartAndResume() throws {
        guard let path = ProcessInfo.processInfo.environment["MOTIONARY_AUDIO_FIXTURE"] else {
            throw XCTSkip("Set MOTIONARY_AUDIO_FIXTURE to the moving-video archive")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOTIONARY_EDITOR_UI_FIXTURE"] = path
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let preview = app.images["editor-preview-image"]
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        func pixels() throws -> [UInt8] {
            let image = try XCTUnwrap(preview.screenshot().image.cgImage)
            var samples = [UInt8](repeating: 0, count: 32 * 24)
            try samples.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 32, height: 24,
                    bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 24))
            }
            return samples
        }
        func checkVisiblePlayback() throws {
            Thread.sleep(forTimeInterval: 0.4)
            app.buttons["Play"].tap()
            var previous = try pixels()
            var changes = 0
            let deadline = ContinuousClock.now + .seconds(3)
            while changes < 2, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.12)
                let current = try pixels()
                let difference = zip(previous, current).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                if difference > current.count { changes += 1 }
                previous = current
            }
            XCTAssertEqual(changes, 2, "The visible preview must advance through multiple distinct frames.")
            app.buttons["Pause"].tap()
        }
        try checkVisiblePlayback()
        try checkVisiblePlayback()
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 30), "Playback must finish on its own.")
        XCTAssertFalse(app.buttons["Next edit point"].isEnabled)
        try checkVisiblePlayback()
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
