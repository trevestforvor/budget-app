import XCTest

/// Signing in to a bank again from the phone, on the demo ledger with `-reconnectStub`: the demo's links read as a
/// 0.6.0 server's that the phone can repair, and a reconnect goes waiting → syncing → done without opening a browser.
/// Screenshots go to $SCREENSHOT_DIR when set (pass `TEST_RUNNER_SCREENSHOT_DIR=/path` to xcodebuild).
@MainActor
final class ReconnectUITests: XCTestCase {
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

    /// The banner offers "Sign in again" and "Renew access"; signing in runs the sheet to done, and the banner goes.
    func testSignInAgainFromLinkedAccounts() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-settings", "-reconnectStub"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["settingsAccounts"].firstMatch.tap()

        XCTAssertTrue(text(containing: "Tidewater needs you to sign in again").waitForExistence(timeout: 10))
        let signIn = app.buttons["Sign in again"]
        XCTAssertTrue(signIn.exists, "the phone can repair it, so the card has its own button")
        XCTAssertTrue(app.buttons["Renew access"].exists, "a link whose access ends in nine days offers renewal")
        XCTAssertTrue(text(containing: "access ends").exists)
        snapshot("reconnect-banner")

        signIn.tap()
        let title = app.staticTexts["reconnectTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the sheet starts")
        snapshot("reconnect-sheet")
        let done = NSPredicate(format: "label == %@", "Tidewater is connected again")
        expectation(for: done, evaluatedWith: title)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(text(containing: "3 new transactions").exists, "the sync that followed says what came in")
        snapshot("reconnect-done")

        app.buttons["reconnectDone"].tap()
        // The sheet goes, and Linked accounts no longer offers the sign-in. (Checked on this page's own controls: Home's
        // attention card, on another tab, reads the demo ledger, which the stub doesn't heal.)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["reconnectTitle"])
        expectation(for: gone, evaluatedWith: app.buttons["Sign in again"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["Renew access"].exists, "the other link still offers renewal")
    }

    /// A free Personal Team build (`-freeTeam` stands in for BUDGET_FREE_TEAM) has no Associated Domains, so even a
    /// server that could repair from the phone gets the dashboard notice, with where the dashboard is since the server
    /// didn't say.
    func testFreeTeamBuildReconnectsOnTheDashboard() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-settings", "-reconnectStub", "-freeTeam"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["settingsAccounts"].firstMatch.tap()

        XCTAssertTrue(text(containing: "Tidewater needs you to sign in again").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "on your Budget dashboard").exists)
        XCTAssertTrue(text(containing: "http://budget.localhost:8081").exists, "no dead button: it says where the dashboard is")
        XCTAssertFalse(app.buttons["Sign in again"].exists, "a free-team build can't be handed back by a bank's app")
        XCTAssertFalse(app.buttons["Renew access"].exists)
        XCTAssertFalse(app.buttons["Open dashboard"].exists)
        snapshot("reconnect-free-team")
    }
}
