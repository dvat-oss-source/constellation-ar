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

/// Opt-in physical-device investigation. Run explicitly with the phone stationary in controlled lighting.
final class CameraQualityDeviceUITests: XCTestCase {
    @MainActor
    func testMatchedLensesAndBackgroundReturn() throws {
        try exercise(lighting: "Day", lenses: ["1×", "0.5×", "1×", "4×", "1×"])
    }

    @MainActor
    func testAutomaticLightingBackgroundReturn() throws {
        try exercise(lighting: "Auto", lenses: ["1×"])
    }

    @MainActor
    private func exercise(lighting: String, lenses: [String]) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical back cameras and a controlled scene")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-debug", "YES", "-lighting", lighting, "-fixedSky", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Record session"].waitForExistence(timeout: 20))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !app.buttons["120"].isHittable { scroll.swipeUp(velocity: .slow) }
        // SwiftUI doesn't expose the Picker label as the segmented-control identifier on this OS.
        // The first "off" in this panel belongs to Small frames; the second belongs to Full frames.
        app.buttons.matching(identifier: "off").firstMatch.tap()
        XCTAssertTrue(app.buttons["120"].isHittable, app.debugDescription)
        app.buttons["120"].tap()
        app.buttons["Record session"].tap()
        app.buttons["Close"].tap()

        for label in lenses {
            let lens = app.buttons[label]
            XCTAssertTrue(lens.waitForExistence(timeout: 10), app.debugDescription)
            lens.tap()
            Thread.sleep(forTimeInterval: 8)
            attach("\(lighting)-\(label)-before-background", app)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            app.activate()
            attach("\(lighting)-\(label)-immediate-return", app)
            Thread.sleep(forTimeInterval: 8)
            attach("\(lighting)-\(label)-settled-return", app)
        }

        app.buttons["Debug"].tap()
        for _ in 0..<5 where !app.buttons["Stop recording"].isHittable { scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.buttons["Stop recording"].isHittable)
        app.buttons["Stop recording"].tap()
        app.buttons["Close"].tap()
        Thread.sleep(forTimeInterval: 8)
        app.buttons["Debug"].tap()
        let telemetry = app.staticTexts.matching(NSPredicate(format:
            "label BEGINSWITH 'display ' OR label BEGINSWITH 'capture → display' OR label BEGINSWITH 'delivered ' OR label BEGINSWITH 'device exposure ' OR label BEGINSWITH 'exposure ' OR label BEGINSWITH 'focus lock ' OR label BEGINSWITH 'active lens ' OR label BEGINSWITH 'source ' OR label BEGINSWITH 'drawable ' OR label BEGINSWITH 'physical input ' OR label BEGINSWITH 'device zoom '"))
        let attachment = XCTAttachment(string: telemetry.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
        attachment.name = "\(lighting)-recording-off-telemetry"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'physical input AVCaptureDeviceTypeBuiltInWideAngleCamera'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'device zoom 1.000×'")).firstMatch.exists)
        app.buttons["Close"].tap()
        #endif
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
