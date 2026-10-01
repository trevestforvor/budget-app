import XCTest

/// Opportunity cost on the demo ledger: the tag button above Ask opens it, a typed price turns into hours before tax, after
/// tax and invested instead, and the pay screen switches to an hourly wage and works out the hours from the paychecks.
/// Screenshots go to $SCREENSHOT_DIR when set (TEST_RUNNER_SCREENSHOT_DIR).
@MainActor
final class OpportunityUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // A fresh pay profile each run: the screen saves as it goes.
        app.launchArguments = ["-resetSettings"] + DemoLaunch.arguments + arguments
        app.launch()
        return app
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func labelContaining(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func testHomeButtonAndTypedPrice() {
        let app = launch()
        let button = app.buttons["priceCheck"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()

        let field = app.textFields["opportunityPrice"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("250")
        XCTAssertTrue(labelContaining("Before tax", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("After tax", in: app).exists)
        XCTAssertTrue(labelContaining("Invested instead", in: app).exists)
        XCTAssertTrue(labelContaining("safe to spend", in: app).exists)
        app.toolbars.buttons["Done"].firstMatch.tap()
        snapshot("opportunity-typed")
    }

    func testSalaryBelowIncomeIsExplained() {
        let app = launch(["-opportunity", "-price", "500"])
        let pay = app.buttons["opportunityPay"]
        XCTAssertTrue(pay.waitForExistence(timeout: 10))
        pay.tap()
        let salary = app.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'Yearly pay'")).firstMatch
        XCTAssertTrue(salary.waitForExistence(timeout: 10))
        salary.tap()
        salary.typeText("50000")
        // A decimal pad has no return key: the bar above it puts the keyboard away.
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.toolbars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let note = labelContaining("likely includes other money", in: app)
        for _ in 0..<6 where !note.exists { app.swipeUp() }
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the demo's $7,700 a month is more than $50,000 leaves after tax")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(labelContaining("estimated from this salary", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(pay.label.contains("an estimate from your salary"), pay.label)
        snapshot("opportunity-salary-estimate")
    }

    func testHourlyWageInfersHours() {
        let app = launch(["-opportunity", "-price", "120"])
        let pay = app.buttons["opportunityPay"]
        XCTAssertTrue(pay.waitForExistence(timeout: 10))
        XCTAssertTrue(pay.label.contains("from your paychecks"), pay.label)
        pay.tap()

        XCTAssertTrue(app.navigationBars["Your pay"].waitForExistence(timeout: 5))
        XCTAssertTrue(labelContaining("typical month of income", in: app).waitForExistence(timeout: 10))
        app.buttons["Hourly"].tap()
        let wage = app.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'Hourly wage'")).firstMatch
        XCTAssertTrue(wage.waitForExistence(timeout: 5))
        wage.tap()
        wage.typeText("45")
        XCTAssertTrue(labelContaining("Your paychecks at this wage", in: app).waitForExistence(timeout: 5),
                      "an hourly wage with paychecks works out the hours")
        snapshot("opportunity-pay-hourly")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(pay.waitForExistence(timeout: 5))
        XCTAssertTrue(pay.label.contains("Hourly"), pay.label)
        XCTAssertTrue(labelContaining("At $45.00 an hour", in: app).exists, "the wage typed is the before-tax rate")
        snapshot("opportunity-hourly-result")
    }
}
