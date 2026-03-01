import XCTest
import SwiftData
@testable import OpenCAN

/// Unit tests for AppState session management using MockACPTransport.
/// These test the core flows: create session, send message, resume session
/// (draining, completed, history), and verify isPrompting state transitions.
@MainActor
final class AppStateTests: XCTestCase {
    private var appState: AppState!
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!
    private var workspace: Workspace!
    private var node: Node!

    override func setUp() async throws {
        // In-memory SwiftData container for testing
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(
            for: SSHKeyPair.self, Node.self, Workspace.self, Session.self,
            configurations: config
        )
        modelContext = ModelContext(modelContainer)

        // Create test node and workspace
        node = Node(name: "test", host: "127.0.0.1", username: "test")
        modelContext.insert(node)
        workspace = Workspace(name: "test-ws", path: "/test/path")
        workspace.node = node
        modelContext.insert(workspace)
        try modelContext.save()

        appState = AppState()
    }

    override func tearDown() async throws {
        appState?.disconnect()
        appState = nil
        modelContainer = nil
        modelContext = nil
    }

    // MARK: - Helpers

    /// Connect using mock transport and wait for connection.
    private func connectMock(scenario: MockScenario = .simple) async throws {
        appState.connectMock(workspace: workspace, scenario: scenario)
        try await waitFor(timeout: 5) { self.appState.connectionStatus == .connected }
    }

    /// Poll-wait for a condition with timeout.
    private func waitFor(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        file: StaticString = #file,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }

    // MARK: - Connection Tests

    func testMockConnect() async throws {
        appState.connectMock(workspace: workspace)
        try await waitFor(timeout: 5) { self.appState.connectionStatus == .connected }
        XCTAssertEqual(appState.connectionStatus, .connected)
    }

    // MARK: - New Session Tests

    func testCreateNewSession() async throws {
        try await connectMock()

        try await appState.createNewSession(modelContext: modelContext)

        XCTAssertNotNil(appState.currentSessionId, "Session ID should be set")
        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after creation")

        // Should have a system message
        let systemMessages = appState.messages.filter { $0.role == .system }
        XCTAssertEqual(systemMessages.count, 1, "Should have exactly one system message")
    }

    func testCreateNewSessionWithSelectedAgentUsesConfiguredCommand() async throws {
        try await connectMock()

        let defaults = UserDefaults.standard
        let key = AgentCommandStore.codexCommandKey
        let customCommand = "npx @zed-industries/codex-acp"
        let previous = defaults.string(forKey: key)
        defaults.set(customCommand, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        try await appState.createNewSession(modelContext: modelContext, agent: .codex)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let createdCommand = await transport.getLastCreateCommand()
        XCTAssertEqual(createdCommand, customCommand)
        XCTAssertEqual(appState.activeSession?.agentID, AgentKind.codex.rawValue)
        XCTAssertEqual(appState.activeSession?.agentCommand, customCommand)
    }

    func testRefreshAvailableAgentsUsesProbeResults() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            AgentKind.claude.rawValue: true,
            AgentKind.codex.rawValue: false,
        ])

        await appState.refreshAvailableAgents()

        XCTAssertTrue(appState.hasReliableAgentAvailability)
        XCTAssertEqual(appState.availableNodeAgents, [.claude])
    }

    func testRefreshAvailableAgentsUnsupportedProbeKeepsPreviousAvailability() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            AgentKind.claude.rawValue: true,
            AgentKind.codex.rawValue: false,
        ])
        await appState.refreshAvailableAgents()

        await transport.setMockAgentProbeUnsupported(true)
        await appState.refreshAvailableAgents()

        XCTAssertTrue(appState.hasReliableAgentAvailability)
        XCTAssertEqual(appState.availableNodeAgents, [.claude])
    }

    func testCreateNewSessionFallsBackWhenDefaultAgentUnavailable() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            AgentKind.claude.rawValue: true,
            AgentKind.codex.rawValue: false,
        ])
        await appState.refreshAvailableAgents()

        let defaults = UserDefaults.standard
        let key = AgentCommandStore.defaultAgentKey
        let previous = defaults.string(forKey: key)
        defaults.set(AgentKind.codex.rawValue, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        try await appState.createNewSession(modelContext: modelContext)

        XCTAssertEqual(appState.activeSession?.agentID, AgentKind.claude.rawValue)
    }

    func testCreateNewSessionFailsWhenNoAvailableAgents() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            AgentKind.claude.rawValue: false,
            AgentKind.codex.rawValue: false,
        ])
        await appState.refreshAvailableAgents()

        do {
            try await appState.createNewSession(modelContext: modelContext)
            XCTFail("Expected createNewSession to throw when no agents are available")
        } catch let error as AppStateError {
            guard case .noAvailableAgents = error else {
                XCTFail("Expected noAvailableAgents error, got \(error)")
                return
            }
        }
    }

    func testCreateNewSessionStillWorksWhenProbeUnsupported() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentProbeUnsupported(true)
        await appState.refreshAvailableAgents()

        let defaults = UserDefaults.standard
        let key = AgentCommandStore.defaultAgentKey
        let previous = defaults.string(forKey: key)
        defaults.set(AgentKind.codex.rawValue, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        try await appState.createNewSession(modelContext: modelContext)

        XCTAssertEqual(appState.activeSession?.agentID, AgentKind.codex.rawValue)
    }

    func testDiscardEmptyActiveSessionDeletesLocalRecordAndDaemonSession() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let sessionId = appState.currentSessionId else {
            XCTFail("Session ID should be set")
            return
        }
        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await appState.discardEmptyActiveSessionIfNeeded(modelContext: modelContext)

        XCTAssertNil(appState.currentSessionId)
        XCTAssertNil(appState.activeSession)
        XCTAssertTrue(appState.messages.isEmpty)

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let persisted = try modelContext.fetch(descriptor)
        XCTAssertTrue(persisted.isEmpty, "Empty session should be removed from SwiftData")

        let detached = await transport.getDetachedSessionIds()
        let killed = await transport.getKilledSessionIds()
        XCTAssertEqual(detached.last, sessionId)
        XCTAssertEqual(killed.last, sessionId)
    }

    func testDiscardEmptyActiveSessionDoesNotDeleteSessionWithConversation() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let sessionId = appState.currentSessionId else {
            XCTFail("Session ID should be set")
            return
        }
        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.sendMessage("hello")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        await appState.discardEmptyActiveSessionIfNeeded(modelContext: modelContext)

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let persisted = try modelContext.fetch(descriptor)
        XCTAssertEqual(persisted.count, 1, "Non-empty session should be kept")

        let killed = await transport.getKilledSessionIds()
        XCTAssertFalse(killed.contains(sessionId), "Non-empty session should not be killed")
    }

    func testNewSessionSendMessage() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        XCTAssertFalse(appState.isPrompting, "isPrompting should be false before send")

        // Send a message
        appState.sendMessage("Hello")

        // isPrompting should be true immediately
        XCTAssertTrue(appState.isPrompting, "isPrompting should be true after send")

        // Wait for the mock response to complete (delays total ~300ms)
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after response")

        // Verify messages: system + user + assistant
        let userMessages = appState.messages.filter { $0.role == .user }
        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        XCTAssertEqual(userMessages.count, 1, "Should have one user message")
        XCTAssertGreaterThanOrEqual(assistantMessages.count, 1, "Should have at least one assistant message")
    }

    func testSendMessageWithImageMentionAddsResourceLinkPromptBlock() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let mention = await appState.uploadImageMention(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
        guard let mention else {
            XCTFail("Expected uploaded mention")
            return
        }

        appState.sendMessage("请看这张图 \(mention.mentionToken)")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        guard let blocks = await transport.getLastPromptBlocks() else {
            XCTFail("Prompt blocks should be captured")
            return
        }
        XCTAssertEqual(blocks.count, 2, "Prompt should include text + resource_link blocks")
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "text")
        XCTAssertEqual(blocks[1]["type"]?.stringValue, "resource_link")
        XCTAssertEqual(blocks[1]["name"]?.stringValue, mention.mentionToken)
        XCTAssertEqual(blocks[1]["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertNotNil(blocks[1]["uri"]?.stringValue)
    }

    func testSendMessageWithUnknownImageMentionDoesNotAddResourceLinkBlock() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.sendMessage("请分析 @img_missing")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        guard let blocks = await transport.getLastPromptBlocks() else {
            XCTFail("Prompt blocks should be captured")
            return
        }
        XCTAssertEqual(blocks.count, 1, "Unknown mention should not emit resource_link")
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "text")

        let systemMessages = appState.messages.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(
            systemMessages.contains { $0.contains("Unknown image mention") && $0.contains("@img_missing") }
        )
    }

    func testSendMessageWithMultipleImageMentionsAddsMultipleResourceLinkBlocks() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let mention1 = await appState.uploadImageMention(
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png",
            fileExtension: "png"
        )
        let mention2 = await appState.uploadImageMention(
            data: Data([0x04, 0x05, 0x06]),
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
        guard let mention1, let mention2 else {
            XCTFail("Expected two uploaded mentions")
            return
        }

        appState.sendMessage("请比较 \(mention1.mentionToken) 和 \(mention2.mentionToken)")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        guard let blocks = await transport.getLastPromptBlocks() else {
            XCTFail("Prompt blocks should be captured")
            return
        }
        XCTAssertEqual(blocks.count, 3, "Prompt should include text + two resource_link blocks")
        XCTAssertEqual(blocks[1]["type"]?.stringValue, "resource_link")
        XCTAssertEqual(blocks[2]["type"]?.stringValue, "resource_link")
        XCTAssertEqual(blocks[1]["name"]?.stringValue, mention1.mentionToken)
        XCTAssertEqual(blocks[2]["name"]?.stringValue, mention2.mentionToken)
    }

    func testImageMentionsAreSessionScoped() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let mention = await appState.uploadImageMention(
            data: Data([0x09, 0x08, 0x07]),
            mimeType: "image/png",
            fileExtension: "png"
        )
        guard let mention else {
            XCTFail("Expected uploaded mention")
            return
        }

        // Switch to a new session; old session mentions should not leak.
        try await appState.createNewSession(modelContext: modelContext)
        appState.sendMessage("请看 \(mention.mentionToken)")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        guard let blocks = await transport.getLastPromptBlocks() else {
            XCTFail("Prompt blocks should be captured")
            return
        }
        XCTAssertEqual(blocks.count, 1, "Old session mention should not emit resource_link")
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "text")
    }

    func testUploadImageMentionBlockedWhileUploading() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        appState.isUploadingImage = true
        let mention = await appState.uploadImageMention(
            data: Data([0x01]),
            mimeType: "image/png",
            fileExtension: "png"
        )
        appState.isUploadingImage = false

        XCTAssertNil(mention, "upload should be blocked when upload flag is already true")
        let systemMessages = appState.messages.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(systemMessages.contains { $0.contains("already in progress") })
    }

    func testUploadImageMentionRejectsOversizedImage() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        let oversized = Data(repeating: 0x00, count: 12 * 1024 * 1024 + 1)
        let mention = await appState.uploadImageMention(
            data: oversized,
            mimeType: "image/png",
            fileExtension: "png"
        )

        XCTAssertNil(mention, "oversized image should be rejected")
        let systemMessages = appState.messages.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(systemMessages.contains { $0.contains("Image too large") })
    }

    func testNewSessionStreamingContent() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        appState.sendMessage("Hello")

        // Wait for completion
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        // Verify streaming content arrived (mock sends "Hello! I'm the mock assistant. How can I help you today?")
        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        XCTAssertFalse(assistantMessages.isEmpty, "Should have assistant messages")
        let fullText = assistantMessages.map { $0.content }.joined()
        XCTAssertTrue(
            fullText.contains("mock assistant"),
            "Assistant text should contain mock content, got: \(fullText)"
        )
    }

    func testSendSecondMessage() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        // First message
        appState.sendMessage("First")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        // Second message should work
        appState.sendMessage("Second")
        XCTAssertTrue(appState.isPrompting, "isPrompting should be true for second send")

        try await waitFor(timeout: 5) { !self.appState.isPrompting }
        XCTAssertFalse(appState.isPrompting, "isPrompting should clear after second response")

        let userMessages = appState.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 2, "Should have two user messages")
    }

    func testSendMessageWithoutPromptCompleteStillClearsPrompting() async throws {
        try await connectMock(scenario: .missingPromptComplete)
        try await appState.createNewSession(modelContext: modelContext)

        appState.sendMessage("Hello")
        XCTAssertTrue(appState.isPrompting, "isPrompting should be true after send")

        // No prompt_complete is emitted, so completion must still happen via
        // terminal session/prompt response fallback.
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        XCTAssertFalse(appState.isPrompting, "isPrompting should clear on terminal prompt response")
        XCTAssertFalse(
            appState.messages.contains { $0.role == .assistant && $0.isStreaming },
            "No assistant messages should remain streaming after prompt response"
        )

        let assistantText = appState.messages
            .filter { $0.role == .assistant }
            .map(\.content)
            .joined()
        XCTAssertTrue(
            assistantText.contains("omits prompt_complete"),
            "Assistant output should still be rendered, got: \(assistantText)"
        )
    }

    func testSendWhilePromptingIsBlocked() async throws {
        try await connectMock(scenario: .complex) // slower scenario
        try await appState.createNewSession(modelContext: modelContext)

        // Send first message
        appState.sendMessage("First")
        XCTAssertTrue(appState.isPrompting)

        // Immediately try to send second — should be blocked
        appState.sendMessage("Second")

        // Should see "Still waiting" system message
        let waitingMessages = appState.messages.filter {
            $0.role == .system && $0.content.contains("Still waiting")
        }
        XCTAssertEqual(waitingMessages.count, 1, "Should show 'still waiting' message")

        // Only one user message should exist (the first one)
        let userMessages = appState.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1, "Only first message should go through")
    }

    func testDisconnectWhilePromptingResetsPromptingState() async throws {
        try await connectMock(scenario: .complex)
        try await appState.createNewSession(modelContext: modelContext)

        appState.sendMessage("First")
        XCTAssertTrue(appState.isPrompting, "Should enter prompting before disconnect")

        appState.disconnect()
        XCTAssertFalse(appState.isPrompting, "disconnect should clear stale prompting state")

        // After reconnect, send should not be blocked by stale isPrompting.
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        appState.sendMessage("After reconnect")
        XCTAssertTrue(appState.isPrompting, "Should be able to send after reconnect")
    }

    func testPromptModelUnavailableErrorShowsFriendlyGuidance() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setNextPromptError(
            code: -32603,
            message: "Internal error: API Error: 503 {\"error\":{\"code\":\"model_not_found\",\"message\":\"no distributor (request id: req-xyz-123)\",\"type\":\"packy_api_error\"}}",
            data: nil
        )

        appState.sendMessage("trigger model unavailable")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        let lastAssistant = try XCTUnwrap(assistantMessages.last)
        XCTAssertTrue(
            lastAssistant.content.contains("Model unavailable on current provider group."),
            "Assistant message should contain concise model-unavailable error"
        )

        let systemMessages = appState.messages.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(
            systemMessages.contains { $0.contains("switching model/group") && $0.contains("req-xyz-123") },
            "System guidance should include remediation and request id"
        )
    }

    func testResumeDifferentSessionDetachesPreviousAttachment() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let initialSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockAttachState("idle")

        try await appState.resumeSession(sessionId: "other-session", modelContext: modelContext)

        let detachedSessionIds = await transport.getDetachedSessionIds()
        XCTAssertEqual(detachedSessionIds.last, initialSessionId, "Should detach previous session before switching")

        let receivedMethods = await transport.getReceivedMethods()
        let detachIndex = try XCTUnwrap(receivedMethods.lastIndex(of: DaemonMethods.sessionDetach))
        let attachIndex = try XCTUnwrap(receivedMethods.lastIndex(of: DaemonMethods.sessionAttach))
        XCTAssertLessThan(detachIndex, attachIndex, "Detach should happen before attaching the new session")
    }

    func testIgnoresNotificationsFromOtherSessions() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let currentSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.emitSessionTextDeltaForTest(
            sessionId: "foreign-session",
            text: "ignore-this-event"
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            appState.messages.contains { $0.content.contains("ignore-this-event") },
            "Events from other sessions should not mutate the active chat"
        )

        await transport.emitSessionTextDeltaForTest(
            sessionId: currentSessionId,
            text: "accept-this-event"
        )
        try await waitFor(timeout: 2) {
            self.appState.messages.contains { $0.content.contains("accept-this-event") }
        }
    }

    // MARK: - Resume Tests: Completed/Idle Session

    func testResumeCompletedSession() async throws {
        try await connectMock()

        // Configure mock for completed session with session/load support
        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockAttachState("idle")
        await transport.setMockLoadSteps([
            .userMessageChunk("What is 2+2?"),
            .textDelta("The answer is 4."),
            .promptComplete(.endTurn),
        ])

        let sessionId = "test-session-completed"
        // Create a local session record
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)

        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after resume")
        XCTAssertFalse(appState.isLoadingHistory, "isLoadingHistory should be false after resume")

        // All messages should have isStreaming = false
        for msg in appState.messages where msg.role == .assistant {
            XCTAssertFalse(msg.isStreaming, "No assistant messages should be streaming")
        }

        // Should have loaded assistant content from session/load history
        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        XCTAssertGreaterThanOrEqual(assistantMessages.count, 1, "Should have assistant message from history")
        let fullText = assistantMessages.map { $0.content }.joined()
        XCTAssertTrue(fullText.contains("answer is 4"), "Should have loaded history content, got: \(fullText)")

        // Should be able to send a new message
        appState.sendMessage("Follow up question")
        XCTAssertTrue(appState.isPrompting, "Should be able to send after resume")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testResumeLegacySessionUsesDaemonReportedCommand() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("legacy-claude"),
                "cwd": .string("/test/path"),
                "state": .string("idle"),
                "lastEventSeq": .int(7),
                "command": .string("claude-agent-acp"),
            ]
        ])
        await transport.setMockAttachState("idle")
        await transport.setMockLoadSteps([
            .userMessageChunk("hello"),
            .textDelta("from history"),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        let session = Session(sessionId: "legacy-claude", workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "legacy-claude", modelContext: modelContext)

        XCTAssertEqual(appState.activeSession?.agentID, AgentKind.claude.rawValue)
        XCTAssertEqual(appState.activeSession?.agentCommand, "claude-agent-acp")
    }

    // MARK: - Resume Tests: Draining Session

    func testResumeDrainingSession() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        // Configure for draining session
        await transport.setMockAttachState("draining")
        let bufferedEvents = buildBufferedEvents([
            .textDelta("I'm working on your request..."),
        ])
        await transport.setMockAttachBufferedEvents(bufferedEvents)

        try await appState.resumeSession(sessionId: "draining-session", modelContext: modelContext)

        // isPrompting should always be cleared after draining resume
        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after draining resume")

        // Should be able to send
        appState.sendMessage("Hello")
        XCTAssertTrue(appState.isPrompting)
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testResumeDrainingStillRunning() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        // Configure for draining session that's still running
        await transport.setMockAttachState("draining")
        let bufferedEvents = buildBufferedEvents([
            .textDelta("Working..."),
        ])
        await transport.setMockAttachBufferedEvents(bufferedEvents)

        try await appState.resumeSession(sessionId: "draining-running", modelContext: modelContext)

        // isPrompting should be false — user should not be locked out of draining sessions
        XCTAssertFalse(appState.isPrompting, "isPrompting should be false — user can send even for draining sessions")

        // User should be able to send a message
        appState.sendMessage("New message")
        XCTAssertTrue(appState.isPrompting, "Should be able to send to draining session")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testResumeDrainingPromptCompleteInBuffer() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        // Configure: draining but prompt_complete IS in the buffer
        await transport.setMockAttachState("draining")
        let bufferedEvents = buildBufferedEvents([
            .textDelta("Done working."),
            .promptComplete(.endTurn),
        ])
        await transport.setMockAttachBufferedEvents(bufferedEvents)

        try await appState.resumeSession(sessionId: "draining-complete-in-buffer", modelContext: modelContext)

        // prompt_complete in buffer should have cleared isPrompting
        XCTAssertFalse(
            appState.isPrompting,
            "isPrompting should be false — prompt_complete was in the buffer"
        )
    }

    // MARK: - Resume Tests: History Session (not in daemon)

    func testResumeHistorySession() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        // Configure: first attach fails (session not found), then subsequent attaches succeed
        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadSteps([
            .userMessageChunk("Old question"),
            .textDelta("Old answer."),
            .promptComplete(.endTurn),
        ])

        // Create a local session record
        let oldSessionId = "old-session-12345"
        let session = Session(sessionId: oldSessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: oldSessionId, modelContext: modelContext)

        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after history recovery")
        XCTAssertFalse(appState.isLoadingHistory)

        // Session ID should have changed to the new daemon session
        XCTAssertNotEqual(appState.currentSessionId, oldSessionId, "Should have a new session ID")
        XCTAssertTrue(
            appState.currentSessionId?.hasPrefix("mock-sess-") == true,
            "New session should be a mock session, got: \(appState.currentSessionId ?? "nil")"
        )

        // Local session should keep the original history source for future recovery.
        let recoveredSessionId = try XCTUnwrap(appState.currentSessionId)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == recoveredSessionId }
        )
        let recovered = try XCTUnwrap(modelContext.fetch(descriptor).first)
        XCTAssertEqual(recovered.historySessionId, oldSessionId)

        // Should have system message about recovery
        let recoveryMessages = appState.messages.filter {
            $0.role == .system && $0.content.contains("recovered")
        }
        XCTAssertFalse(recoveryMessages.isEmpty, "Should show recovery system message")

        // Should be able to send
        appState.sendMessage("New question")
        XCTAssertTrue(appState.isPrompting)
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testResumeHistorySessionReusesStoredAgentCommand() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadSteps([
            .userMessageChunk("Old question"),
            .textDelta("Old answer."),
            .promptComplete(.endTurn),
        ])

        let customCommand = "npx @zed-industries/codex-acp"
        let session = Session(
            sessionId: "history-session-with-agent",
            agentID: AgentKind.codex.rawValue,
            agentCommand: customCommand,
            workspace: workspace
        )
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "history-session-with-agent", modelContext: modelContext)

        let createdCommand = await transport.getLastCreateCommand()
        XCTAssertEqual(createdCommand, customCommand)
    }

    func testResumeLegacyHistorySessionFallsBackToClaudeCommand() async throws {
        let defaults = UserDefaults.standard
        let defaultKey = AgentCommandStore.defaultAgentKey
        let previousDefault = defaults.string(forKey: defaultKey)
        defaults.set(AgentKind.codex.rawValue, forKey: defaultKey)
        defer {
            if let previousDefault {
                defaults.set(previousDefault, forKey: defaultKey)
            } else {
                defaults.removeObject(forKey: defaultKey)
            }
        }

        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadSteps([
            .userMessageChunk("legacy"),
            .textDelta("history"),
            .promptComplete(.endTurn),
        ])

        let session = Session(sessionId: "legacy-no-agent-metadata", workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "legacy-no-agent-metadata", modelContext: modelContext)

        let createdCommand = await transport.getLastCreateCommand()
        XCTAssertEqual(createdCommand, AgentKind.claude.defaultCommand)
    }

    func testResumeRecoveredSessionUsesOriginalHistorySource() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let oldSessionId = "old-session-anchor"
        let session = Session(sessionId: oldSessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        // First recovery.
        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadSteps([
            .userMessageChunk("Old question"),
            .textDelta("Old answer."),
            .promptComplete(.endTurn),
        ])
        try await appState.resumeSession(sessionId: oldSessionId, modelContext: modelContext)
        let recoveredSessionId = try XCTUnwrap(appState.currentSessionId)

        // Second recovery should still load from the original anchor.
        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadSteps([
            .userMessageChunk("Old question"),
            .textDelta("Recovered from original history."),
            .promptComplete(.endTurn),
        ])
        try await appState.resumeSession(sessionId: recoveredSessionId, modelContext: modelContext)

        let lastLoadSessionId = await transport.getLastLoadSessionId()
        XCTAssertEqual(lastLoadSessionId, oldSessionId, "Should load from original history session")
    }

    func testResumeCompletedSessionFallsBackToHistorySource() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("idle")
        await transport.setMockLoadFailSessionIDs(["recovered-session"])
        await transport.setMockLoadSteps([
            .userMessageChunk("Original question"),
            .textDelta("Original history answer."),
            .promptComplete(.endTurn),
        ])

        let session = Session(
            sessionId: "recovered-session",
            historySessionId: "original-session",
            workspace: workspace
        )
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "recovered-session", modelContext: modelContext)

        let lastLoadSessionId = await transport.getLastLoadSessionId()
        let lastLoadRoute = await transport.getLastLoadRouteToSessionId()
        XCTAssertEqual(lastLoadSessionId, "original-session")
        XCTAssertEqual(lastLoadRoute, "recovered-session")

        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        let fullText = assistantMessages.map { $0.content }.joined()
        XCTAssertTrue(fullText.contains("Original history answer"))
    }

    func testResumeHistorySessionFallsBackToAlternateCwd() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let legacyWorkspace = Workspace(name: "legacy", path: "/legacy/path")
        legacyWorkspace.node = node
        modelContext.insert(legacyWorkspace)
        try modelContext.save()

        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadFailSessionCwdPairs([
            "legacy-history-id|/wrong/path",
            "legacy-history-id|/test/path",
        ])
        await transport.setMockLoadSteps([
            .userMessageChunk("Old question"),
            .textDelta("Loaded from legacy cwd."),
            .promptComplete(.endTurn),
        ])

        let session = Session(
            sessionId: "legacy-history-id",
            sessionCwd: "/wrong/path",
            workspace: workspace
        )
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "legacy-history-id", modelContext: modelContext)

        let lastLoadCwd = await transport.getLastLoadCwd()
        XCTAssertEqual(lastLoadCwd, "/legacy/path")
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content == "Session recovered from history"
            },
            "Should recover from history via alternate cwd"
        )
    }

    func testRefreshDaemonSessionsUpdatesSnapshot() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("daemon-s-1"),
                "cwd": .string("/test/path"),
                "state": .string("prompting"),
                "lastEventSeq": .int(42),
            ]
        ])

        await appState.refreshDaemonSessions()

        XCTAssertEqual(appState.daemonSessions.count, 1)
        XCTAssertEqual(appState.daemonSessions.first?.sessionId, "daemon-s-1")
        XCTAssertEqual(appState.daemonSessions.first?.state, "prompting")
        XCTAssertEqual(appState.daemonSessions.first?.lastEventSeq, 42)
    }

    // MARK: - UnifiedSession Tests

    func testUnifiedSessionMerge() {
        let u1 = UnifiedSession(
            sessionId: "s1",
            daemonState: "idle",
            cwd: "/test/path",
            lastEventSeq: 10,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(u1.displayState, "idle")
        XCTAssertTrue(u1.isResumable)
        XCTAssertEqual(u1.displayTitle, "s1") // shorter than 8, shown as-is

        let u2 = UnifiedSession(
            sessionId: "s2",
            daemonState: nil,
            cwd: nil,
            lastEventSeq: nil,
            title: "My Session",
            daemonTitle: nil,
            lastUsedAt: Date(),
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(u2.displayState, "history")
        XCTAssertTrue(u2.isResumable)
        XCTAssertEqual(u2.displayTitle, "My Session")

        let u3 = UnifiedSession(
            sessionId: "s3",
            daemonState: "prompting",
            cwd: "/test/path",
            lastEventSeq: 50,
            title: "Running Session",
            daemonTitle: nil,
            lastUsedAt: Date(),
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(u3.displayState, "prompting")
        XCTAssertTrue(u3.isResumable)
        XCTAssertEqual(u3.displayTitle, "Running Session")
    }

    func testUnifiedSessionDeadIsResumableForRecovery() {
        let unified = UnifiedSession(
            sessionId: "dead-sess",
            daemonState: "dead",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertTrue(unified.isResumable)
        XCTAssertEqual(unified.displayState, "dead")
    }

    func testUnifiedSessionUnknownAgentIDFallsBackToRawValue() {
        let unified = UnifiedSession(
            sessionId: "s-unknown-agent",
            daemonState: "idle",
            cwd: "/test",
            lastEventSeq: 1,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: "custom-agent",
            agentCommand: nil
        )
        XCTAssertEqual(unified.agentDisplayName, "custom-agent")
    }

    func testUnifiedSessionEmptyPlaceholderDetection() {
        let empty = UnifiedSession(
            sessionId: "s-empty",
            daemonState: "idle",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertTrue(empty.isEmptyPlaceholder)

        let withEvents = UnifiedSession(
            sessionId: "s-with-events",
            daemonState: "idle",
            cwd: "/test",
            lastEventSeq: 1,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertFalse(withEvents.isEmptyPlaceholder)
    }

    // MARK: - Session List Lifecycle Tests

    func testRefreshDaemonSessionsDeduplicatesConcurrentCalls() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("s-1"),
                "cwd": .string("/test/path"),
                "state": .string("idle"),
                "lastEventSeq": .int(5),
            ]
        ])

        // Fire two concurrent refreshes — only one should actually call daemon
        async let r1: () = appState.refreshDaemonSessions()
        async let r2: () = appState.refreshDaemonSessions()
        _ = await (r1, r2)

        // Count how many sessionList calls were made
        let methods = await transport.getReceivedMethods()
        let listCalls = methods.filter { $0 == DaemonMethods.sessionList }
        XCTAssertEqual(listCalls.count, 1, "Concurrent refreshes should be coalesced into one call")
    }

    func testSendMessageDoesNotRefreshDaemonSessionsFromPromptResponse() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        // After createNewSession: 1 sessionList call from its internal refresh.
        // The notification-driven prompt_complete handler may also refresh (from
        // handleSessionEvent). Verify the prompt *response* path no longer triggers
        // a redundant refresh on top of the notification-driven one.
        let methodsBefore = await transport.getReceivedMethods()
        let listCallsBefore = methodsBefore.filter { $0 == DaemonMethods.sessionList }.count

        appState.sendMessage("Hello")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        // Allow the async Task from promptComplete notification handler to settle
        try await Task.sleep(for: .milliseconds(100))

        let methodsAfter = await transport.getReceivedMethods()
        let listCallsAfter = methodsAfter.filter { $0 == DaemonMethods.sessionList }.count

        // At most 1 new call: from the notification-driven promptComplete handler.
        // Previously there were 2 (notification + response path); now only 1.
        let newCalls = listCallsAfter - listCallsBefore
        XCTAssertLessThanOrEqual(
            newCalls, 1,
            "sendMessage should trigger at most 1 session refresh (from notification), got \(newCalls)"
        )
    }

    func testDiscardEmptySessionRefreshesDaemonSessions() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let methodsBefore = await transport.getReceivedMethods()
        let listCallsBefore = methodsBefore.filter { $0 == DaemonMethods.sessionList }.count

        await appState.discardEmptyActiveSessionIfNeeded(modelContext: modelContext)

        let methodsAfter = await transport.getReceivedMethods()
        let listCallsAfter = methodsAfter.filter { $0 == DaemonMethods.sessionList }.count

        XCTAssertEqual(
            listCallsAfter, listCallsBefore + 1,
            "discardEmptyActiveSession should refresh daemon sessions to update the list"
        )
    }

    func testCleanupConnectionClearsDaemonSessions() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("s-1"),
                "cwd": .string("/test/path"),
                "state": .string("idle"),
                "lastEventSeq": .int(5),
            ]
        ])
        await appState.refreshDaemonSessions()
        XCTAssertFalse(appState.daemonSessions.isEmpty, "Sessions should be populated before disconnect")

        appState.disconnect()
        XCTAssertTrue(appState.daemonSessions.isEmpty, "disconnect should clear daemon sessions")
    }

    func testRefreshAfterDisconnectIsNoOp() async throws {
        try await connectMock()
        appState.disconnect()

        // Refresh after disconnect should not crash or populate sessions
        await appState.refreshDaemonSessions()
        XCTAssertTrue(appState.daemonSessions.isEmpty, "refresh after disconnect should be a no-op")
    }

    // MARK: - Helpers

    /// Build buffered event dicts from MockSteps for configuring mock attach responses.
    private func buildBufferedEvents(_ steps: [MockStep]) -> [[String: JSONValue]] {
        var events: [[String: JSONValue]] = []
        var seq = 1
        for step in steps {
            let update: JSONValue
            switch step {
            case .textDelta(let text):
                update = .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            case .promptComplete(let reason):
                update = .object([
                    "sessionUpdate": .string("prompt_complete"),
                    "stopReason": .string(reason.rawValue)
                ])
            default:
                continue
            }

            let event: [String: JSONValue] = [
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string("test"),
                    "update": update
                ])
            ]
            events.append([
                "seq": .int(seq),
                "event": .object(event)
            ])
            seq += 1
        }
        return events
    }
}
