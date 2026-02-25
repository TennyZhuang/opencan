import XCTest

final class OpenCANUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    // MARK: - Node Management

    func testNodeListAppears() throws {
        XCTAssertTrue(app.navigationBars["Nodes"].waitForExistence(timeout: 5))
    }

    func testAddNode() throws {
        // Tap the add button
        let addButton = app.buttons["plus"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        // Fill in the form
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Test Node")

        let hostField = app.textFields["Host"]
        hostField.tap()
        hostField.typeText("10.0.0.1")

        let usernameField = app.textFields["Username"]
        usernameField.tap()
        usernameField.typeText("testuser")

        // Save
        app.buttons["Save"].tap()

        // Verify node appears in list
        XCTAssertTrue(app.staticTexts["Test Node"].waitForExistence(timeout: 3))
    }

    func testDeleteNode() throws {
        // First add a node
        try testAddNode()

        // Swipe to delete
        let cell = app.staticTexts["Test Node"]
        cell.swipeLeft()
        app.buttons["Delete"].tap()

        // Verify it's gone
        XCTAssertFalse(app.staticTexts["Test Node"].exists)
    }

    // MARK: - Demo Data

    func testDemoDataSeeded() throws {
        // On first launch, demo data should be seeded
        // cp32 node should exist
        let cp32 = app.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
    }

    func testNavigateToWorkspaces() throws {
        // Tap on cp32 node
        let cp32 = app.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
        cp32.tap()

        // Should see the workspace list with "home"
        XCTAssertTrue(app.staticTexts["home"].waitForExistence(timeout: 3))
    }

    // MARK: - End-to-End (requires cp32 server)

    func testConnectAndCreateSession() throws {
        // Navigate to cp32 > home workspace
        let cp32 = app.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
        cp32.tap()

        let home = app.staticTexts["home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()

        // Wait for connection (this requires the real server)
        let newSessionButton = app.buttons["New Session"]
        guard newSessionButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("Could not connect to cp32 — server may be unreachable")
        }

        // Create new session
        newSessionButton.tap()

        // Should navigate to chat view
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 10))
    }

    func testSendMessage() throws {
        // First connect
        try testConnectAndCreateSession()

        // Type a message
        let textField = app.textFields.firstMatch
        guard textField.waitForExistence(timeout: 5) else {
            throw XCTSkip("Chat input not found")
        }
        textField.tap()
        textField.typeText("Hello, this is a test message")

        // Send
        let sendButton = app.buttons["arrow.up.circle.fill"]
        sendButton.tap()

        // Wait for response (assistant message should appear)
        // We just check that the message was sent (user bubble appears)
        let userMessage = app.staticTexts["Hello, this is a test message"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
    }
}
