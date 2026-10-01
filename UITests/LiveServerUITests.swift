import XCTest

/// Drives the real app against a Budget API seeded with the demo ledger — a LOCAL test server
/// (`BUDGET_ALLOW_DEMO=1 BUDGET_SEED_DEMO=1 swift run BudgetServer`), never the Olares one, which holds
/// real accounts and refuses the demo. Skipped unless the runner passes the server:
///
///   TEST_RUNNER_BUDGET_SERVER=https://… TEST_RUNNER_BUDGET_TOKEN=… xcodebuild test …
///
/// Ask runs on the live model, so these check what the ledger says (targets, messages, counts),
/// never the model's wording.
@MainActor
final class LiveServerUITests: XCTestCase {
    private var server: String?
    private var token: String?

    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        server = env["BUDGET_SERVER"]
        token = env["BUDGET_TOKEN"]
        try XCTSkipIf(server == nil || token == nil, "Set TEST_RUNNER_BUDGET_SERVER and TEST_RUNNER_BUDGET_TOKEN to run against a server.")
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-server", server!, "-token", token!] + arguments
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
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("server-\(name).png"))
        }
    }

    /// Part one of two: every tab loads from the server, which leaves last time's copy on the phone.
    func testSavedCopyPrime() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 20))
        for tab in ["Spending", "Plan", "Activity"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'On your Olares'")).firstMatch
                .waitForExistence(timeout: 20), "\(tab) didn't load live")
        }
    }

    /// Part two, with the server swapped for one that takes connections and never answers
    /// (TEST_RUNNER_BUDGET_EXPECT_SAVED=1): each tab shows last time's copy at once, saying it's updating, and says
    /// "Offline copy" once the request gives up.
    func testSavedCopyShowsAtOnce() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUDGET_EXPECT_SAVED"] == "1", "Run after testSavedCopyPrime, against a server that never answers.")
        let started = Date()
        let app = launch()
        let updating = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Updating'")).firstMatch
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "Home waited on the server") // launch included
        XCTAssertTrue(updating.exists)
        snapshot("saved-home-updating")
        for tab in ["Spending", "Plan", "Activity"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] \"Can't reach\"")).firstMatch.exists, tab)
        }
        snapshot("saved-activity")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Offline copy'")).firstMatch.waitForExistence(timeout: 40))
        snapshot("saved-home-offline")
    }

    /// Home, Spending, Plan and Activity all load from the server.
    func testScreensLoadFromServer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 20))
        snapshot("home")
        app.tabBars.buttons["Spending"].tap()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 20))
        // Categories sit below the month's gauge and plan.
        let dining = app.staticTexts["Dining"]
        for _ in 0..<5 where !dining.exists { app.swipeUp() }
        XCTAssertTrue(dining.waitForExistence(timeout: 5))
        snapshot("spending")
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.staticTexts["Can save / mo"].waitForExistence(timeout: 20))
        snapshot("plan")
        app.tabBars.buttons["Activity"].tap()
        // The "Needs review" quick filter is there whether or not anything waits.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Needs review'")).firstMatch.waitForExistence(timeout: 20))
        snapshot("activity")
    }

    /// Running the checkup again visibly reloads: the button spins, then says it updated.
    func testCheckupReloadShowsUpdated() {
        let app = launch(["-checkup"])
        let button = app.buttons["reloadButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Checkup'")).firstMatch.waitForExistence(timeout: 20))
        button.tap()
        let note = app.descendants(matching: .any).matching(identifier: "reloadNote").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertTrue(note.label.hasPrefix("Updated"), note.label)
        snapshot("checkup-reloaded")
    }

    /// Live Qwen proposes on the server; nothing changes until Apply; the ledger confirms it.
    func testLiveAskProposalApplies() {
        let app = launch(["-ask", "Set my dining budget to $520 a month"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 120), "the live model should propose a target change")
        XCTAssertTrue(app.staticTexts["Not applied"].exists)
        snapshot("ask-proposal")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Dining target is now $520 a month."].waitForExistence(timeout: 30))
        snapshot("ask-applied")
        app.tabBars.buttons["Spending"].tap()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 20))
        let target = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '$520 target'")).firstMatch
        for _ in 0..<5 where !target.exists { app.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        snapshot("spending-after-apply")
    }

    /// A read-only question is answered from tool results, with the tool trace shown.
    func testLiveAskAnswersFromTools() {
        let app = launch(["-ask", "How much have I spent on DoorDash this month?"])
        let trace = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'tool sumByMerchant'")).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 120))
        XCTAssertTrue(app.staticTexts["qwen3.8-27b"].exists, "the reply should be attributed to the live model")
        snapshot("ask-doordash")
    }

    /// Settings → Advanced shows the server's status (the connection checked live, the categorization model); the
    /// threshold is on Review.
    func testSettingsShowsServer() {
        let app = launch()
        app.buttons["Settings"].tap()
        let advanced = app.buttons["settingsAdvanced"]
        for _ in 0..<6 where !(advanced.exists && advanced.isHittable) { app.swipeUp(velocity: .slow) }
        advanced.tap()
        // Settings shows what the app is talking to, so Done can't silently flip it back to demo.
        let demo = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Use the demo ledger'")).firstMatch
        if demo.waitForExistence(timeout: 5) { XCTAssertEqual(demo.value as? String, "0") }
        XCTAssertEqual(app.textFields["serverAddress"].value as? String, server)
        // The connection card checks the server live when Advanced opens.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Reachable'")).firstMatch.waitForExistence(timeout: 20))
        snapshot("settings")
        // List rows leave the accessibility tree once scrolled off, so check each as it comes into view.
        let model = app.staticTexts["Files uncertain transactions"]
        for _ in 0..<6 where !model.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(model.exists, "the categorization model should be on the server's Advanced page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let review = app.buttons["settingsReview"]
        for _ in 0..<6 where !(review.exists && review.isHittable) { app.swipeDown(velocity: .slow) }
        review.tap()
        XCTAssertTrue(app.staticTexts["Sure enough at"].waitForExistence(timeout: 10) || app.staticTexts["Off"].exists)
    }
    /// The morning summary: turning it on asks to notify, registers this phone's token and time zone with the server,
    /// and says what's still missing — a local test server has no APNs key, so that's what it should say.
    func testMorningSummaryRegisters() {
        // A stand-in token: the simulator may not reach APNs, and the server only needs one to register.
        let app = launch(["-settings", "-pushToken", String(repeating: "5e", count: 32)])
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Morning summary'")).firstMatch
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings should offer the morning summary with a server")
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        // iOS asks once; a rerun on the same simulator finds it already allowed.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'add an APNs key' OR label CONTAINS 'follows your phone'")).firstMatch
        // The note sits under the section's rows; bring it into view.
        for _ in 0..<4 where !note.waitForExistence(timeout: 5) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(note.exists, "the server should answer the registration")
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.datePickers["settingsMorningSummaryTime"].exists || app.buttons.matching(NSPredicate(format: "label CONTAINS '9:30'")).firstMatch.exists,
                      "the time should be shown to change")
        snapshot("morning-summary")
    }
    /// Turning the summary on with no stand-in token: whether iOS answers or not, the app is still running (and saying
    /// something) after the 20 seconds the token wait allows.
    func testMorningSummaryWithoutToken() {
        let app = launch(["-settings"])
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Morning summary'")).firstMatch
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)], timeout: 10)
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        sleep(26)
        XCTAssertEqual(app.state, .runningForeground, "the app should survive the token wait")
        snapshot("morning-summary-no-token")
    }
}
