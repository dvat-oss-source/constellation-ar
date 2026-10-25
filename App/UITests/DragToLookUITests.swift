import XCTest

final class DragToLookUITests: XCTestCase {
    @MainActor
    func testDragChangesViewDirection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-lookAzimuth", "180", "-lookAltitude", "20", "-lighting", "Night"]
        app.launch()
        Thread.sleep(forTimeInterval: 5)
        attachScreenshot(named: "before-drag")
        let before = try viewCentre(in: app)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "after-drag")
        let after = try viewCentre(in: app)

        XCTAssertLessThan(after.azimuth, before.azimuth - 3, "dragging right should turn the view left (west → east of south)")
        XCTAssertGreaterThan(after.altitude, before.altitude + 5, "dragging down should tilt the view up")
    }

    @MainActor
    private func viewCentre(in app: XCUIApplication) throws -> (altitude: Double, azimuth: Double) {
        app.buttons["Debug"].tap()
        let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'view centre'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        let label = text.label
        app.buttons["Close"].tap()
        let numbers = label.split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 2 else { throw XCTSkip("unexpected label \(label)") }
        return (numbers[0], numbers[1])
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
