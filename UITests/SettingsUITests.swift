import XCTest

/// Settings and everything reachable from it, on the demo ledger. Screenshots go to $SCREENSHOT_DIR when set
/// (pass `TEST_RUNNER_SCREENSHOT_DIR=/path` to xcodebuild) and are attached to the result bundle.
@MainActor
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = [], textSize: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-settings"] + arguments
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
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

    private func element(_ identifierOrLabel: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", identifierOrLabel, identifierOrLabel)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    /// Lists only put on-screen rows in the accessibility tree, so swipe until the element is hittable: down the
    /// page first, then back up. A row scrolled under the translucent navigation bar still counts as hittable, but a
    /// tap there lands on the bar, so its middle has to be below the bar too.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        func inView() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let bar = app.navigationBars.firstMatch
            return !bar.exists || element.frame.midY > bar.frame.maxY
        }
        if element.waitForExistence(timeout: 3), inView() { return element }
        for _ in 0..<6 where !inView() { app.swipeUp() }
        for _ in 0..<10 where !inView() { app.swipeDown() }
        return element
    }

    private func open(_ row: String) {
        let link = reveal(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", row, row, row + ",")).firstMatch)
        XCTAssertTrue(link.exists, "\(row) should be in Settings")
        link.tap()
    }

    // MARK: Root

    /// The root is about money first: a sign-in notice, the budget pages, accounts, memory, privacy, then Advanced.
    func testRootLeadsWithTheBudget() {
        launch()
        XCTAssertTrue(text(containing: "Tidewater needs you to sign in again").waitForExistence(timeout: 10))
        for row in ["settingsCategories", "settingsRules", "settingsReview", "settingsTargets", "settingsAccounts"] {
            XCTAssertTrue(element(row).exists, "\(row) should be on the root")
        }
        XCTAssertTrue(text(containing: "1 conflict").waitForExistence(timeout: 5), "the demo's two Uber rules disagree")
        snapshot("settings-root")
        XCTAssertTrue(reveal(element("settingsAdvanced")).exists)
        // "Face ID lock" on a phone with Face ID; the simulator only offers the passcode.
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS 'when you open Budget'")).firstMatch.exists)
        XCTAssertTrue(text(containing: "Demo ledger on this phone").exists, "footer says what the app talks to")
        snapshot("settings-root-bottom")
    }

    // MARK: Categories

    /// Categories by budget type; editing one changes its colour through the ledger, and a new one lands in its section.
    func testCategoriesEditAndAdd() {
        launch()
        open("settingsCategories")
        XCTAssertTrue(element("category-dining").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["BILLS"].exists || app.staticTexts["Bills"].exists)
        XCTAssertTrue(app.buttons["addCategory"].exists, "adding one is the first row, not only the toolbar's +")
        snapshot("categories")

        element("category-dining").tap()
        XCTAssertTrue(app.navigationBars["Edit category"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Merge into another category").waitForExistence(timeout: 10), "dining has rows, so it merges rather than deletes")
        snapshot("category-editor")
        app.buttons["Teal"].tap()
        app.buttons["saveCategory"].tap()
        XCTAssertTrue(element("category-dining").waitForExistence(timeout: 10))

        // The row at the top of the list, not only the toolbar's "+".
        let add = reveal(app.buttons["addCategory"])
        XCTAssertEqual(add.label, "Add a category")
        add.tap()
        let name = app.textFields["categoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pets")
        app.buttons["Bills"].tap()
        app.buttons["Pets"].firstMatch.tap() // the paw print, found by its label
        snapshot("category-new")
        app.buttons["saveCategory"].tap()
        XCTAssertTrue(reveal(element("category-pets")).exists, "the new category shows in the list")
    }

    /// Money in has its own section (Income and the demo's Card rewards). An existing category shows its type without
    /// changing it; a new one can be money in, which hides the budget type and says in a line what it does.
    func testMoneyInCategories() {
        launch()
        open("settingsCategories")
        XCTAssertTrue(element("category-dining").waitForExistence(timeout: 10))
        let rewards = reveal(element("category-card-rewards"))
        XCTAssertTrue(rewards.exists, "the demo's Card rewards is listed")
        XCTAssertTrue(element("category-income").exists, "Income sits in the same section")
        snapshot("categories-money-in")

        rewards.tap()
        XCTAssertTrue(app.navigationBars["Edit category"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("categoryType").label, "Money in", "an existing category's type is shown, not offered")
        XCTAssertTrue(text(containing: "Counts as money coming in, like income").exists)
        XCTAssertFalse(app.buttons["Bills"].exists, "money in has no budget type")
        XCTAssertTrue(text(containing: "Merge into another category").waitForExistence(timeout: 10), "it merges into other money in")
        snapshot("category-editor-card-rewards")
        app.buttons["Cancel"].tap()

        app.buttons["addCategoryToolbar"].tap()
        let name = app.textFields["categoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Cash back")
        XCTAssertTrue(app.buttons["Bills"].exists, "a new category starts as spending")
        app.buttons["Money in"].tap()
        XCTAssertTrue(text(containing: "Counts as money coming in, like income").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Bills"].exists, "choosing money in hides the budget type")
        snapshot("category-new-money-in")
        app.buttons["saveCategory"].tap()
        XCTAssertTrue(reveal(element("category-cash-back")).exists, "the new money-in category shows in the list")
        snapshot("categories-with-cash-back")
    }

    // MARK: Rules

    /// The demo's rules come newest first with their hits; the conflict is called out; a new rule previews live.
    func testRulesListAndLivePreview() {
        launch()
        open("settingsRules")
        XCTAssertTrue(text(containing: "2 rules disagree").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Filed").exists, "hit counts show")
        snapshot("rules")

        app.buttons["Add a rule"].tap()
        let descriptor = app.textFields["ruleDescriptor"]
        XCTAssertTrue(descriptor.waitForExistence(timeout: 5))
        descriptor.tap()
        descriptor.typeText("NETFLIX")
        app.buttons["ruleCategory"].tap()
        XCTAssertTrue(app.navigationBars["File it under"].waitForExistence(timeout: 5))
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Entertainment'")).firstMatch).tap()
        XCTAssertTrue(text(containing: "would be filed").waitForExistence(timeout: 10), "the preview counts what saving would file")
        snapshot("rule-editor-preview")
        app.buttons["saveRule"].tap()
        XCTAssertTrue(text(containing: "NETFLIX").waitForExistence(timeout: 10), "the new rule is listed")
        snapshot("rules-after-add")
    }

    // MARK: New category from a picker

    /// "New category…" tops the rule editor's picker and opens the same editor as Settings (already on money in for a
    /// rule on money coming in); the category it makes is the one the rule files under.
    func testNewCategoryFromRuleEditor() {
        launch()
        open("settingsRules")
        XCTAssertTrue(text(containing: "2 rules disagree").waitForExistence(timeout: 10))
        app.buttons["Add a rule"].tap()
        let descriptor = app.textFields["ruleDescriptor"]
        XCTAssertTrue(descriptor.waitForExistence(timeout: 5))
        descriptor.tap()
        descriptor.typeText("YARN")

        app.buttons["Coming in"].tap()
        app.buttons["ruleCategory"].tap()
        XCTAssertTrue(app.navigationBars["File it under"].waitForExistence(timeout: 5))
        let new = app.buttons["newCategory"]
        XCTAssertTrue(new.waitForExistence(timeout: 5), "New category… sits at the top of the picker")
        snapshot("picker-new-category")
        new.tap()
        XCTAssertTrue(app.navigationBars["New category"].waitForExistence(timeout: 5), "the Settings editor, not a second one")
        XCTAssertTrue(app.otherElements["categoryType"].buttons["Money in"].isSelected, "a rule for money coming in starts a money-in category")
        app.navigationBars["New category"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["File it under"].waitForExistence(timeout: 5), "cancelling goes back to the picker")
        app.navigationBars["File it under"].buttons["Cancel"].tap()

        app.buttons["Either way"].tap()
        app.buttons["ruleCategory"].tap()
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        let name = app.textFields["categoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["categoryType"].buttons["Spending"].isSelected)
        name.tap()
        name.typeText("Pottery test")
        snapshot("picker-new-category-editor")
        app.buttons["saveCategory"].tap()
        XCTAssertTrue(app.navigationBars["New rule"].waitForExistence(timeout: 10), "saving the category goes back to the rule")
        let category = app.buttons["ruleCategory"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(category.label.contains("Pottery test"), "the new category is what the rule files under (\(category.label))")
        snapshot("rule-editor-new-category")
    }

    /// From a transaction's category chip: search, "New category…" takes the search as its name, and saving re-files
    /// the transaction under it.
    func testNewCategoryFromTransactionDetail() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-tab", "activity", "-activity", "detail:DoorDash"]
        app.launch()
        let chip = app.buttons["categoryChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        chip.tap()
        let new = app.buttons["newCategory"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        // The picker's own search (Activity's sits under the sheet), pulled down into view.
        let search = app.searchFields.matching(NSPredicate(format: "label == 'Categories' OR placeholderValue == 'Categories'")).firstMatch
        if !search.waitForExistence(timeout: 2) { new.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Takeout")
        XCTAssertTrue(text(containing: "No category called").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Named “Takeout”").exists, "the row says it takes the search as the name")
        snapshot("detail-picker-new-category")
        new.tap()
        let name = app.textFields["categoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Takeout", "the search becomes the name")
        snapshot("detail-new-category-editor")
        app.buttons["saveCategory"].tap()
        // DoorDash's other rows are filed as Dining, so the ledger offers to file them too (apply to similar).
        let fileSimilar = app.buttons["fileSimilarButton"]
        XCTAssertTrue(fileSimilar.waitForExistence(timeout: 10), "re-filing offers the merchant's other rows")
        fileSimilar.tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Takeout'"), object: chip)], timeout: 10)
        XCTAssertEqual(chip.value as? String, "Takeout", "the transaction is re-filed under it")
    }

    // MARK: Review

    /// The review page: the waiting card, the toggles, and "Open review" landing on Activity's review.
    func testReviewSettingsOpensReview() {
        launch()
        open("settingsReview")
        XCTAssertTrue(text(containing: "8 quick answers file 11 transactions").waitForExistence(timeout: 10), "counted in decisions, like Activity")
        let newMerchants = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'New merchants'")).firstMatch
        XCTAssertTrue(newMerchants.exists)
        newMerchants.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() // the switch itself, not its label
        XCTAssertEqual(newMerchants.value as? String, "1")
        snapshot("review-settings")
        app.buttons["openReview"].tap()
        XCTAssertTrue(text(containing: "1 of 8").waitForExistence(timeout: 10), "the first decision opens in Activity's one-at-a-time review")
        XCTAssertTrue(app.buttons["answerButton"].exists)
        snapshot("review-opened")
        app.buttons["Done"].tap()
        XCTAssertTrue(text(containing: "Needs review · 8").waitForExistence(timeout: 10), "closing it leaves you on Activity")
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected)
    }

    // MARK: Accounts

    /// Accounts grouped by institution, statement-only included, with the sign-in card and Sync now.
    func testAccountsGroupsAndSyncs() {
        launch()
        open("settingsAccounts")
        XCTAssertTrue(text(containing: "Tidewater needs you to sign in again").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Total Checking ••0909").exists, "account numbers' last digits show")
        snapshot("accounts")
        XCTAssertTrue(reveal(text(containing: "Keystone Mastercard")).exists, "a card that only comes from statements is listed")
        XCTAssertTrue(text(containing: "From statements").exists)
        snapshot("accounts-statements")
        app.buttons["syncNow"].tap()
        XCTAssertTrue(text(containing: "Tidewater waits for you to sign in again").waitForExistence(timeout: 15), "the sync says what came in and who's waiting")
        snapshot("accounts-synced")
        app.buttons["Add an account"].tap()
        XCTAssertTrue(text(containing: "Add accounts on your dashboard").waitForExistence(timeout: 5))
        snapshot("accounts-add")
    }

    // MARK: Memory

    /// What Budget has learned: filters, and forgetting a merchant.
    func testMemoryForgets() {
        launch()
        open("settingsMemory")
        XCTAssertTrue(text(containing: "merchants").waitForExistence(timeout: 10))
        snapshot("memory")
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        search.tap()
        search.typeText("Netflix")
        XCTAssertTrue(text(containing: "Netflix").waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Netflix".count))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rules'")).firstMatch.tap()
        XCTAssertTrue(text(containing: "Uber").waitForExistence(timeout: 5))
        XCTAssertFalse(text(containing: "Netflix").exists, "the Rules filter shows only what rules filed")
        snapshot("memory-rules")
        text(containing: "Uber").tap()
        XCTAssertTrue(app.buttons["Make a rule"].waitForExistence(timeout: 5))
        snapshot("memory-actions")
        app.buttons["Forget"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Forget'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(text(containing: "Forgot Uber").waitForExistence(timeout: 10))
    }

    // MARK: Privacy, targets, advanced

    func testPrivacyAndTargets() {
        launch()
        open("settingsPrivacy")
        XCTAssertTrue(text(containing: "Your transactions stay on your Olares").waitForExistence(timeout: 10))
        snapshot("privacy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("settingsTargets")
        XCTAssertTrue(text(containing: "Monthly targets").waitForExistence(timeout: 10))
        snapshot("targets")
        reveal(text(containing: "Housing")).tap()
        XCTAssertTrue(app.buttons["Save target"].waitForExistence(timeout: 5), "the same target editor as Spending")
    }

    /// Advanced keeps the connection, the model, the prompt and every tool schema.
    func testAdvancedShowsServerAndAssistant() {
        launch()
        open("settingsAdvanced")
        XCTAssertTrue(text(containing: "Demo ledger").waitForExistence(timeout: 10))
        snapshot("advanced")
        open("System prompt")
        XCTAssertTrue(text(containing: "Numbers come from the ledger").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("Tools")
        let tool = reveal(app.staticTexts["adjustCategoryTarget"])
        XCTAssertTrue(tool.exists)
        tool.tap()
        XCTAssertTrue(app.staticTexts["PARAMETERS"].waitForExistence(timeout: 5) || app.staticTexts["Parameters"].exists)
    }

    // MARK: Against a server

    /// On a (local, demo-seeded) server: Advanced checks the connection live and links the dashboard, the privacy
    /// page can clear the offline copy, and "Disconnect this phone" goes back to Connect. Skipped unless
    /// `TEST_RUNNER_BUDGET_SERVER` and `TEST_RUNNER_BUDGET_TOKEN` are set.
    func testServerAdvancedAndDisconnect() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["BUDGET_SERVER"], let token = env["BUDGET_TOKEN"] else {
            throw XCTSkip("Set TEST_RUNNER_BUDGET_SERVER and TEST_RUNNER_BUDGET_TOKEN to run against a server.")
        }
        app = XCUIApplication()
        app.launchArguments = ["-noDemo", "-resetSettings", "-server", server, "-token", token, "-settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        XCTAssertTrue(reveal(text(containing: "Connected")).exists)
        snapshot("server-root")

        open("settingsPrivacy")
        let clear = reveal(app.buttons["Clear offline copy"])
        XCTAssertTrue(clear.exists)
        XCTAssertTrue(text(containing: "Server token").exists)
        clear.tap()
        XCTAssertTrue(app.buttons["Offline copy cleared"].waitForExistence(timeout: 5))
        snapshot("server-privacy")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        open("settingsAccounts")
        XCTAssertTrue(text(containing: "Keystone").waitForExistence(timeout: 10))
        app.buttons["Add an account"].tap()
        XCTAssertTrue(app.buttons["Open dashboard"].waitForExistence(timeout: 5), "the server says where its dashboard is")
        snapshot("server-accounts-add")
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        open("settingsAdvanced")
        XCTAssertTrue(text(containing: "Reachable").waitForExistence(timeout: 15), "Advanced checks the connection when it opens")
        snapshot("server-advanced")
        XCTAssertTrue(reveal(text(containing: "Open the Budget dashboard")).exists)
        let disconnect = reveal(app.buttons["Disconnect this phone"])
        XCTAssertTrue(disconnect.exists)
        snapshot("server-advanced-bottom")
        disconnect.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Disconnect'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Connect to your server"].waitForExistence(timeout: 10), "the phone forgets the server")
        snapshot("server-disconnected")
    }

    // MARK: Lock

    /// The lock screen covers everything until unlocked (the simulator has no passcode, so Unlock simply opens).
    func testLockScreen() {
        app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-locked"]
        app.launch()
        let unlock = app.buttons["unlockButton"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        snapshot("lock")
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Large text

    /// The main pages at the largest accessibility size: nothing truncates into uselessness, rows stack.
    func testAccessibilityTextSize() {
        launch(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(text(containing: "Tidewater needs you to sign in again").waitForExistence(timeout: 10))
        snapshot("ax-settings-root")
        app.swipeUp()
        snapshot("ax-settings-root-2")
        open("settingsRules")
        XCTAssertTrue(text(containing: "2 rules disagree").waitForExistence(timeout: 10))
        snapshot("ax-rules")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("settingsAccounts")
        XCTAssertTrue(text(containing: "Tidewater").waitForExistence(timeout: 10))
        app.swipeUp()
        snapshot("ax-accounts")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("settingsReview")
        XCTAssertTrue(text(containing: "8 quick answers file 11 transactions").waitForExistence(timeout: 10), "counted in decisions, like Activity")
        snapshot("ax-review")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open("settingsCategories")
        XCTAssertTrue(element("category-housing").waitForExistence(timeout: 10))
        snapshot("ax-categories")
        element("category-housing").tap()
        XCTAssertTrue(app.navigationBars["Edit category"].waitForExistence(timeout: 5))
        snapshot("ax-category-editor")
    }
}
