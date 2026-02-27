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

    // MARK: - Mock Helpers (uses MockACPTransport via --uitesting)

    /// Navigate to cp32 > home and wait for mock connection.
    private func navigateToSessionPicker() {
        let cp32 = app.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
        cp32.tap()

        let home = app.staticTexts["home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()

        // Mock connection should be near-instant
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 10),
            "New Session button should appear — mock connection may have failed"
        )
    }

    /// Create a new session and verify we land in ChatView.
    private func createSessionAndEnterChat() {
        navigateToSessionPicker()

        app.buttons["New Session"].tap()

        // Verify system message proves session was actually created
        let systemMessage = app.staticTexts["New session on home"]
        XCTAssertTrue(
            systemMessage.waitForExistence(timeout: 10),
            "System message 'New session on home' should appear — session may not have been created"
        )

        // Verify we're in the chat view
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
    }

    // MARK: - Mock-Backed E2E Tests

    func testConnectAndCreateSession() throws {
        createSessionAndEnterChat()
    }

    func testCreateSessionShowsLoading() throws {
        navigateToSessionPicker()

        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.isEnabled, "New Session button should be enabled before tap")

        newSessionButton.tap()

        // Mock creates session nearly instantly — we may already be in ChatView.
        // Verify either: (a) button is disabled (still on session picker), or
        // (b) we navigated to ChatView (session was created).
        let disconnectButton = app.buttons["Disconnect"]
        let buttonDisabled = newSessionButton.exists && !newSessionButton.isEnabled
        let navigatedToChat = disconnectButton.waitForExistence(timeout: 5)

        XCTAssertTrue(
            buttonDisabled || navigatedToChat,
            "Should either show disabled button (loading) or navigate to chat (created)"
        )
    }

    func testSendMessageAndReceiveResponse() throws {
        createSessionAndEnterChat()

        // Type a message
        let textField = app.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5), "Chat input should exist")
        textField.tap()
        textField.typeText("Hello, this is a test message")

        // Send
        let sendButton = app.buttons["arrow.up.circle.fill"]
        sendButton.tap()

        // Verify user message appears
        let userMessage = app.staticTexts["Hello, this is a test message"]
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 5),
            "User message should appear in chat"
        )

        // The mock's simple scenario streams text (~350ms total) then sends promptComplete.
        // After completion, the "Thinking..." indicator should disappear.
        // Wait a moment for the mock to finish streaming.
        sleep(3)

        // Verify streaming completed — "Thinking..." should no longer be visible
        let thinking = app.staticTexts["Thinking..."]
        XCTAssertFalse(
            thinking.exists,
            "Thinking indicator should disappear after mock response completes"
        )
    }

    func testResumeSession() throws {
        // First create a session
        createSessionAndEnterChat()

        // Navigate back to session picker
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Wait for session picker to reappear
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(
            newSessionButton.waitForExistence(timeout: 5),
            "Should return to session picker"
        )

        // The session we just created should appear in "Sessions"
        let sessionsSection = app.staticTexts["Sessions"]
        XCTAssertTrue(
            sessionsSection.waitForExistence(timeout: 5),
            "Sessions section should appear after creating a session"
        )

        // Session rows display a truncated session id when there's no title.
        // For mock sessions this starts with "mock-ses".
        let mockSessionText = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'mock-ses'")
        )
        XCTAssertTrue(
            mockSessionText.firstMatch.waitForExistence(timeout: 3),
            "Mock session ID should be visible in recent sessions"
        )
        mockSessionText.firstMatch.tap()

        // Verify session resume system message appears in ChatView
        // The mock's session/load succeeds, so we get "Session resumed"
        let resumedMessage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Session re'")
        )
        XCTAssertTrue(
            resumedMessage.firstMatch.waitForExistence(timeout: 10),
            "Session resume message should appear — resume may have failed"
        )

        // Verify we're in chat view
        let disconnectButton = app.buttons["Disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
    }

    // MARK: - Integration Tests (requires cp32 server)

    func testIntegrationSendMessage() throws {
        // Re-launch without --uitesting to use real server
        app.terminate()
        let integrationApp = XCUIApplication()
        integrationApp.launch()

        let cp32 = integrationApp.staticTexts["cp32"]
        XCTAssertTrue(cp32.waitForExistence(timeout: 5))
        cp32.tap()

        let home = integrationApp.staticTexts["home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()

        let newSessionButton = integrationApp.buttons["New Session"]
        guard newSessionButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("Could not connect to cp32 — server may be unreachable")
        }

        newSessionButton.tap()

        let systemMessage = integrationApp.staticTexts["New session on home"]
        guard systemMessage.waitForExistence(timeout: 15) else {
            throw XCTSkip("Session creation timed out — server may be unreachable")
        }

        let textField = integrationApp.textFields.firstMatch
        guard textField.waitForExistence(timeout: 5) else {
            throw XCTSkip("Chat input not found")
        }
        textField.tap()
        textField.typeText("Hello")

        integrationApp.buttons["arrow.up.circle.fill"].tap()

        let userMessage = integrationApp.staticTexts["Hello"]
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 5),
            "User message should appear in chat"
        )
    }
}
