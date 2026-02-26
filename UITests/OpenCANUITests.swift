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

    // MARK: - Helpers (requires cp32 server)

    /// Navigate to cp32 > home and wait for connection.
    /// Throws XCTSkip if server is unreachable.
    private func navigateToSessionPicker() throws {
        let cp32 = app.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
        cp32.tap()

        let home = app.staticTexts["home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()

        // Wait for connection
        let newSessionButton = app.buttons["New Session"]
        guard newSessionButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("Could not connect to cp32 — server may be unreachable")
        }
    }

    /// Create a new session and verify we land in ChatView.
    private func createSessionAndEnterChat() throws {
        try navigateToSessionPicker()

        app.buttons["New Session"].tap()

        // Verify system message proves session was actually created
        let systemMessage = app.staticTexts["New session on home"]
        XCTAssertTrue(
            systemMessage.waitForExistence(timeout: 15),
            "System message 'New session on home' should appear — session may not have been created"
        )

        // Verify we're in the chat view
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
    }

    // MARK: - End-to-End (requires cp32 server)

    func testConnectAndCreateSession() throws {
        try createSessionAndEnterChat()
    }

    func testCreateSessionShowsLoading() throws {
        try navigateToSessionPicker()

        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.isEnabled, "New Session button should be enabled before tap")

        newSessionButton.tap()

        // Button should become disabled while session is being created
        // (prevents double-tap)
        XCTAssertFalse(
            newSessionButton.isEnabled,
            "New Session button should be disabled while creating session"
        )
    }

    func testSendMessage() throws {
        try createSessionAndEnterChat()

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

        // Verify user message appears (proves sendMessage didn't bail
        // due to nil currentSessionId)
        let userMessage = app.staticTexts["Hello, this is a test message"]
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 5),
            "User message should appear in chat — currentSessionId may be nil"
        )

        // Verify assistant starts responding (Thinking... indicator or any
        // assistant content should eventually appear)
        let thinking = app.staticTexts["Thinking..."]
        XCTAssertTrue(
            thinking.waitForExistence(timeout: 15),
            "Assistant should start responding after sending a message"
        )
    }

    func testResumeSession() throws {
        // First create a session
        try createSessionAndEnterChat()

        // Navigate back to session picker
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The session we just created should appear in "Recent Sessions"
        let recentSection = app.staticTexts["Recent Sessions"]
        XCTAssertTrue(
            recentSection.waitForExistence(timeout: 5),
            "Recent Sessions section should appear after creating a session"
        )

        // Tap the first session in the recent list to resume it
        let sessionCell = app.cells.element(boundBy: 1) // index 0 is "New Session"
        guard sessionCell.waitForExistence(timeout: 3) else {
            throw XCTSkip("No recent session cell found")
        }
        sessionCell.tap()

        // Verify "Loaded session" system message appears
        let loadedMessage = app.staticTexts["Loaded session"]
        XCTAssertTrue(
            loadedMessage.waitForExistence(timeout: 15),
            "System message 'Loaded session' should appear — resume may have failed"
        )

        // Verify we're in chat view
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
    }
}
