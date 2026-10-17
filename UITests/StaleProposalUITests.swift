import XCTest

/// An Ask proposal whose data changed before it was applied: the server refuses it, the card says it's out of date
/// and offers Refresh, and Refresh works it out again (no model call) and offers it again. On the demo ledger.
@MainActor
final class StaleProposalUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func ask(_ app: XCUIApplication, _ question: String) {
        let field = app.textFields["Ask about your money"].exists ? app.textFields["Ask about your money"] : app.textViews["Ask about your money"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(question)
        app.buttons["Send"].tap()
    }

    /// Two caps for DoorDash proposed in one conversation: applying the second moves the cap the first was worked out
    /// against, so the first is refused as out of date, and Refresh offers it again against the new cap.
    func testStaleCardRefreshes() {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-ask", "Cap DoorDash at $150"]
        app.launch()
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 10))

        ask(app, "Cap DoorDash at $200")
        let applies = app.buttons.matching(identifier: "Apply")
        let second = applies.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 10))

        // The first card still offers Apply; the cap it read has moved.
        app.buttons["Apply"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Out of date"].waitForExistence(timeout: 10))
        let refresh = app.buttons["Refresh"]
        XCTAssertTrue(refresh.exists)
        refresh.tap()

        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Out of date"].exists)
        app.buttons["Apply"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "Applied").element(boundBy: 1).waitForExistence(timeout: 10))
    }
}
