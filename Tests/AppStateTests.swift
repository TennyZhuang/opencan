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
            lastUsedAt: nil
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
            lastUsedAt: Date()
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
            lastUsedAt: Date()
        )
        XCTAssertEqual(u3.displayState, "prompting")
        XCTAssertTrue(u3.isResumable)
        XCTAssertEqual(u3.displayTitle, "Running Session")
    }

    func testUnifiedSessionDeadNotResumable() {
        let unified = UnifiedSession(
            sessionId: "dead-sess",
            daemonState: "dead",
            cwd: "/test",
            lastEventSeq: 0,
            title: nil,
            lastUsedAt: nil
        )
        XCTAssertFalse(unified.isResumable)
        XCTAssertEqual(unified.displayState, "dead")
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

// MARK: - MockACPTransport test configuration helpers

extension MockACPTransport {
    func setMockAttachState(_ state: String) {
        self.mockAttachState = state
    }

    func setMockAttachBufferedEvents(_ events: [[String: JSONValue]]) {
        self.mockAttachBufferedEvents = events
    }

    func setMockAttachShouldFail(_ fail: Bool) {
        self.mockAttachShouldFail = fail
    }

    func setMockSessionList(_ list: [[String: JSONValue]]) {
        self.mockSessionList = list
    }

    func setMockLoadSteps(_ steps: [MockStep]) {
        self.mockLoadSteps = steps
    }

    func setMockLoadFailSessionIDs(_ ids: Set<String>) {
        self.mockLoadFailSessionIDs = ids
    }

    func setMockLoadFailSessionCwdPairs(_ pairs: Set<String>) {
        self.mockLoadFailSessionCwdPairs = pairs
    }

    func getLastLoadSessionId() -> String? {
        lastLoadSessionId
    }

    func getLastLoadRouteToSessionId() -> String? {
        lastLoadRouteToSessionId
    }

    func getLastLoadCwd() -> String? {
        lastLoadCwd
    }

    func getReceivedMethods() -> [String] {
        receivedMethods
    }

    func getDetachedSessionIds() -> [String] {
        detachedSessionIds
    }
}
