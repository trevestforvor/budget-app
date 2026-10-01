import XCTest

/// A paced walkthrough of every screen and feature, for screen recordings. Skipped unless
/// `TEST_RUNNER_TOUR=1`. Runs against the server when `TEST_RUNNER_BUDGET_SERVER` and
/// `TEST_RUNNER_BUDGET_TOKEN` are set (seed it with the demo first), otherwise the demo ledger.
/// Steps that can't find their element are skipped rather than failing, so a recording survives.
@MainActor
final class DemoTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private let beat: TimeInterval = 1.5

    override func setUp() async throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["TOUR"] != "1", "Set TEST_RUNNER_TOUR=1 to run the walkthrough.")
        app = XCUIApplication()
        if let server = env["BUDGET_SERVER"], let token = env["BUDGET_TOKEN"] {
            app.launchArguments = ["-server", server, "-token", token]
        } else {
            app.launchArguments = DemoLaunch.arguments
        }
    }

    private func pause(_ beats: Double = 1) { Thread.sleep(forTimeInterval: beat * beats) }
    private let start = Date()
    private func section(_ name: String) { print(String(format: "TOUR %5.1fs %@", Date().timeIntervalSince(start), name)) }

    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10, scrolling: Bool = false) -> Bool {
        if scrolling {
            for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        }
        guard element.waitForExistence(timeout: timeout), element.isHittable else {
            print("TOUR skipped: \(element.description)")
            return false
        }
        element.tap()
        pause()
        return true
    }

    private func label(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func labelContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func scrollDown(_ times: Int = 1) { for _ in 0..<times { app.swipeUp(velocity: .slow); pause() } }
    private func scrollUp(_ times: Int = 1) { for _ in 0..<times { app.swipeDown(velocity: .slow) } ; pause(0.5) }
    private func back() { if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap(); pause() } }
    private func tab(_ name: String) { app.tabBars.buttons[name].tap(); pause() }

    private func ask(_ question: String, waitFor: XCUIElement, timeout: TimeInterval = 90) {
        let field = app.textViews["Ask about your money"].exists ? app.textViews["Ask about your money"] : app.textFields["Ask about your money"]
        guard field.waitForExistence(timeout: 10) else { return }
        field.tap()
        field.typeText(question)
        pause(0.5)
        let send = app.buttons.matching(identifier: "arrow.up").firstMatch
        if send.exists { send.tap() } else { field.typeText("\n") }
        _ = waitFor.waitForExistence(timeout: timeout)
        pause(1.5)
    }

    func testTour() {
        app.launch()

        section("home")
        // Home: safe to spend, flex budget, cash trend, insights, recent activity, accounts.
        _ = app.staticTexts["Safe to spend"].waitForExistence(timeout: 30)
        pause(2)
        scrollDown(3)
        scrollUp(4)

        section("spending")
        // Spending: the budget month and the one before, longer periods, a category's detail and target editor, caps.
        tab("Spending")
        pause()
        tap(app.buttons["Previous month"])
        tap(app.buttons["Next month"])
        for period in ["90 days", "Year to date", "Month"] { tap(app.buttons[period]) }
        if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dining' AND label CONTAINS 'target' AND NOT label CONTAINS 'Progress'")).firstMatch) {
            pause()
            if tap(app.buttons["Edit target"]) {
                pause()
                tap(app.buttons["Cancel"])
            }
            scrollDown(1)
            back()
        }
        scrollDown(2)
        scrollUp(3)

        section("activity")
        // Activity: the review queue answered a group at a time, search, a transaction's detail.
        tab("Activity")
        pause()
        let firstReview = app.buttons.matching(identifier: "reviewRow").firstMatch
        if tap(firstReview) {
            pause()
            tap(app.buttons["answerButton"])
            pause()
            tap(app.buttons["Done"], timeout: 3)
        }
        let search = app.searchFields.firstMatch
        if tap(search) {
            search.typeText("DoorDash")
            pause(2)
            if tap(app.cells.firstMatch.exists ? app.cells.firstMatch : app.buttons.matching(NSPredicate(format: "label CONTAINS 'DoorDash'")).element(boundBy: 0)) {
                pause()
                back()
            }
            let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
            tap(close, timeout: 3)
        }

        section("ask")
        // Ask: a read question answered from ledger tools, a proposed change applied, navigation.
        tab("Ask")
        pause()
        ask("How much have I spent on DoorDash this month?", waitFor: labelContaining("tool sumByMerchant"))
        ask("Cap DoorDash at $150 a month", waitFor: app.buttons["Apply"])
        tap(app.buttons["Apply"])
        pause()
        ask("How much can I save each month?", waitFor: labelContaining("tool savings"), timeout: 45)
        tap(app.buttons["New conversation"])
        ask("Show me groceries", waitFor: app.buttons["Open"])
        if tap(app.buttons["Open"]) {
            pause(1.5)
            back()
        }

        section("plan")
        // Plan: projection horizons, savings plan, a goal check.
        tab("Plan")
        pause()
        for months in ["3 months", "12 months", "6 months"] { tap(app.buttons[months]) }
        scrollDown(1)
        let savingsButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'monthly savings'")).firstMatch
        if tap(savingsButton, scrolling: true) {
            tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use 20%'")).firstMatch)
            tap(app.buttons["Save plan"])
        }
        tap(app.buttons["Check with the ledger"], scrolling: true)
        pause()
        scrollDown(1)
        scrollUp(4)

        section("settings")
        // Settings: categories, rules, review, accounts, what Budget has learned; Advanced holds the server, the
        // model, the assistant (system prompt, tools) and the design system.
        tab("Home")
        if tap(app.buttons["Settings"]) {
            pause()
            for page in ["settingsCategories", "settingsRules", "settingsReview", "settingsAccounts", "settingsMemory"] {
                if tap(app.buttons[page], scrolling: true) { scrollDown(1); scrollUp(1); back() }
            }
            if tap(app.buttons["settingsAdvanced"], scrolling: true) {
                if tap(labelContaining("System prompt"), scrolling: true) { scrollDown(1); back() }
                if tap(labelContaining("Tools"), scrolling: true) {
                    if tap(app.staticTexts["adjustCategoryTarget"], scrolling: true) { scrollDown(1); back() }
                    back()
                }
                if tap(labelContaining("Design system"), scrolling: true) { scrollDown(2); back() }
                back()
            }
            tap(app.buttons["Done"])
        }
        pause(2)
        section("end")
    }
}
