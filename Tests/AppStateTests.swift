import XCTest
import SwiftData
@testable import OpenCAN

/// Unit tests for AppState session management using MockACPTransport.
/// These test the core flows: create session, send message, open conversation
/// (draining, completed, missing), and verify isPrompting state transitions.
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

    func testWorkspaceDirectoryExistsThrowsWhenDisconnected() async {
        do {
            let _ = try await appState.workspaceDirectoryExists(path: "/tmp/workspace")
            XCTFail("Expected workspaceDirectoryExists to throw when disconnected")
        } catch let error as AppStateError {
            guard case .notConnected = error else {
                XCTFail("Expected notConnected error, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected AppStateError.notConnected, got \(error)")
        }
    }

    func testWorkspaceDirectoryChecksAreNoOpInMockMode() async throws {
        try await connectMock()

        let exists = try await appState.workspaceDirectoryExists(path: "/tmp/workspace")
        XCTAssertTrue(exists)

        do {
            try await appState.createWorkspaceDirectory(path: "/tmp/workspace")
        } catch {
            XCTFail("createWorkspaceDirectory should not throw in mock mode: \(error)")
        }
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

    func testSendMessageWithoutPromptResponseTimesOutAndAllowsRetry() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.configurePromptTimeoutsForTesting(responseTimeoutSeconds: 0.2)
        await transport.setMockPromptShouldHang(true)

        let firstAccepted = appState.sendMessage("First message will hang")
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(appState.isPrompting)

        try await waitFor(timeout: 2) { !self.appState.isPrompting }

        XCTAssertFalse(
            appState.messages.contains { $0.role == .assistant && $0.isStreaming },
            "Streaming should stop after prompt timeout"
        )
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Timeout guidance should be shown in system message"
        )

        await transport.setMockPromptShouldHang(false)
        let secondAccepted = appState.sendMessage("Second message should succeed")
        XCTAssertTrue(secondAccepted, "Prompt timeout should not permanently block sending")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }

        let userMessages = appState.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 2, "Second message should be deliverable after timeout recovery")
    }

    func testDroppedPromptResponseAfterPromptCompleteDoesNotShowTimeoutError() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.configurePromptTimeoutsForTesting(responseTimeoutSeconds: 1.0)
        await transport.setMockDropPromptResponse(true)

        appState.sendMessage("Response will be dropped after prompt_complete")
        try await waitFor(timeout: 2) { !self.appState.isPrompting }

        // Let request timeout fire in background; prompt_complete already ended turn.
        try await Task.sleep(for: .milliseconds(1400))

        XCTAssertFalse(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Prompt timeout should be ignored after prompt_complete"
        )
    }

    func testStreamingUpdatesKeepPromptAlivePastBaseTimeout() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        guard let sessionId = appState.currentSessionId else {
            XCTFail("Missing current session id")
            return
        }

        appState.configurePromptTimeoutsForTesting(responseTimeoutSeconds: 0.2)
        await transport.setMockPromptShouldHang(true)

        let accepted = appState.sendMessage("keep prompt alive with updates")
        XCTAssertTrue(accepted)
        XCTAssertTrue(appState.isPrompting)

        let keepAliveTask = Task.detached {
            // Keep updates flowing past at least one 1s poll interval so the
            // inactivity timeout cannot fire while activity is ongoing.
            for tick in 0..<20 {
                await transport.emitSessionTextDeltaForTest(
                    sessionId: sessionId,
                    text: "heartbeat \(tick)"
                )
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        // Prompt should still be active while updates keep arriving.
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertTrue(appState.isPrompting)
        XCTAssertFalse(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Timeout should not trigger while streaming updates are still flowing"
        )

        _ = await keepAliveTask.result
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Timeout should trigger after streaming updates stop and prompt remains unfinished"
        )
    }

    func testDaemonPromptingStateDefersInactivityTimeout() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        guard let sessionId = appState.currentSessionId else {
            XCTFail("Missing current session id")
            return
        }

        appState.configurePromptTimeoutsForTesting(
            responseTimeoutSeconds: 0.2,
            maxWaitSeconds: 2.0
        )
        await transport.setMockPromptShouldHang(true)
        await transport.setMockSessionList([
            [
                "sessionId": .string(sessionId),
                "cwd": .string("/test/path"),
                "state": .string("prompting"),
                "lastEventSeq": .int(1),
            ]
        ])

        let accepted = appState.sendMessage("long running prompt without intermediate updates")
        XCTAssertTrue(accepted)

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(appState.isPrompting, "Prompt should stay active while daemon reports prompting")
        XCTAssertFalse(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Timeout guidance should not appear while daemon still reports prompting"
        )

        await transport.setMockSessionList([
            [
                "sessionId": .string(sessionId),
                "cwd": .string("/test/path"),
                "state": .string("idle"),
                "lastEventSeq": .int(1),
            ]
        ])

        try await waitFor(timeout: 2) { !self.appState.isPrompting }
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("No terminal response")
            },
            "Timeout should eventually surface once daemon no longer reports a busy prompt state"
        )
    }

    func testPromptResponseFromPreviousSessionDoesNotSettleCurrentPrompt() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        let originalSessionId = try XCTUnwrap(appState.currentSessionId)
        appState.sendMessage("message on old session")
        XCTAssertTrue(appState.isPrompting)

        // Simulate user switching to another session before the old prompt returns.
        appState.currentSessionId = "new-active-session"
        appState.isPrompting = true

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(
            appState.isPrompting,
            "Prompt completion from \(originalSessionId) should not settle the new active session"
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

    func testSendMessageReturnsFalseWhenPrompting() async throws {
        try await connectMock(scenario: .complex)
        try await appState.createNewSession(modelContext: modelContext)

        let firstAccepted = appState.sendMessage("First")
        XCTAssertTrue(firstAccepted, "First send should be accepted")
        XCTAssertTrue(appState.isPrompting)

        let secondAccepted = appState.sendMessage("Second")
        XCTAssertFalse(secondAccepted, "Second send should be rejected while prompting")
    }

    func testSendMessageReturnsFalseWhenDisconnected() async {
        let accepted = appState.sendMessage("Hello")
        XCTAssertFalse(accepted, "Send should fail when no session/transport is active")
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

    func testOpenDifferentSessionDetachesPreviousAttachment() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let initialSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockAttachState("idle")

        try await appState.openSession(sessionId: "other-session", modelContext: modelContext)

        let detachedSessionIds = await transport.getDetachedSessionIds()
        XCTAssertEqual(detachedSessionIds.last, initialSessionId, "Should detach previous session before switching")

        let receivedMethods = await transport.getReceivedMethods()
        let detachIndex = try XCTUnwrap(receivedMethods.lastIndex(of: DaemonMethods.conversationDetach))
        let attachIndex = try XCTUnwrap(receivedMethods.lastIndex(of: DaemonMethods.conversationOpen))
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

    func testAcceptsNotificationForActiveRuntimeWhenLegacySessionIdDiffers() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let currentSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.emitSessionTextDeltaForTest(
            sessionId: "legacy-history-id",
            runtimeId: currentSessionId,
            conversationId: "legacy-history-id",
            text: "accept-via-runtime-metadata"
        )
        try await waitFor(timeout: 2) {
            self.appState.messages.contains { $0.content.contains("accept-via-runtime-metadata") }
        }
    }

    func testIgnoresNotificationWhenRuntimeIdMismatchesActiveRuntime() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let currentSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.emitSessionTextDeltaForTest(
            sessionId: currentSessionId,
            runtimeId: "foreign-runtime",
            conversationId: currentSessionId,
            text: "ignore-via-runtime-metadata"
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            appState.messages.contains { $0.content.contains("ignore-via-runtime-metadata") },
            "Runtime metadata should win over legacy sessionId when filtering notifications"
        )
    }

    func testForeignNotificationDoesNotPolluteLastEventSeqCursor() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let currentSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.emitSessionTextDeltaForTest(
            sessionId: "foreign-session",
            text: "ignore-with-seq",
            seq: 777
        )
        try await Task.sleep(for: .milliseconds(50))

        appState.messages = []
        appState.activeSession = nil
        appState.currentSessionId = nil
        try await appState.openSession(sessionId: currentSessionId, modelContext: modelContext)

        let attachedSessionID = await transport.getLastAttachSessionId()
        let attachedSeq = await transport.getLastAttachLastEventSeq()
        XCTAssertEqual(attachedSessionID, currentSessionId)
        XCTAssertEqual(
            attachedSeq, 0,
            "Foreign seq should not advance attach replay cursor for the active session"
        )
    }

    func testHistoryLoadingWithoutTrackedSessionStillIgnoresForeignNotifications() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.isLoadingHistory = true
        await transport.emitSessionTextDeltaForTest(
            sessionId: "foreign-session",
            text: "history-foreign"
        )
        try await Task.sleep(for: .milliseconds(50))
        appState.isLoadingHistory = false

        XCTAssertFalse(
            appState.messages.contains { $0.content.contains("history-foreign") },
            "History-loading fallback should not accept foreign-session notifications"
        )
    }

    // MARK: - Open Tests: Completed/Idle Conversation

    func testOpenCompletedSession() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockAttachState("idle")
        await transport.setMockAttachBufferedEvents(
            buildBufferedEvents([
                .userMessageChunk("What is 2+2?"),
                .textDelta("The answer is 4."),
                .promptComplete(.endTurn),
            ])
        )

        let sessionId = "test-session-completed"
        // Create a local session record
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.openSession(sessionId: sessionId, modelContext: modelContext)

        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after open")
        XCTAssertFalse(appState.isLoadingHistory, "isLoadingHistory should be false after open")

        // All messages should have isStreaming = false
        for msg in appState.messages where msg.role == .assistant {
            XCTAssertFalse(msg.isStreaming, "No assistant messages should be streaming")
        }

        // Should have replayed assistant content from daemon buffered history
        let assistantMessages = appState.messages.filter { $0.role == .assistant }
        XCTAssertGreaterThanOrEqual(assistantMessages.count, 1, "Should have assistant message from history")
        let fullText = assistantMessages.map { $0.content }.joined()
        XCTAssertTrue(fullText.contains("answer is 4"), "Should have loaded history content, got: \(fullText)")

        // Should be able to send a new message
        appState.sendMessage("Follow up question")
        XCTAssertTrue(appState.isPrompting, "Should be able to send after open")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testSuspendChatListAnimationsDuringHistoryLoad() async throws {
        XCTAssertFalse(appState.suspendChatListAnimations)
        appState.isLoadingHistory = true
        XCTAssertTrue(
            appState.suspendChatListAnimations,
            "Animations should be suspended while isLoadingHistory is true"
        )
        appState.isLoadingHistory = false
        XCTAssertFalse(appState.suspendChatListAnimations)
    }

    func testOpenLegacyConversationUsesDaemonReportedCommand() async throws {
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

        try await appState.openSession(sessionId: "legacy-claude", modelContext: modelContext)

        XCTAssertEqual(appState.activeSession?.agentID, AgentKind.claude.rawValue)
        XCTAssertEqual(appState.activeSession?.agentCommand, "claude-agent-acp")
    }

    // MARK: - Open Tests: Draining Conversation

    func testOpenDrainingConversation() async throws {
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

        try await appState.openSession(sessionId: "draining-session", modelContext: modelContext)

        // isPrompting should always be cleared after draining open
        XCTAssertFalse(appState.isPrompting, "isPrompting should be false after draining open")

        // Should be able to send
        appState.sendMessage("Hello")
        XCTAssertTrue(appState.isPrompting)
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testOpenDrainingConversationStillRunning() async throws {
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

        try await appState.openSession(sessionId: "draining-running", modelContext: modelContext)

        // isPrompting should be false — user should not be locked out of draining sessions
        XCTAssertFalse(appState.isPrompting, "isPrompting should be false — user can send even for draining sessions")

        // User should be able to send a message
        appState.sendMessage("New message")
        XCTAssertTrue(appState.isPrompting, "Should be able to send to draining session")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
    }

    func testOpenDrainingConversationPromptCompleteInBuffer() async throws {
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

        try await appState.openSession(sessionId: "draining-complete-in-buffer", modelContext: modelContext)

        // prompt_complete in buffer should have cleared isPrompting
        XCTAssertFalse(
            appState.isPrompting,
            "isPrompting should be false — prompt_complete was in the buffer"
        )
    }

    func testOpenRunningConversationWithoutReplayDoesNotIssueLegacyLoad() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("prompting")
        await transport.setMockAttachBufferedEvents([])

        try await appState.openSession(sessionId: "running-load", modelContext: modelContext)

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(methods.contains(ACPMethods.sessionLoad), "Running conversation open should not issue legacy session/load")
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("Conversation reopened (still running)")
            },
            "Running open should rely on daemon-owned reopen state"
        )
    }

    func testOpenRunningConversationSkipsBlockingLoadWhenReplayIsAvailable() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("prompting")
        await transport.setMockAttachBufferedEvents(
            buildBufferedEvents([
                .textDelta("Buffered fallback after load timeout."),
                .promptComplete(.endTurn)
            ])
        )
        await transport.setMockLoadShouldHang(true)

        let sessionId = "running-load-hang"
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        let startedAt = Date()
        try await appState.openSession(sessionId: sessionId, modelContext: modelContext)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            2.0,
            "Running open should not block on session/load when replay already has visible history"
        )
        XCTAssertFalse(appState.isLoadingHistory)
        XCTAssertFalse(appState.isPrompting)
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Buffered fallback after load timeout.") },
            "Should replay buffered history when session/load times out"
        )
        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(
            methods.contains(ACPMethods.sessionLoad),
            "Running open with visible buffered replay should not issue blocking session/load"
        )
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("Conversation reopened (still running)")
            },
            "Should surface a non-blocking running open status"
        )
    }

    func testOpenRunningConversationWithoutReplayDoesNotBlockForever() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("prompting")
        await transport.setMockAttachBufferedEvents([])
        await transport.setMockLoadShouldHang(true)

        let sessionId = "running-load-timeout"
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        let startedAt = Date()
        try await appState.openSession(sessionId: sessionId, modelContext: modelContext)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            2.0,
            "Running open should stay responsive without app-side history loading"
        )
        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(
            methods.contains(ACPMethods.sessionLoad),
            "Should not attempt legacy session/load backfill when replay is empty"
        )
        XCTAssertFalse(appState.isLoadingHistory)
        XCTAssertFalse(appState.isPrompting)
    }

    func testOpenSameActiveConversationReusesInMemoryTranscript() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        let sessionId = try XCTUnwrap(appState.currentSessionId)

        appState.sendMessage("keep in memory")
        try await waitFor(timeout: 5) { !self.appState.isPrompting }
        let messagesBefore = appState.messages.map(\.content)
        XCTAssertFalse(messagesBefore.isEmpty)

        let methodsBefore = await transport.getReceivedMethods()
        try await appState.openSession(sessionId: sessionId, modelContext: modelContext)
        let methodsAfter = await transport.getReceivedMethods()

        XCTAssertEqual(appState.currentSessionId, sessionId)
        XCTAssertEqual(appState.messages.map(\.content), messagesBefore)
        XCTAssertEqual(
            methodsAfter.count,
            methodsBefore.count,
            "Re-entering the same active session should not reattach/reload"
        )
    }

    // MARK: - Open Tests: Non-Recoverable Conversations

    func testOpenAttachFailureRestoresPreviousAttachment() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let previousSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setNextAttachError(
            code: -32603,
            message: "Internal error while attaching",
            data: nil
        )

        let busySession = Session(sessionId: "busy-session", workspace: workspace)
        modelContext.insert(busySession)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: "busy-session", modelContext: modelContext)
            XCTFail("Expected openSession to fail")
        } catch {
            // expected
        }

        XCTAssertEqual(
            appState.currentSessionId,
            previousSessionId,
            "Failed open should restore previous attached session"
        )
        let lastAttachSessionId = await transport.getLastAttachSessionId()
        XCTAssertEqual(lastAttachSessionId, previousSessionId)
    }

    func testOpenAttachFailureAndRestoreFailureClearsCurrentSessionId() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let previousSessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachError(
            code: -32603,
            message: "Internal error while attaching",
            data: nil
        )

        let busySession = Session(sessionId: "busy-session-restore-fails", workspace: workspace)
        modelContext.insert(busySession)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: "busy-session-restore-fails", modelContext: modelContext)
            XCTFail("Expected openSession to fail")
        } catch {
            // expected
        }

        XCTAssertNil(
            appState.currentSessionId,
            "When target+restore attach both fail, currentSessionId must be cleared to avoid stale detached pointer"
        )

        let methods = await transport.getReceivedMethods()
        let openCalls = methods.filter { $0 == DaemonMethods.conversationOpen }.count
        XCTAssertEqual(openCalls, 2, "Should attempt target open and rollback open")
    }

    func testOpenSessionAlreadyAttachedByAnotherClientDoesNotRecover() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachError(
            code: -32000,
            message: "session already attached by another client: busy-session",
            data: nil
        )

        let session = Session(sessionId: "busy-session", workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: "busy-session", modelContext: modelContext)
            XCTFail("Expected openSession to fail for ownership conflict")
        } catch let error as AppStateError {
            guard case .sessionAttachedByAnotherClient(let sessionId) = error else {
                XCTFail("Expected sessionAttachedByAnotherClient, got \(error)")
                return
            }
            XCTAssertEqual(sessionId, "busy-session")
        } catch {
            XCTFail("Expected AppStateError.sessionAttachedByAnotherClient, got \(error)")
        }

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(methods.contains(DaemonMethods.conversationCreate), "Should not create recovery conversation on ownership conflict")
    }

    func testOpenMissingSessionMarksDeadDirectly() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachShouldFail(true)

        let missingSessionID = "missing-session-123"
        let session = Session(sessionId: missingSessionID, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: missingSessionID, modelContext: modelContext)
            XCTFail("Expected openSession to fail")
        } catch let error as AppStateError {
            guard case .sessionNotRecoverable(let sessionId) = error else {
                XCTFail("Expected sessionNotRecoverable, got \(error)")
                return
            }
            XCTAssertEqual(sessionId, missingSessionID)
        }

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(methods.contains(DaemonMethods.conversationCreate), "Missing managed session should not trigger new conversation creation")
        XCTAssertFalse(methods.contains(ACPMethods.sessionLoad), "Missing managed session should not attempt history load")
        XCTAssertEqual(
            appState.daemonConversations.first { $0.conversationId == missingSessionID }?.state,
            "unavailable"
        )
    }

    func testOpenMissingSessionClearsStaleCurrentSessionIdAfterDetach() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let previousSessionId = try XCTUnwrap(appState.currentSessionId)
        await transport.setMockAttachShouldFail(true)

        let missingSessionID = "missing-session-after-detach"
        let session = Session(sessionId: missingSessionID, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: missingSessionID, modelContext: modelContext)
            XCTFail("Expected openSession to fail for missing managed session")
        } catch let error as AppStateError {
            guard case .sessionNotRecoverable(let sessionId) = error else {
                XCTFail("Expected sessionNotRecoverable, got \(error)")
                return
            }
            XCTAssertEqual(sessionId, missingSessionID)
        }

        XCTAssertEqual(
            appState.currentSessionId,
            previousSessionId,
            "Missing target should roll back to the previous attached runtime when reclaim succeeds"
        )

        let detachedSessionIds = await transport.getDetachedSessionIds()
        XCTAssertTrue(detachedSessionIds.contains(previousSessionId))
    }

    func testOpenCompletedSessionWithoutReplayStillReopensConversation() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("idle")
        await transport.setMockAttachBufferedEvents([])

        let session = Session(sessionId: "empty-session", workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.openSession(sessionId: "empty-session", modelContext: modelContext)

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(methods.contains(ACPMethods.sessionLoad))
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content == "Conversation reopened"
            }
        )
    }

    func testOpenSessionUsesDaemonReportedConversationCwd() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("idle")
        await transport.setMockConversationList([
            [
                "conversationId": .string("legacy-history-id"),
                "runtimeId": .string("managed-runtime-legacy"),
                "state": .string("ready"),
                "cwd": .string("/legacy/path"),
                "lastEventSeq": .int(2),
                "origin": .string("managed")
            ]
        ])
        await transport.setMockAttachBufferedEvents(
            buildBufferedEvents([
                .userMessageChunk("Question"),
                .textDelta("Loaded from daemon-owned cwd."),
                .promptComplete(.endTurn),
            ])
        )

        let session = Session(
            sessionId: "legacy-history-id",
            sessionCwd: "/wrong/path",
            workspace: workspace
        )
        modelContext.insert(session)
        try modelContext.save()

        try await appState.openSession(sessionId: "legacy-history-id", modelContext: modelContext)

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(methods.contains(ACPMethods.sessionLoad))
        XCTAssertEqual(appState.activeSession?.sessionCwd, "/legacy/path")
        XCTAssertEqual(appState.currentSessionId, "managed-runtime-legacy")
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("daemon-owned cwd") },
            "Should apply daemon replay content without app-side cwd probing"
        )
    }

    func testOpenSessionUsesConversationOpenForRestorableConversation() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockConversationList([
            [
                "conversationId": .string("external-session-1"),
                "state": .string("restorable"),
                "cwd": .string("/test/path"),
                "origin": .string("discovered"),
                "lastEventSeq": .int(3),
            ]
        ])
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Continued on mobile."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        try await appState.openSession(sessionId: "external-session-1", modelContext: modelContext)

        let openedRuntimeId = try XCTUnwrap(appState.currentSessionId)
        XCTAssertNotEqual(openedRuntimeId, "external-session-1")
        XCTAssertTrue(openedRuntimeId.hasPrefix("mock-sess-"))
        XCTAssertEqual(appState.activeSession?.conversationId, "external-session-1")

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.conversationOpen))
        XCTAssertFalse(methods.contains(DaemonMethods.conversationCreate))
        XCTAssertFalse(methods.contains(ACPMethods.sessionLoad))
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Continued on mobile.") }
        )
    }

    func testOpenSessionUpdatesExistingLocalRecordToNewRuntime() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let conversationId = "external-session-mapped"
        let managedSessionId = "managed-session-local"

        await transport.setMockConversationList([
            [
                "conversationId": .string(conversationId),
                "state": .string("restorable"),
                "cwd": .string("/test/path"),
                "origin": .string("discovered"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Rebound onto a new runtime."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        let mapped = Session(
            sessionId: managedSessionId,
            conversationId: conversationId,
            canonicalSessionId: conversationId,
            sessionCwd: "/test/path",
            workspace: workspace
        )
        modelContext.insert(mapped)
        try modelContext.save()

        try await appState.openSession(sessionId: conversationId, modelContext: modelContext)

        let openedRuntimeId = try XCTUnwrap(appState.currentSessionId)
        XCTAssertNotEqual(openedRuntimeId, managedSessionId)
        XCTAssertTrue(openedRuntimeId.hasPrefix("mock-sess-"))

        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let updated = try XCTUnwrap(sessions.first { $0.stableConversationId == conversationId })
        XCTAssertEqual(updated.conversationId, conversationId)
        XCTAssertEqual(updated.sessionId, openedRuntimeId)

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.conversationOpen))
        XCTAssertFalse(methods.contains(DaemonMethods.conversationCreate))
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("new runtime") }
        )
    }

    func testOpenSessionManagedConversationReusesExistingRuntime() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockConversationList([
            [
                "conversationId": .string("managed-conversation"),
                "runtimeId": .string("managed-runtime-1"),
                "state": .string("attached"),
                "cwd": .string("/test/path"),
                "origin": .string("managed"),
                "lastEventSeq": .int(4),
            ]
        ])
        await transport.setMockAttachBufferedEvents(
            buildBufferedEvents([
                .textDelta("Buffered managed reply."),
                .promptComplete(.endTurn),
            ])
        )
        await appState.refreshDaemonSessions()

        try await appState.openSession(sessionId: "managed-conversation", modelContext: modelContext)

        XCTAssertEqual(appState.currentSessionId, "managed-runtime-1")
        let methods = await transport.getReceivedMethods()
        let openCalls = methods.filter { $0 == DaemonMethods.conversationOpen }.count
        XCTAssertEqual(openCalls, 1)
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Buffered managed reply.") }
        )
    }

    func testOpenSessionLoadFailureMarksConversationUnavailable() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockConversationList([
            [
                "conversationId": .string("external-session-fail"),
                "state": .string("restorable"),
                "cwd": .string("/test/path"),
                "origin": .string("discovered"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setMockLoadFailSessionIDs(["external-session-fail"])
        await appState.refreshDaemonSessions()

        let local = Session(
            sessionId: "external-session-fail",
            conversationId: "external-session-fail",
            workspace: workspace
        )
        modelContext.insert(local)
        try modelContext.save()

        do {
            try await appState.openSession(sessionId: "external-session-fail", modelContext: modelContext)
            XCTFail("Expected openSession to fail when daemon restore fails")
        } catch let error as AppStateError {
            guard case .sessionNotRecoverable(let sessionId) = error else {
                XCTFail("Expected sessionNotRecoverable, got \(error)")
                return
            }
            XCTAssertEqual(sessionId, "external-session-fail")
        }

        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        XCTAssertTrue(sessions.contains { $0.sessionId == "external-session-fail" })
        XCTAssertFalse(sessions.contains { $0.sessionId.hasPrefix("mock-sess-") })
        XCTAssertTrue(
            appState.daemonConversations.contains {
                $0.conversationId == "external-session-fail" && $0.state == "unavailable"
            }
        )
    }

    func testOpenSessionConversationOpenFailureDoesNotMutateLocalRecord() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockConversationList([
            [
                "conversationId": .string("external-attach-fail"),
                "state": .string("restorable"),
                "cwd": .string("/test/path"),
                "origin": .string("discovered"),
                "lastEventSeq": .int(0),
            ]
        ])
        await appState.refreshDaemonSessions()

        let local = Session(
            sessionId: "legacy-runtime",
            conversationId: "external-attach-fail",
            workspace: workspace
        )
        modelContext.insert(local)
        try modelContext.save()

        await transport.setNextAttachError(
            code: -32000,
            message: "attach failed",
            data: nil
        )

        do {
            try await appState.openSession(sessionId: "external-attach-fail", modelContext: modelContext)
            XCTFail("Expected openSession to fail when conversation.open attach fails")
        } catch {
            // expected
        }

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.conversationOpen))
        XCTAssertFalse(methods.contains(DaemonMethods.conversationCreate))

        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        let persisted = try XCTUnwrap(sessions.first { $0.stableConversationId == "external-attach-fail" })
        XCTAssertEqual(persisted.sessionId, "legacy-runtime")
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
                "updatedAt": .string("2026-02-25T10:30:00Z"),
            ]
        ])

        await appState.refreshDaemonSessions()

        XCTAssertEqual(appState.daemonSessions.count, 1)
        XCTAssertEqual(appState.daemonSessions.first?.sessionId, "daemon-s-1")
        XCTAssertEqual(appState.daemonSessions.first?.state, "prompting")
        XCTAssertEqual(appState.daemonSessions.first?.lastEventSeq, 42)
        XCTAssertNotNil(appState.daemonSessions.first?.updatedAt)
    }

    // MARK: - UnifiedSession Tests

    func testUnifiedSessionMerge() {
        let u1 = UnifiedSession(
            sessionId: "s1",
            daemonState: "ready",
            cwd: "/test/path",
            lastEventSeq: 10,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(u1.displayState, "ready")
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
        XCTAssertEqual(u2.displayState, "unavailable")
        XCTAssertTrue(u2.isResumable)
        XCTAssertEqual(u2.displayTitle, "My Session")

        let u3 = UnifiedSession(
            sessionId: "s3",
            daemonState: "running",
            cwd: "/test/path",
            lastEventSeq: 50,
            title: "Running Session",
            daemonTitle: nil,
            lastUsedAt: Date(),
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(u3.displayState, "running")
        XCTAssertTrue(u3.isResumable)
        XCTAssertEqual(u3.displayTitle, "Running Session")
    }

    func testUnifiedSessionDisplayTitleUsesFullSessionIDWhenNoTitle() {
        let sessionID = "019cabed-6f1d-75f1-8a47-44aed3b42e10"
        let unified = UnifiedSession(
            sessionId: sessionID,
            daemonState: "ready",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )

        XCTAssertEqual(unified.displayTitle, sessionID)
    }

    func testUnifiedSessionDeadIsStillActionable() {
        let unified = UnifiedSession(
            sessionId: "dead-sess",
            daemonState: "unavailable",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: nil,
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertTrue(unified.isResumable)
        XCTAssertEqual(unified.displayState, "unavailable")
    }

    func testUnifiedSessionExternalIsResumable() {
        let unified = UnifiedSession(
            sessionId: "external-sess",
            daemonState: "restorable",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: "External Session",
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertTrue(unified.isResumable)
        XCTAssertEqual(unified.displayState, "restorable")
    }

    func testUnifiedSessionUsesDaemonUpdatedAtWhenNoLocalTimestamp() {
        let daemonDate = Date(timeIntervalSince1970: 1_700_000_000)
        let unified = UnifiedSession(
            sessionId: "external-no-local-date",
            daemonState: "restorable",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: "External Session",
            lastUsedAt: nil,
            daemonUpdatedAt: daemonDate,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertEqual(unified.effectiveLastUsedAt, daemonDate)
    }

    func testUnifiedSessionUnknownAgentIDFallsBackToRawValue() {
        let unified = UnifiedSession(
            sessionId: "s-unknown-agent",
            daemonState: "ready",
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
            daemonState: "ready",
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
            daemonState: "ready",
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

    func testUnexpectedTransportClosePreservesActiveSessionContext() async throws {
        try await connectMock(scenario: .complex)
        try await appState.createNewSession(modelContext: modelContext)

        appState.sendMessage("still-streaming")
        let sessionId = try XCTUnwrap(appState.currentSessionId)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.close()

        try await waitFor(timeout: 5) { self.appState.connectionStatus == .disconnected }

        XCTAssertEqual(appState.currentSessionId, sessionId)
        XCTAssertNotNil(appState.activeSession, "Active session should be kept for reconnect recovery")
        XCTAssertFalse(appState.isPrompting, "Prompting state should clear after interruption")
        XCTAssertFalse(
            appState.messages.contains(where: \.isStreaming),
            "Streaming message flags should be cleared after interruption"
        )
        XCTAssertTrue(appState.daemonSessions.isEmpty, "Daemon sessions should reset after interruption")
    }

    func testMarkTransportInterruptedBackfillsWorkspaceFromActiveSession() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        appState.activeWorkspace = nil
        appState.markTransportInterrupted("mock interruption")

        XCTAssertEqual(appState.connectionStatus, .disconnected)
        XCTAssertEqual(appState.connectionError, "mock interruption")
        XCTAssertEqual(
            appState.activeWorkspace?.persistentModelID,
            workspace.persistentModelID,
            "Workspace should be restored from activeSession for openSession()"
        )
    }

    func testRecoverInterruptedSessionRoundTripCallsReconnectAndOpen() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let sessionId = try XCTUnwrap(appState.currentSessionId)

        appState.markTransportInterrupted("mock interruption")
        XCTAssertEqual(appState.connectionStatus, .disconnected)

        var connectCalls = 0
        var openedSessionIDs: [String] = []
        appState.autoReconnectConnectHandler = { _ in
            connectCalls += 1
            self.appState.connectionStatus = .connected
        }
        appState.autoReconnectOpenHandler = { openedSessionId, _ in
            openedSessionIDs.append(openedSessionId)
            self.appState.currentSessionId = openedSessionId
        }

        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)

        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(openedSessionIDs, [sessionId])
        XCTAssertEqual(appState.connectionStatus, .connected)
        XCTAssertNil(appState.connectionError)

        // Recovery flag should be cleared after success (no second attempt).
        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(openedSessionIDs, [sessionId])
    }

    func testRecoverInterruptedSessionReconnectFailureAllowsRetry() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        appState.markTransportInterrupted("mock interruption")
        XCTAssertNotNil(appState.activeNode, "Failed recovery should preserve active node for retry")

        var connectCalls = 0
        var openCalls = 0
        appState.autoReconnectConnectHandler = { _ in
            connectCalls += 1
            self.appState.connectionStatus = .failed
            self.appState.connectionError = "mock connect failure"
        }
        appState.autoReconnectOpenHandler = { _, _ in
            openCalls += 1
        }

        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(openCalls, 0)
        XCTAssertEqual(appState.connectionStatus, .failed)

        // Retry should run again because auto-reconnect intent remains enabled.
        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 2)
        XCTAssertEqual(openCalls, 0)
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
