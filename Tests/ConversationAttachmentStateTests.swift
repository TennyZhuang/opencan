import XCTest
import SwiftData
@testable import OpenCAN

@MainActor
final class ConversationAttachmentStateTests: XCTestCase {
    private var appState: AppState!
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!
    private var workspace: Workspace!
    private var node: Node!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(
            for: SSHKeyPair.self, Node.self, Workspace.self, Session.self,
            configurations: config
        )
        modelContext = ModelContext(modelContainer)

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

    private func connectMock(scenario: MockScenario = .simple) async throws {
        appState.connectMock(workspace: workspace, scenario: scenario)
        try await waitFor(timeout: 5) { self.appState.connectionStatus == .connected }
    }

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

    func testAttachmentStateIsAttachedAfterSessionCreate() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        let conversationId = try XCTUnwrap(appState.activeSession?.conversationId)
        let runtimeId = try XCTUnwrap(appState.currentSessionId)

        guard case .attached(let derivedConversationId, let derivedRuntimeId, let turnState) = appState.conversationAttachmentState else {
            XCTFail("Expected attached state")
            return
        }

        XCTAssertEqual(derivedConversationId, conversationId)
        XCTAssertEqual(derivedRuntimeId, runtimeId)
        XCTAssertEqual(turnState, .idle)
        XCTAssertTrue(appState.conversationAttachmentState.allowsPromptSend)
        XCTAssertFalse(appState.shouldShowChatReconnectOverlay)
    }

    func testAttachmentStateBecomesPromptingWhileTurnIsActive() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        guard let transport = appState.mockTransport else {
            XCTFail("Mock transport not available")
            return
        }
        await transport.setMockPromptShouldHang(true)

        XCTAssertTrue(appState.sendMessage("hang this prompt"))
        try await waitFor(timeout: 5) { self.appState.isPrompting }

        guard case .attached(_, _, let turnState) = appState.conversationAttachmentState else {
            XCTFail("Expected attached state while prompt is active")
            return
        }

        XCTAssertEqual(turnState, .prompting)
    }

    func testAttachmentStateBecomesRecoveringAfterTransportInterrupt() async throws {
        try await connectMock()
        try await appState.createNewSession(modelContext: modelContext)

        let conversationId = try XCTUnwrap(appState.activeSession?.conversationId)
        let runtimeId = try XCTUnwrap(appState.currentSessionId)

        appState.markTransportInterrupted("mock interruption")

        guard case .recovering(
            let derivedConversationId,
            let lastKnownRuntimeId,
            let lastEventSeq,
            let transportState
        ) = appState.conversationAttachmentState else {
            XCTFail("Expected recovering state after interrupt")
            return
        }

        XCTAssertEqual(derivedConversationId, conversationId)
        XCTAssertEqual(lastKnownRuntimeId, runtimeId)
        XCTAssertEqual(lastEventSeq, 0)
        XCTAssertEqual(transportState, .disconnected)
        XCTAssertTrue(appState.shouldShowChatReconnectOverlay)
        XCTAssertFalse(appState.conversationAttachmentState.allowsPromptSend)
    }

    func testAttachmentStateMapsUnavailableConversation() throws {
        let session = Session(
            runtimeId: "runtime-stale-1",
            conversationId: "conversation-stable-1",
            conversationCwd: "/test/path",
            workspace: workspace
        )
        modelContext.insert(session)
        try modelContext.save()

        appState.activeSession = session
        appState.currentSessionId = nil
        appState.daemonConversations = [
            DaemonConversationInfo(
                conversationId: "conversation-stable-1",
                runtimeId: nil,
                state: "unavailable",
                cwd: "/test/path",
                command: nil,
                title: nil,
                updatedAt: nil,
                ownerId: nil,
                origin: "managed",
                lastEventSeq: 0
            )
        ]

        XCTAssertEqual(
            appState.conversationAttachmentState,
            .unavailable(conversationId: "conversation-stable-1")
        )
        XCTAssertFalse(appState.conversationAttachmentState.allowsPromptSend)
        XCTAssertFalse(appState.shouldShowChatReconnectOverlay)
    }

    func testAttachmentStateDoesNotReportAttachedWithoutLiveConnection() {
        let session = Session(
            runtimeId: "runtime-stale-1",
            conversationId: "conversation-stable-1",
            conversationCwd: "/test/path",
            workspace: workspace
        )

        let state = ConversationAttachmentState.derive(
            connectionStatus: .failed,
            activeSession: session,
            currentSessionId: "runtime-stale-1",
            daemonConversations: [],
            daemonSessions: [],
            isPrompting: false,
            shouldAutoReconnectInterruptedSession: false,
            isAutoReconnectInProgress: false,
            lastEventSeqByRuntimeID: [:]
        )

        XCTAssertEqual(state, .none)
        XCTAssertFalse(state.allowsPromptSend)
    }
}
