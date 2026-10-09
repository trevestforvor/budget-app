import XCTest

/// Yearly charges and recurring corrections on the demo ledger: a transaction spread over the year from its details,
/// a subscription taken off recurring and put back, and a merchant added as recurring. Screenshots go to
/// $SCREENSHOT_DIR when set (TEST_RUNNER_SCREENSHOT_DIR).
@MainActor
final class RecurringUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + arguments
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

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testYearlySwitchSpreadsACharge() {
        let app = launch(["-tab", "activity", "-activity", "detail:Bluebird Coffee"])
        let yearly = app.switches["yearlyToggle"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 10))
        scroll(to: yearly, in: app)
        yearly.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(element(app, containing: "Spread over the year").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "a month for 12 months").exists)
        snapshot("detail-yearly")
    }

    func testTakeOffRecurringAndPutBack() {
        let app = launch(["-open", "recurring"])
        let netflix = element(app, containing: "Netflix")
        // The "To review" card (0.5.0) sits above the list, so the list starts below the fold.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recurringLayout").firstMatch.waitForExistence(timeout: 10))
        scroll(to: netflix, in: app)
        XCTAssertTrue(netflix.waitForExistence(timeout: 10))
        netflix.tap()
        let remove = app.buttons["recurringRemove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        snapshot("recurring-edit")
        remove.tap()

        let putBack = app.buttons["Put back"]
        scroll(to: putBack, in: app)
        XCTAssertTrue(putBack.waitForExistence(timeout: 10), "Netflix is listed under Not recurring with a way back")
        snapshot("recurring-not-recurring")
        putBack.tap()
        XCTAssertTrue(element(app, containing: "Budget decides whether Netflix recurs").waitForExistence(timeout: 10))
    }

    func testSwipeToDelete() {
        let app = launch(["-open", "recurring"])
        let spotify = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Spotify")).firstMatch
        // Off-screen rows aren't in the accessibility tree: wait for the screen, then scroll Spotify into view.
        XCTAssertTrue(app.staticTexts["Bills and subscriptions · next 30 days"].waitForExistence(timeout: 10))
        scroll(to: spotify, in: app)
        XCTAssertTrue(spotify.waitForExistence(timeout: 5))
        spotify.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        snapshot("recurring-swipe")
        delete.tap()
        XCTAssertTrue(element(app, containing: "Took Spotify off recurring").waitForExistence(timeout: 10))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Spotify")).firstMatch.waitForExistence(timeout: 10),
                      "Undo puts it back on the list")
    }

    func testAddAMerchantAsYearly() {
        let app = launch(["-open", "recurring"])
        let add = app.buttons["addRecurring"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Bluebird")
        let coffee = element(app, containing: "Bluebird Coffee")
        XCTAssertTrue(coffee.waitForExistence(timeout: 10))
        coffee.tap()

        let save = app.buttons["recurringSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        app.buttons["Yearly"].tap()
        XCTAssertTrue(element(app, containing: "a twelfth a month for a year").exists)
        snapshot("recurring-add-yearly")
        save.tap()

        // Both sheets close once it's saved; then the list shows every recurring charge.
        let addList = app.navigationBars["Add recurring"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: addList)
        waitForExpectations(timeout: 10)
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let added = element(app, containing: "set by you")
        scroll(to: added, in: app)
        XCTAssertTrue(added.waitForExistence(timeout: 10), "Bluebird Coffee is listed, marked as the person's")
        snapshot("recurring-added")
    }
}
