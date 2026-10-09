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
            // A push token, so Settings offers the pace alerts.
            app.launchArguments = DemoLaunch.arguments + ["-pushToken", String(repeating: "ab", count: 32)]
        }
    }

    private func pause(_ beats: Double = 1) { Thread.sleep(forTimeInterval: beat * beats) }
    private let start = Date()
    /// Also prints the wall clock, so a recording can be trimmed to the tour.
    private func section(_ name: String) {
        print(String(format: "TOUR %5.1fs %@ at %.2f", Date().timeIntervalSince(start), name, Date().timeIntervalSince1970))
    }

    private func id(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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

        section("net worth")
        // Net worth: its history over each range, assets and debts, the ones entered by hand.
        if tap(id("openNetWorth"), scrolling: true) {
            pause()
            for range in ["1Y", "ALL", "3M"] { tap(app.buttons[range]) }
            scrollDown(2)
            scrollUp(2)
            back()
        }
        scrollUp(5)

        section("spending")
        // Spending: the budget month and the one before, longer periods, a category's detail and target editor, caps.
        tab("Spending")
        pause()
        tap(app.buttons["Previous month"])
        tap(app.buttons["Next month"])
        for period in ["90 days", "Year to date", "Month"] { tap(app.buttons[period]) }
        // Where the month's money went, as a flow from income to buckets to categories.
        if tap(app.buttons["Flow"], scrolling: true) {
            scrollDown(1)
            pause(2)
            scrollUp(1)
            tap(app.buttons["Top categories"], scrolling: true)
        }
        scrollUp(3)
        if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dining' AND label CONTAINS 'target' AND NOT label CONTAINS 'Progress'")).firstMatch, scrolling: true) {
            pause()
            if tap(app.buttons["Edit target"]) {
                pause()
                tap(app.buttons["Cancel"])
            }
            scrollDown(1)
            back()
        }
        // The most frequent merchants, then what's coming up: the review questions and the calendar.
        for _ in 0..<6 where !(id("mostFrequent").exists && id("mostFrequent").isHittable) { scrollDown(1) }
        pause()
        if tap(app.buttons.matching(identifier: "recurring").firstMatch, scrolling: true) {
            pause()
            scrollDown(1)
            scrollUp(1)
            if tap(app.buttons["Calendar"]) {
                pause()
                tap(id("upcomingDay"))
                pause()
                scrollDown(2)
                scrollUp(2)
                tap(app.buttons["List"])
            }
            back()
        }
        scrollUp(6)

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
            search.typeText("DoorDash\n")
            pause(2)
            if tap(app.buttons.matching(identifier: "activityRow").firstMatch, scrolling: true) {
                pause()
                // The merchant's page: spend over time, how often, its category and rules.
                if tap(id("merchantLink"), scrolling: true) {
                    pause()
                    scrollDown(2)
                    scrollUp(2)
                    back()
                }
                back()
            }
            let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
            tap(close, timeout: 3)
        }
        // Tags: a trip's transactions found by tag, and what the trip cost.
        if tap(search) {
            search.typeText("Austin\n")
            pause(2)
            if tap(app.buttons.matching(identifier: "activityRow").firstMatch, scrolling: true) {
                if tap(app.buttons["Austin trip"], scrolling: true) {
                    pause(2)
                    back()
                }
                back()
            }
            let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
            tap(close, timeout: 3)
        }

        section("ask")
        // Ask: a read question answered from ledger tools, a proposed change applied, navigation.
        tab("Ask")
        pause()
        ask("Where did my money go this month?", waitFor: labelContaining("Computed by the ledger"), timeout: 8)
        ask("Cap DoorDash at $150 a month", waitFor: app.buttons["Apply"], timeout: 8)
        tap(app.buttons["Apply"])
        pause()
        ask("How much can I save each month?", waitFor: labelContaining("Can save a month"), timeout: 8)
        tap(app.buttons["New conversation"])
        ask("Show me groceries", waitFor: app.buttons["Open"], timeout: 8)
        if tap(app.buttons["Open"]) {
            pause(1.5)
            back()
        }
        // Past conversations, kept on the server.
        if tap(app.buttons["Conversations"]) {
            pause(2)
            back()
        }

        section("plan")
        // Plan: projection horizons, savings plan, a goal check.
        tab("Plan")
        pause()
        for months in ["3 months", "12 months", "6 months"] { tap(app.buttons[months]) }
        // A scenario (a new car) against the plain forecast.
        if tap(app.buttons["New car"], scrolling: true) {
            pause(2)
            tap(app.buttons["Plain forecast"])
        }
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
        // Settings: categories, what Budget has learned, what Ask keeps in mind, pace alerts; then the design system,
        // under Advanced.
        tab("Home")
        if tap(app.buttons["Settings"]) {
            pause()
            for page in ["settingsCategories", "settingsMemory", "settingsAssistantMemory", "settingsPaceAlerts"] {
                if tap(app.buttons[page], scrolling: true) { scrollDown(1); scrollUp(1); back() }
            }
            if tap(app.buttons["settingsAdvanced"], scrolling: true) {
                if tap(labelContaining("Design system"), scrolling: true) { scrollDown(2); back() }
                back()
            }
            tap(app.buttons["Done"])
        }
        pause(2)
        section("end")
    }
}
