import XCTest
import SwiftData
@testable import OpenCAN

/// Unit tests for AppState session management using MockACPTransport.
/// These test the core flows: create session, send message, resume session
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

        try await appState.resumeSession(sessionId: currentSessionId, modelContext: modelContext)

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

    func testSuspendChatListAnimationsDuringHistoryLoad() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockAttachState("idle")
        await transport.setMockLoadSteps([
            .delay(milliseconds: 250),
            .userMessageChunk("History question"),
            .textDelta("History answer"),
        ])

        let sessionId = "history-tail-window"
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        let resumeTask = Task {
            try await self.appState.resumeSession(sessionId: sessionId, modelContext: self.modelContext)
        }

        try await waitFor(timeout: 2) { self.appState.isLoadingHistory }
        XCTAssertTrue(
            appState.suspendChatListAnimations,
            "Animations should be suspended while isLoadingHistory is true"
        )

        try await resumeTask.value

        XCTAssertFalse(appState.isLoadingHistory, "History load should eventually complete")
        XCTAssertFalse(appState.suspendChatListAnimations)
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

    func testResumeRunningSessionLoadsHistoryWhenReplayIsEmpty() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("prompting")
        await transport.setMockAttachBufferedEvents([])
        await transport.setMockLoadSteps([
            .userMessageChunk("history question"),
            .textDelta("history answer"),
            .promptComplete(.endTurn),
        ])

        try await appState.resumeSession(sessionId: "running-load", modelContext: modelContext)

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(ACPMethods.sessionLoad), "Running session resume should load history")
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("history answer") },
            "Running resume should apply loaded history content"
        )
    }

    func testResumeRunningSessionSkipsBlockingLoadWhenReplayIsAvailable() async throws {
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
        try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            2.0,
            "Running resume should not block on session/load when replay already has visible history"
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
            "Running resume with visible buffered replay should not issue blocking session/load"
        )
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.contains("Session resumed (still running)")
            },
            "Should surface a non-blocking running resume status"
        )
    }

    func testResumeRunningSessionLoadTimeoutDoesNotBlockForeverWhenReplayEmpty() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        appState.configureSessionLoadTimeoutForTesting(seconds: 0.2)
        await transport.setMockAttachState("prompting")
        await transport.setMockAttachBufferedEvents([])
        await transport.setMockLoadShouldHang(true)

        let sessionId = "running-load-timeout"
        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        let startedAt = Date()
        try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            2.0,
            "Running resume should stop waiting after session/load timeout when replay is empty"
        )
        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(
            methods.contains(ACPMethods.sessionLoad),
            "Should attempt session/load backfill when running replay is empty"
        )
        XCTAssertFalse(appState.isLoadingHistory)
        XCTAssertFalse(appState.isPrompting)
    }

    func testResumeSameActiveSessionReusesInMemoryTranscript() async throws {
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
        try await appState.resumeSession(sessionId: sessionId, modelContext: modelContext)
        let methodsAfter = await transport.getReceivedMethods()

        XCTAssertEqual(appState.currentSessionId, sessionId)
        XCTAssertEqual(appState.messages.map(\.content), messagesBefore)
        XCTAssertEqual(
            methodsAfter.count,
            methodsBefore.count,
            "Re-entering the same active session should not reattach/reload"
        )
    }

    // MARK: - Resume Tests: Non-Recoverable Sessions

    func testResumeAttachFailureRestoresPreviousAttachment() async throws {
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
            try await appState.resumeSession(sessionId: "busy-session", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail")
        } catch {
            // expected
        }

        XCTAssertEqual(
            appState.currentSessionId,
            previousSessionId,
            "Failed resume should restore previous attached session"
        )
        let lastAttachSessionId = await transport.getLastAttachSessionId()
        XCTAssertEqual(lastAttachSessionId, previousSessionId)
    }

    func testResumeAttachFailureAndRestoreFailureClearsCurrentSessionId() async throws {
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
            try await appState.resumeSession(sessionId: "busy-session-restore-fails", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail")
        } catch {
            // expected
        }

        XCTAssertNil(
            appState.currentSessionId,
            "When target+restore attach both fail, currentSessionId must be cleared to avoid stale detached pointer"
        )

        let methods = await transport.getReceivedMethods()
        let attachCalls = methods.filter { $0 == DaemonMethods.sessionAttach }.count
        XCTAssertGreaterThanOrEqual(attachCalls, 2, "Should attempt rollback attach")

        let lastAttachSessionId = await transport.getLastAttachSessionId()
        XCTAssertEqual(lastAttachSessionId, previousSessionId)
    }

    func testResumeSessionAlreadyAttachedByAnotherClientDoesNotRecover() async throws {
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
            try await appState.resumeSession(sessionId: "busy-session", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail for ownership conflict")
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
        XCTAssertFalse(methods.contains(DaemonMethods.sessionCreate), "Should not create recovery session on ownership conflict")
    }

    func testResumeMissingSessionAttemptsTakeoverRecovery() async throws {
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

        try await appState.resumeSession(sessionId: missingSessionID, modelContext: modelContext)

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.sessionCreate), "Missing session should trigger takeover session creation")
        XCTAssertTrue(methods.contains(ACPMethods.sessionLoad), "Missing session should attempt history load during takeover")
        XCTAssertNotEqual(appState.currentSessionId, missingSessionID)
        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content.starts(with: "External session resumed")
            }
        )
    }

    func testResumeCompletedSessionWithoutReplayReportsHistoryUnavailable() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachState("idle")
        await transport.setMockAttachBufferedEvents([])
        await transport.setMockLoadFailSessionIDs(["empty-session"])

        let session = Session(sessionId: "empty-session", workspace: workspace)
        modelContext.insert(session)
        try modelContext.save()

        try await appState.resumeSession(sessionId: "empty-session", modelContext: modelContext)

        XCTAssertTrue(
            appState.messages.contains {
                $0.role == .system && $0.content == "Session resumed (history unavailable)"
            }
        )
    }

    func testResumeSessionLoadFallsBackToAlternateCwd() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let legacyWorkspace = Workspace(name: "legacy", path: "/legacy/path")
        legacyWorkspace.node = node
        modelContext.insert(legacyWorkspace)
        try modelContext.save()

        await transport.setMockAttachState("idle")
        await transport.setMockLoadFailSessionCwdPairs([
            "legacy-history-id|/wrong/path",
            "legacy-history-id|/test/path",
        ])
        await transport.setMockLoadSteps([
            .userMessageChunk("Question"),
            .textDelta("Loaded from alternate cwd."),
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
            appState.messages.contains { $0.role == .assistant && $0.content.contains("alternate cwd") },
            "Should load session history via alternate cwd"
        )
    }

    func testResumeExternalSessionTakeover() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("external-session-1"),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(3),
            ]
        ])
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Continued on mobile."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        try await appState.resumeSession(sessionId: "external-session-1", modelContext: modelContext)

        let resumedSessionId = try XCTUnwrap(appState.currentSessionId)
        XCTAssertNotEqual(resumedSessionId, "external-session-1")
        XCTAssertTrue(resumedSessionId.hasPrefix("mock-sess-"))

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.sessionCreate), "External takeover should create a managed session")
        XCTAssertTrue(methods.contains(ACPMethods.sessionLoad), "External takeover should load external history")
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Continued on mobile.") }
        )
    }

    func testResumeExternalSessionRedirectsToMappedManagedSessionWithoutDaemonManagedRow() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        let externalSessionId = "external-session-mapped"
        let managedSessionId = "managed-session-local"

        await transport.setMockSessionList([
            [
                "sessionId": .string(externalSessionId),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setMockAttachState("idle")
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Reused mapped managed session."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        let mapped = Session(
            sessionId: managedSessionId,
            canonicalSessionId: externalSessionId,
            sessionCwd: "/test/path",
            workspace: workspace
        )
        modelContext.insert(mapped)
        try modelContext.save()

        try await appState.resumeSession(sessionId: externalSessionId, modelContext: modelContext)

        XCTAssertEqual(appState.currentSessionId, managedSessionId)
        let lastAttachSessionId = await transport.getLastAttachSessionId()
        XCTAssertEqual(lastAttachSessionId, managedSessionId)

        let methods = await transport.getReceivedMethods()
        XCTAssertFalse(
            methods.contains(DaemonMethods.sessionCreate),
            "Mapped external resume should not create a new takeover session"
        )
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Reused mapped managed session.") }
        )
    }

    func testResumeExternalSessionTakeoverRetriesAlternateCommandAfterQueryClosed() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            "claude": true,
            "codex": true,
        ])
        await appState.refreshAvailableAgents()

        await transport.setMockSessionList([
            [
                "sessionId": .string("external-session-retry"),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setNextLoadError(
            code: -32603,
            message: "Internal error",
            data: .object([
                "details": .string("Query closed before response received")
            ])
        )
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Recovered with alternate command."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        try await appState.resumeSession(sessionId: "external-session-retry", modelContext: modelContext)

        let createCommands = await transport.getCreateCommands()
        XCTAssertGreaterThanOrEqual(createCommands.count, 2, "Should retry takeover with another command")
        XCTAssertEqual(createCommands.first, AgentCommandStore.command(for: .claude))
        XCTAssertTrue(createCommands.contains(AgentCommandStore.command(for: .codex)))

        let killed = await transport.getKilledSessionIds()
        XCTAssertEqual(killed.count, 1, "Failed takeover attempt should be cleaned up")
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Recovered with alternate command.") }
        )
    }

    func testResumeExternalSessionTakeoverRetriesAlternateCommandAfterSessionNotFound() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            "claude": true,
            "codex": true,
        ])
        await appState.refreshAvailableAgents()

        await transport.setMockSessionList([
            [
                "sessionId": .string("external-session-notfound"),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setNextLoadError(
            code: -32603,
            message: "Internal error",
            data: .object([
                "details": .string("Session not found")
            ])
        )
        await transport.setMockLoadSteps([
            .userMessageChunk("External conversation"),
            .textDelta("Recovered after not-found command retry."),
            .promptComplete(.endTurn),
        ])
        await appState.refreshDaemonSessions()

        try await appState.resumeSession(sessionId: "external-session-notfound", modelContext: modelContext)

        let createCommands = await transport.getCreateCommands()
        XCTAssertGreaterThanOrEqual(createCommands.count, 2, "Should retry takeover with another command when first loader reports not found")
        XCTAssertEqual(createCommands.first, AgentCommandStore.command(for: .claude))
        XCTAssertTrue(createCommands.contains(AgentCommandStore.command(for: .codex)))

        let killed = await transport.getKilledSessionIds()
        XCTAssertEqual(killed.count, 1, "Failed takeover attempt should be cleaned up")
        XCTAssertTrue(
            appState.messages.contains { $0.role == .assistant && $0.content.contains("Recovered after not-found command retry.") }
        )
    }

    func testResumeExternalSessionTakeoverLoadFailureDoesNotPersistManagedSessionID() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAgentAvailabilityByID([
            "claude": true,
            "codex": true,
        ])
        await appState.refreshAvailableAgents()

        await transport.setMockSessionList([
            [
                "sessionId": .string("external-session-fail"),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(0),
            ]
        ])
        await transport.setMockLoadFailSessionIDs(["external-session-fail"])
        await appState.refreshDaemonSessions()

        let local = Session(sessionId: "external-session-fail", workspace: workspace)
        modelContext.insert(local)
        try modelContext.save()

        do {
            try await appState.resumeSession(sessionId: "external-session-fail", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail when takeover load fails for all commands")
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

        let createCommands = await transport.getCreateCommands()
        XCTAssertGreaterThanOrEqual(createCommands.count, 2)

        let killed = await transport.getKilledSessionIds()
        XCTAssertEqual(killed.count, createCommands.count, "All failed takeover sessions should be cleaned up")
    }

    func testResumeMissingSessionTakeoverFailureMarksSessionDead() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockAttachShouldFail(true)
        await transport.setMockLoadFailSessionIDs(["missing-session-dead"])

        let missing = Session(sessionId: "missing-session-dead", workspace: workspace)
        modelContext.insert(missing)
        try modelContext.save()

        do {
            try await appState.resumeSession(sessionId: "missing-session-dead", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail")
        } catch let error as AppStateError {
            guard case .sessionNotRecoverable(let sessionId) = error else {
                XCTFail("Expected sessionNotRecoverable, got \(error)")
                return
            }
            XCTAssertEqual(sessionId, "missing-session-dead")
        }

        let deadEntry = appState.daemonSessions.first { $0.sessionId == "missing-session-dead" }
        XCTAssertEqual(deadEntry?.state, "dead")
    }

    func testResumeExternalSessionTakeoverCleansCreatedSessionWhenAttachFails() async throws {
        try await connectMock()

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }

        await transport.setMockSessionList([
            [
                "sessionId": .string("external-attach-fail"),
                "cwd": .string("/test/path"),
                "state": .string("external"),
                "lastEventSeq": .int(0),
            ]
        ])
        await appState.refreshDaemonSessions()

        await transport.setNextAttachError(
            code: -32000,
            message: "attach failed",
            data: nil
        )

        do {
            try await appState.resumeSession(sessionId: "external-attach-fail", modelContext: modelContext)
            XCTFail("Expected resumeSession to fail when takeover attach fails")
        } catch {
            // expected
        }

        let methods = await transport.getReceivedMethods()
        XCTAssertTrue(methods.contains(DaemonMethods.sessionCreate))
        XCTAssertTrue(methods.contains(DaemonMethods.sessionKill), "Failed takeover attach should cleanup created session")

        let killed = await transport.getKilledSessionIds()
        XCTAssertEqual(killed.count, 1, "Exactly one created takeover session should be killed")
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
        XCTAssertEqual(u2.displayState, "external")
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

    func testUnifiedSessionDisplayTitleUsesFullSessionIDWhenNoTitle() {
        let sessionID = "019cabed-6f1d-75f1-8a47-44aed3b42e10"
        let unified = UnifiedSession(
            sessionId: sessionID,
            daemonState: "idle",
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

    func testUnifiedSessionExternalIsResumable() {
        let unified = UnifiedSession(
            sessionId: "external-sess",
            daemonState: "external",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            daemonTitle: "External Session",
            lastUsedAt: nil,
            agentID: nil,
            agentCommand: nil
        )
        XCTAssertTrue(unified.isResumable)
        XCTAssertEqual(unified.displayState, "external")
    }

    func testUnifiedSessionUsesDaemonUpdatedAtWhenNoLocalTimestamp() {
        let daemonDate = Date(timeIntervalSince1970: 1_700_000_000)
        let unified = UnifiedSession(
            sessionId: "external-no-local-date",
            daemonState: "external",
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
            "Workspace should be restored from activeSession for resumeSession()"
        )
    }

    func testRecoverInterruptedSessionRoundTripCallsReconnectAndResume() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)
        let sessionId = try XCTUnwrap(appState.currentSessionId)

        appState.markTransportInterrupted("mock interruption")
        XCTAssertEqual(appState.connectionStatus, .disconnected)

        var connectCalls = 0
        var resumedSessionIDs: [String] = []
        appState.autoReconnectConnectHandler = { _ in
            connectCalls += 1
            self.appState.connectionStatus = .connected
        }
        appState.autoReconnectResumeHandler = { resumedSessionId, _ in
            resumedSessionIDs.append(resumedSessionId)
            self.appState.currentSessionId = resumedSessionId
        }

        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)

        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(resumedSessionIDs, [sessionId])
        XCTAssertEqual(appState.connectionStatus, .connected)
        XCTAssertNil(appState.connectionError)

        // Recovery flag should be cleared after success (no second attempt).
        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(resumedSessionIDs, [sessionId])
    }

    func testRecoverInterruptedSessionReconnectFailureAllowsRetry() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        appState.markTransportInterrupted("mock interruption")
        XCTAssertNotNil(appState.activeNode, "Failed recovery should preserve active node for retry")

        var connectCalls = 0
        var resumeCalls = 0
        appState.autoReconnectConnectHandler = { _ in
            connectCalls += 1
            self.appState.connectionStatus = .failed
            self.appState.connectionError = "mock connect failure"
        }
        appState.autoReconnectResumeHandler = { _, _ in
            resumeCalls += 1
        }

        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(appState.connectionStatus, .failed)

        // Retry should run again because auto-reconnect intent remains enabled.
        await appState.recoverInterruptedSessionIfNeeded(modelContext: modelContext)
        XCTAssertEqual(connectCalls, 2)
        XCTAssertEqual(resumeCalls, 0)
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
