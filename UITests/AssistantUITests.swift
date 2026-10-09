import XCTest

/// Assistant memory and chat history on the demo ledger: the memory list, adding a memory, and reopening a kept
/// conversation from Recents. Screenshots go to $SCREENSHOT_DIR when set (TEST_RUNNER_SCREENSHOT_DIR).
@MainActor
final class AssistantUITests: XCTestCase {
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

    func testAssistantMemoryListsAndAdds() {
        let app = launch(["-open", "assistantMemory"])
        XCTAssertTrue(element(app, containing: "Saving for a trip to Lisbon next spring").waitForExistence(timeout: 10))
        snapshot("assistant-memory")
        app.buttons["addAssistantMemory"].tap()
        let field = app.textFields["assistantMemoryField"].exists ? app.textFields["assistantMemoryField"] : app.textViews["assistantMemoryField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Walks to work most days")
        app.buttons["Save"].tap()
        XCTAssertTrue(element(app, containing: "Walks to work most days").waitForExistence(timeout: 10))
    }

    func testRecentsReopenAConversation() {
        let app = launch(["-open", "conversations"])
        let dining = element(app, containing: "What did we spend on dining in Q3 vs Q2?")
        XCTAssertTrue(dining.waitForExistence(timeout: 10))
        snapshot("conversations")
        dining.tap()
        // Back on the hub with the conversation open: its later turn's card is from earlier, not offered again.
        XCTAssertTrue(app.buttons["New conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Set the dining target to $500").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Apply"].exists)
        snapshot("conversation-reopened")
    }
}
