import Foundation
import SwiftUI
import SwiftData

/// Root state coordinator connecting SSH, ACP, and UI.
@MainActor @Observable
final class AppState {
    // Active connection context
    var activeNode: Node?
    var activeWorkspace: Workspace?
    var activeSession: Session?
    var connectionStatus: ConnectionStatus = .disconnected
    var connectionError: String?

    // Navigation
    var shouldPopToRoot = false

    // All remote sessions discovered via session/list
    var remoteSessions: [(sessionId: String, cwd: String?, title: String?)] = []

    // Chat
    var messages: [ChatMessage] = []
    var currentSessionId: String?
    var isPrompting = false
    var isCreatingSession = false
    var scrollTrigger = 0

    // Internal
    private let sshManager = SSHConnectionManager()
    private var acpClient: ACPClient?
    private var acpService: ACPService?
    private var transport: SSHStdioTransport?
    private var notificationTask: Task<Void, Never>?
    private var ptyTask: Task<Void, Never>?

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    // MARK: - Connection

    /// Connect to a workspace's node via SSH and initialize ACP.
    /// After this, call createNewSession() or resumeSession() to start chatting.
    /// If already connected, tears down the old connection first.
    func connect(workspace: Workspace) {
        if connectionStatus == .connected || connectionStatus == .connecting {
            cleanupConnection()
        }
        guard let node = workspace.node, let key = node.sshKey else {
            connectionError = "Node or SSH key not configured"
            connectionStatus = .failed
            return
        }

        connectionStatus = .connecting
        connectionError = nil
        activeWorkspace = workspace
        activeNode = node

        // Build jump server params
        let jumpHost = node.jumpServer?.host
        let jumpPort = node.jumpServer?.port
        let jumpUsername = node.jumpServer?.username
        let jumpKeyPEM = node.jumpServer?.sshKey?.privateKeyPEM

        let params = SSHConnectionManager.ConnectionParams(
            host: node.host,
            port: node.port,
            username: node.username,
            privateKeyPEM: key.privateKeyPEM,
            command: node.command,
            jumpHost: jumpHost,
            jumpPort: jumpPort,
            jumpUsername: jumpUsername,
            jumpKeyPEM: jumpKeyPEM
        )

        Task {
            // Await full teardown of previous SSH connection before starting new one
            await sshManager.disconnect()

            do {
                let t = try await sshManager.connect(params: params)
                self.transport = t

                ptyTask = Task.detached { [sshManager] in
                    do {
                        if #available(macOS 15.0, iOS 18.0, *) {
                            try await sshManager.startPTY(
                                transport: t,
                                command: params.command
                            )
                        }
                    } catch {
                        await MainActor.run {
                            self.connectionError = "PTY closed: \(error.localizedDescription)"
                            self.connectionStatus = .disconnected
                        }
                    }
                }

                // Wait for PTY to be ready before sending ACP messages
                await t.waitUntilReady()

                let client = ACPClient(transport: t)
                await client.start()
                self.acpClient = client
                let service = ACPService(client: client)
                self.acpService = service

                // Initialize with timeout — if the ACP server doesn't respond,
                // fail instead of hanging forever.
                let initResult = try await withThrowingTimeout(seconds: 30) {
                    try await service.initialize()
                }
                Log.app.info("ACP initialized: \(String(describing: initResult))")
                Log.toFile("[AppState] ACP initialized")

                // Small delay to let the agent fully initialize
                try await Task.sleep(for: .seconds(1))

                // List all remote sessions
                do {
                    self.remoteSessions = try await service.listSessions()
                    Log.toFile("[AppState] Found \(self.remoteSessions.count) remote sessions")
                } catch {
                    Log.toFile("[AppState] session/list failed: \(error), will create new")
                    self.remoteSessions = []
                }

                self.connectionStatus = .connected
            } catch {
                Log.app.error("Connection error: \(error)")
                Log.toFile("[AppState] Connection error: \(error)")
                self.connectionError = error.localizedDescription
                self.connectionStatus = .failed
                // Clean up partially-established connection resources
                self.cleanupConnection()
            }
        }
    }

    /// Create a new ACP session on the active workspace.
    func createNewSession(modelContext: ModelContext) async throws {
        guard !isCreatingSession else { return }
        guard let service = acpService,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        messages = []

        Log.toFile("[AppState] Creating session...")
        let sessionId = try await service.createSession(cwd: workspace.path)
        self.currentSessionId = sessionId

        let session = Session(sessionId: sessionId, workspace: workspace)
        modelContext.insert(session)
        try? modelContext.save()
        self.activeSession = session

        startNotificationListener()
        addSystemMessage("New session on \(workspace.name)")
    }

    /// Resume an existing ACP session by loading it.
    /// If loading fails, falls back to creating a new session and notifies the user.
    func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
        guard let service = acpService,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        messages = []

        Log.toFile("[AppState] Loading session \(sessionId)...")
        do {
            try await service.loadSession(sessionId: sessionId, cwd: workspace.path)
        } catch {
            Log.toFile("[AppState] Load failed, creating new session: \(error)")
            addSystemMessage("Could not resume session, starting new")
            try await createNewSession(modelContext: modelContext)
            return
        }

        self.currentSessionId = sessionId

        // Find or create local Session record
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.lastUsedAt = Date()
            self.activeSession = existing
        } else {
            let session = Session(sessionId: sessionId, workspace: workspace)
            modelContext.insert(session)
            self.activeSession = session
        }
        try? modelContext.save()

        startNotificationListener()
        addSystemMessage("Loaded session")
    }

    func disconnect() {
        cleanupConnection()
        shouldPopToRoot = true
        Task { await sshManager.disconnect() }
    }

    /// Tear down the current connection state without triggering navigation.
    /// Does not close the SSH session — caller is responsible for that.
    private func cleanupConnection() {
        let client = acpClient
        let t = transport
        notificationTask?.cancel()
        ptyTask?.cancel()
        acpClient = nil
        acpService = nil
        transport = nil
        connectionStatus = .disconnected
        currentSessionId = nil
        activeSession = nil
        activeNode = nil
        activeWorkspace = nil
        remoteSessions = []
        messages = []
        // Stop ACP client and close transport asynchronously
        Task.detached {
            if let client { await client.stop() }
            if let t { await t.close() }
        }
    }

    // MARK: - Chat

    func sendMessage(_ text: String) {
        guard !text.isEmpty, !isPrompting,
              let service = acpService,
              let sessionId = currentSessionId else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        let assistantMsg = ChatMessage(role: .assistant, isStreaming: true)
        messages.append(assistantMsg)
        isPrompting = true
        scrollTrigger += 1

        Task {
            do {
                let _ = try await service.sendPrompt(sessionId: sessionId, text: text)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
            } catch {
                self.lastAssistantMessage().content += "\n[Error: \(error.localizedDescription)]"
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
            }
        }
    }

    // MARK: - Notifications

    private func startNotificationListener() {
        notificationTask?.cancel()
        guard let client = acpClient else { return }
        notificationTask = Task {
            for await notification in client.notifications {
                guard let event = SessionUpdateParser.parse(notification) else { continue }
                self.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: SessionEvent) {
        switch event {
        case .agentMessage(let text):
            lastAssistantMessage().content = text

        case .agentMessageDelta(let text):
            // If the last assistant message already has tool calls,
            // create a new message so text renders below tool cards.
            let msg = lastAssistantMessage()
            if !msg.toolCalls.isEmpty {
                msg.isStreaming = false
                let newMsg = ChatMessage(role: .assistant, isStreaming: isPrompting)
                newMsg.content = text
                messages.append(newMsg)
            } else {
                msg.content += text
            }

        case .toolCall(let id, let name, let input):
            // Tool call starting — mark previous text as done streaming.
            let msg = lastAssistantMessage()
            if !msg.content.isEmpty {
                msg.isStreaming = false
            }
            msg.toolCalls.append(
                ToolCallInfo(id: id, name: name, input: input)
            )

        case .toolCallUpdate(let id, let title, let input, let output):
            let msg = lastAssistantMessage()
            if let i = msg.toolCalls.firstIndex(where: { $0.id == id }) {
                if let title { msg.toolCalls[i].name = title }
                if let input { msg.toolCalls[i].input = input }
                if let output { msg.toolCalls[i].output = output }
            }

        case .toolCallComplete(let id, let title, let input, let output, let failed):
            let msg = lastAssistantMessage()
            if let i = msg.toolCalls.firstIndex(where: { $0.id == id }) {
                if let title { msg.toolCalls[i].name = title }
                if let input { msg.toolCalls[i].input = input }
                if let output { msg.toolCalls[i].output = output }
                msg.toolCalls[i].isComplete = true
                msg.toolCalls[i].isFailed = failed
            }

        case .thought(let text):
            lastAssistantMessage().content += "\n> \(text)"

        case .promptComplete(_):
            // Stop streaming on ALL assistant messages from this turn.
            for msg in messages where msg.role == .assistant && msg.isStreaming {
                msg.isStreaming = false
            }
            isPrompting = false
        }
        scrollTrigger += 1
    }

    /// Get or create the current assistant message for appending content.
    private func lastAssistantMessage() -> ChatMessage {
        if let last = messages.last, last.role == .assistant {
            return last
        }
        let msg = ChatMessage(role: .assistant, isStreaming: isPrompting)
        messages.append(msg)
        return msg
    }

    private func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }
}

enum AppStateError: Error, LocalizedError {
    case notConnected
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a workspace"
        case .timeout: "Connection timed out — server did not respond"
        }
    }
}

/// Run an async operation with a timeout.
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AppStateError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
