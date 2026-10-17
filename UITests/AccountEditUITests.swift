import XCTest

/// B3 on the phone: Settings → Linked accounts → the pencil on an account opens the edit sheet; a nickname saved there
/// names the account in the list, and making a card of an account with money in it warns. On the demo ledger. Screenshots go to $SCREENSHOT_DIR when set.
@MainActor
final class AccountEditUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
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

    private func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    /// The account row reads as one element (its pencil included, "Edit <name>"), so the pencil is reached by its own
    /// identifier when the tree has it, else by a tap on the row's trailing edge, where it sits.
    private func tapEdit(_ name: String) {
        let pencil = app.buttons.matching(NSPredicate(format: "identifier == 'editAccount' AND label == %@", "Edit \(name)")).firstMatch
        if pencil.waitForExistence(timeout: 3), pencil.isHittable { pencil.tap(); return }
        let row = text(containing: "Edit \(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row offers Edit")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
    }

    func testNicknameFromTheSheet() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let accounts = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'settingsAccounts'")).firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()
        XCTAssertTrue(text(containing: "Total Checking ••0909").waitForExistence(timeout: 10))

        tapEdit("Total Checking")
        XCTAssertTrue(app.navigationBars["Edit account"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Your bank calls it “Total Checking”").exists)
        XCTAssertTrue(app.buttons["saveAccount"].exists && !app.buttons["saveAccount"].isEnabled, "nothing to save yet")
        snapshot("account-edit-sheet")

        let nickname = app.textFields["accountNickname"]
        nickname.tap()
        nickname.typeText("Bills")
        let mask = app.textFields["accountMask"]
        mask.tap()
        mask.typeText("1")   // 09091: five digits are fine
        snapshot("account-edit-filled")
        app.buttons["saveAccount"].tap()

        XCTAssertTrue(text(containing: "Bills ••09091").waitForExistence(timeout: 10), "the nickname and digits name the account")
        XCTAssertFalse(text(containing: "Total Checking ••0909").exists)
        snapshot("account-edit-saved")
    }

    /// Made a card with money in it, the save says what to check, after the sheet has gone (the row can't present an
    /// alert while it's still presenting the sheet).
    func testCardWithPositiveBalanceWarns() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let accounts = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'settingsAccounts'")).firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 5))
        accounts.tap()
        XCTAssertTrue(text(containing: "Cash Account").waitForExistence(timeout: 10))

        tapEdit("Cash Account")
        XCTAssertTrue(app.navigationBars["Edit account"].waitForExistence(timeout: 5))
        let card = app.buttons["Card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        app.buttons["saveAccount"].tap()

        let alert = app.alerts["Saved"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the save says what to check")
        let warning = alert.descendants(matching: .staticText).matching(NSPredicate(format: "label CONTAINS[c] %@", "Check it after the next sync")).firstMatch
        XCTAssertTrue(warning.exists, "the positive-balance warning is in the alert")
        snapshot("account-edit-card-warning")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.navigationBars["Edit account"].exists)
    }
}
