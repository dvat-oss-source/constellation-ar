import XCTest

/// Walks the Phase 6 debug controls (recorder, calibration, accuracy readout) and attaches screenshots.
final class PrecisionDebugUITests: XCTestCase {
    @MainActor
    func testRecorderControlsAndAccuracyReadout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debug", "YES", "-lookAzimuth", "180", "-lookAltitude", "30", "-lighting", "Night"]
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        attach("1-debug-panel-recorder-controls", app)

        app.buttons["Motion"].firstMatch.tap()
        let record = app.buttons["Record session"]
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        record.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 3), "the recorder should be running")
        attach("2-recording-started", app)

        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp(velocity: .slow)
        scroll.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        attach("3-precision-readout", app)

        scroll.swipeDown(velocity: .fast)
        scroll.swipeDown(velocity: .fast)
        let stop = app.buttons["Stop recording"]
        if stop.waitForHittability(timeout: 3) { stop.tap() }
        Thread.sleep(forTimeInterval: 1)
        attach("4-recording-saved", app)

        app.buttons["Close"].tap()
        Thread.sleep(forTimeInterval: 1)
        attach("5-accuracy-badge", app)
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func waitForHittability(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
