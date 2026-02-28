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

    // Daemon sessions (replaces remoteSessions)
    var daemonSessions: [DaemonSessionInfo] = []

    // Chat
    var messages: [ChatMessage] = []
    var currentSessionId: String?
    var isPrompting = false
    var isCreatingSession = false
    /// True while replaying history via session/load — suppresses streaming UI.
    var isLoadingHistory = false
    /// Incremented (debounced) when chat content changes. The view
    /// auto-scrolls only if the user is already near the bottom.
    var contentVersion = 0
    /// Set to true when the user sends a message — forces scroll
    /// to bottom regardless of current scroll position.
    var forceScrollToBottom = false

    // Daemon upload progress (nil = not uploading, 0..1 = uploading)
    var daemonUploadProgress: Double?

    // Internal
    private let sshManager = SSHConnectionManager()
    private var acpClient: ACPClient?
    private var acpService: ACPService?
    private var daemonClient: DaemonClient?
    private var transport: SSHStdioTransport?
    private(set) var mockTransport: MockACPTransport?
    private var notificationTask: Task<Void, Never>?
    private var ptyTask: Task<Void, Never>?
    private var isStreamingThought = false
    /// Per-session event sequence tracking for daemon replay.
    private var lastEventSeq: [String: UInt64] = [:]
    /// Session IDs that are allowed to emit events during session/load history replay.
    private var historyLoadSessionIds: Set<String> = []
    private var historyLoadCleanupTask: Task<Void, Never>?
    private var historyLoadGeneration: UInt64 = 0

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    // MARK: - Connection

    /// Connect to a node via SSH and the daemon.
    /// After this, set activeWorkspace and call createNewSession() or resumeSession() to start chatting.
    /// If already connected, tears down the old connection first.
    func connect(node: Node) {
        if connectionStatus == .connected || connectionStatus == .connecting {
            cleanupConnection()
        }
        guard let key = node.sshKey else {
            connectionError = "SSH key not configured"
            connectionStatus = .failed
            return
        }

        connectionStatus = .connecting
        connectionError = nil
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
            command: "~/.opencan/bin/opencan-daemon attach",  // Always use daemon
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

                // Ensure daemon binary is installed on the server
                try await sshManager.ensureDaemonInstalled { [weak self] fraction in
                    Task { @MainActor in
                        self?.daemonUploadProgress = fraction
                    }
                }
                self.daemonUploadProgress = nil

                ptyTask = Task.detached { [sshManager] in
                    do {
                        if #available(macOS 15.0, iOS 18.0, *) {
                            try await sshManager.startPTY(
                                transport: t,
                                command: params.command
                            )
                        }
                    } catch {
                        // PTY died — close the transport so the ACP client's
                        // message stream ends and pending requests are cancelled.
                        await t.close()
                        await MainActor.run {
                            self.connectionError = "PTY closed: \(error.localizedDescription)"
                            self.connectionStatus = .disconnected
                        }
                    }
                }

                // Wait for PTY to be ready before sending messages
                await t.waitUntilReady()
                Log.toFile("[AppState] PTY ready, waiting for daemon/attached signal...")

                let client = ACPClient(transport: t)
                await client.start()
                self.acpClient = client

                // Wait for the first JSON-RPC message from the transport.
                // opencan-daemon attach prints {"jsonrpc":"2.0","method":"daemon/attached",...}
                // when it has connected to the daemon socket and is ready to bridge.
                // This prevents sending daemon/hello before the bridge is set up.
                try await withThrowingTimeout(seconds: 30) {
                    await t.waitForFirstJSON()
                }
                Log.toFile("[AppState] Daemon attached, sending hello...")

                // ACPService is kept for sendPrompt (daemon forwards transparently)
                let service = ACPService(client: client)
                self.acpService = service

                // Initialize daemon connection with timeout
                let daemon = DaemonClient(client: client)
                let info = try await withThrowingTimeout(seconds: 30) {
                    try await daemon.hello()
                }
                self.daemonClient = daemon
                self.daemonSessions = info.sessions
                Log.app.info("Daemon connected: v\(info.daemonVersion), \(info.sessions.count) sessions")
                Log.toFile("[AppState] Daemon connected: v\(info.daemonVersion)")

                // Start notification listener once for the entire connection.
                // Do NOT restart it per-session — AsyncStream only supports one consumer.
                startNotificationListener()

                self.connectionStatus = .connected
            } catch {
                Log.app.error("Connection error: \(error)")
                Log.toFile("[AppState] Connection error: \(error)")
                self.connectionError = error.localizedDescription
                self.connectionStatus = .failed
                self.cleanupConnection()
            }
        }
    }

    /// Connect using a mock transport for offline UI testing.
    /// Skips SSH entirely — plugs MockACPTransport directly into ACPClient.
    func connectMock(workspace: Workspace, scenario: MockScenario = .simple) {
        if connectionStatus == .connected || connectionStatus == .connecting {
            cleanupConnection()
        }

        connectionStatus = .connecting
        connectionError = nil
        activeWorkspace = workspace
        activeNode = workspace.node

        Task {
            let transport = MockACPTransport(scenario: scenario)
            self.mockTransport = transport

            let client = ACPClient(transport: transport)
            await client.start()
            self.acpClient = client

            let service = ACPService(client: client)
            self.acpService = service

            let daemon = DaemonClient(client: client)

            do {
                let info = try await daemon.hello()
                self.daemonClient = daemon
                self.daemonSessions = info.sessions
                Log.toFile("[AppState] Mock daemon connected")

                startNotificationListener()

                self.connectionStatus = .connected
            } catch {
                Log.toFile("[AppState] Mock connection error: \(error)")
                self.connectionError = error.localizedDescription
                self.connectionStatus = .failed
                self.cleanupConnection()
            }
        }
    }

    /// Refresh daemon session snapshot used by SessionPicker state badges.
    func refreshDaemonSessions() async {
        guard let daemon = daemonClient else { return }
        if let updated = try? await daemon.listSessions() {
            self.daemonSessions = updated
        }
    }

    /// Create a new ACP session via the daemon using the app's default agent.
    func createNewSession(modelContext: ModelContext) async throws {
        let defaultAgent = AgentCommandStore.defaultAgent()
        try await createNewSession(modelContext: modelContext, agent: defaultAgent)
    }

    /// Create a new ACP session via the daemon using a specific built-in agent.
    func createNewSession(modelContext: ModelContext, agent: AgentKind) async throws {
        let command = AgentCommandStore.command(for: agent)
        try await createNewSession(
            modelContext: modelContext,
            agentID: agent.rawValue,
            command: command
        )
    }

    /// Create a new ACP session via the daemon using explicit agent metadata.
    private func createNewSession(modelContext: ModelContext, agentID: String, command: String) async throws {
        guard let daemon = daemonClient,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        messages = []
        let launchCommand = normalizeAgentCommand(command, fallback: AgentCommandStore.command(forAgentID: agentID))

        Log.toFile("[AppState] Creating session via daemon...")
        let sessionId = try await daemon.createSession(
            cwd: workspace.path,
            command: launchCommand
        )
        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon)
        self.currentSessionId = sessionId
        self.lastEventSeq[sessionId] = 0

        // Auto-attach to the new session
        let _ = try await daemon.attachSession(sessionId: sessionId, lastEventSeq: 0)

        let session = Session(
            sessionId: sessionId,
            sessionCwd: workspace.path,
            agentID: agentID,
            agentCommand: launchCommand,
            workspace: workspace
        )
        modelContext.insert(session)
        try? modelContext.save()
        self.activeSession = session

        // Refresh daemon session list so SessionPickerView shows the new session
        await refreshDaemonSessions()

        addSystemMessage("New session on \(workspace.name)")
    }

    /// Resume an existing session via daemon attach with event replay.
    /// Strategy depends on session state:
    /// - Running (prompting/draining): buffer replay + live streaming
    /// - Completed/idle: daemon attach + buffer replay (session/load only as backfill)
    /// - History (not in daemon): create new session + session/load old history
    func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
        guard let daemon = daemonClient,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let existingSession = try? modelContext.fetch(sessionDescriptor).first
        let daemonKnownSession = daemonSessions.first(where: { $0.sessionId == sessionId })
        let daemonKnownCwd = daemonKnownSession?.cwd
        let daemonKnownCommand = daemonKnownSession?.command
        let historySessionId = existingSession?.historySessionId
        let sourceSessionId = historySessionId ?? sessionId
        let sourceSessionCwd: String? = if historySessionId != nil {
            existingSession?.historySessionCwd ?? existingSession?.sessionCwd ?? daemonKnownCwd
        } else {
            existingSession?.sessionCwd ?? daemonKnownCwd
        }
        let sessionAgent = resolveSessionAgent(
            storedAgentID: existingSession?.agentID,
            storedAgentCommand: existingSession?.agentCommand,
            daemonCommand: daemonKnownCommand
        )

        messages = []

        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon)

        // External sessions (not managed by daemon) go straight to history recovery.
        if daemonKnownSession?.state == "external" {
            Log.toFile("[AppState] External session \(sessionId), recovering via session/load")
            try await resumeHistorySession(
                oldSessionId: sessionId,
                sourceSessionId: sourceSessionId,
                sourceSessionCwd: sourceSessionCwd,
                workspace: workspace,
                agentID: sessionAgent.id,
                command: sessionAgent.command,
                daemon: daemon,
                modelContext: modelContext
            )
            return
        }

        Log.toFile("[AppState] Attaching to session \(sessionId)...")
        let shouldReplayFullBuffer = daemonKnownSession?.state == "idle" || daemonKnownSession?.state == "completed"
        let desiredAttachSeq = shouldReplayFullBuffer ? 0 : (lastEventSeq[sessionId] ?? 0)
        let result: DaemonAttachResult
        do {
            result = try await daemon.attachSession(
                sessionId: sessionId,
                lastEventSeq: desiredAttachSeq
            )
        } catch {
            // Daemon doesn't know this session — recover via session/load
            Log.toFile("[AppState] Attach failed, recovering history session: \(error)")
            try await resumeHistorySession(
                oldSessionId: sessionId,
                sourceSessionId: sourceSessionId,
                sourceSessionCwd: sourceSessionCwd,
                workspace: workspace,
                agentID: sessionAgent.id,
                command: sessionAgent.command,
                daemon: daemon,
                modelContext: modelContext
            )
            return
        }

        self.currentSessionId = sessionId

        let isRunning = result.state == "prompting" || result.state == "draining"
        var resolvedSessionCwd = daemonKnownCwd ?? existingSession?.sessionCwd ?? workspace.path

        if isRunning {
            // Replay buffered events. Set isPrompting before replay so that
            // a prompt_complete in the buffer can clear it.
            isPrompting = true
            for buffered in result.bufferedEvents {
                if let event = SessionUpdateParser.parse(buffered.event) {
                    handleSessionEvent(event)
                }
                lastEventSeq[sessionId] = buffered.seq
            }
            // After replay, always clear isPrompting for draining sessions.
            // The user reconnected to interact — they shouldn't be locked out
            // if the ACP is stuck or dead. If the old prompt is genuinely
            // still running, prompt_complete will arrive via the notification
            // listener in the background. If the user sends while the ACP is
            // busy, the ACP will reject it and the error will be shown.
            if isPrompting {
                isPrompting = false
                for msg in messages where msg.isStreaming {
                    msg.isStreaming = false
                }
                Log.toFile("[AppState] Cleared isPrompting after draining/running session replay")
            }
        } else {
            // Completed/idle session: prefer daemon buffer replay first.
            // session/load is only used as a backfill when replay gives no visible history.
            for buffered in result.bufferedEvents {
                if let event = SessionUpdateParser.parse(buffered.event) {
                    handleSessionEvent(event)
                }
                lastEventSeq[sessionId] = buffered.seq
            }

            let hasHistorySource = (historySessionId != nil && historySessionId != sessionId)
            let hasVisibleReplay = hasRenderableConversation()
            if !hasVisibleReplay || hasHistorySource {
                beginHistoryLoadScope(sessionIds: Set([sessionId]))
                Log.toFile("[AppState] Loading history via session/load for \(sessionId)...")
                let primaryCwds = loadCwdCandidates(
                    preferred: [existingSession?.sessionCwd, daemonKnownCwd, workspace.path],
                    workspace: workspace
                )
                let loadedPrimaryCwd = await loadSessionFromCandidates(
                    sessionId: sessionId,
                    candidateCwds: primaryCwds
                )

                if let loadedPrimaryCwd {
                    resolvedSessionCwd = loadedPrimaryCwd
                } else if let historySessionId, historySessionId != sessionId {
                    historyLoadSessionIds.insert(historySessionId)
                    let historyCwds = loadCwdCandidates(
                        preferred: [
                            existingSession?.historySessionCwd,
                            existingSession?.sessionCwd,
                            daemonKnownCwd,
                            workspace.path
                        ],
                        workspace: workspace
                    )
                    if let loadedHistoryCwd = await loadSessionFromCandidates(
                        sessionId: historySessionId,
                        routeToSessionId: sessionId,
                        candidateCwds: historyCwds
                    ) {
                        existingSession?.historySessionCwd = loadedHistoryCwd
                    }
                }
            } else {
                Log.toFile(
                    "[AppState] Resumed \(sessionId) via buffered replay (\(result.bufferedEvents.count) events), skipping session/load"
                )
            }
            endHistoryLoadScope()
            // Ensure no stale streaming indicators
            for msg in messages where msg.isStreaming {
                msg.isStreaming = false
            }
        }

        // Find or create local Session record
        if let existing = existingSession {
            existing.lastUsedAt = Date()
            existing.sessionCwd = resolvedSessionCwd
            if existing.historySessionId == sessionId {
                existing.historySessionId = nil
                existing.historySessionCwd = nil
            }
            existing.agentID = existing.agentID ?? sessionAgent.id
            existing.agentCommand = normalizeAgentCommand(
                existing.agentCommand,
                fallback: sessionAgent.command
            )
            self.activeSession = existing
        } else {
            let session = Session(
                sessionId: sessionId,
                sessionCwd: resolvedSessionCwd,
                historySessionId: historySessionId == sessionId ? nil : historySessionId,
                historySessionCwd: historySessionId == sessionId ? nil : sourceSessionCwd,
                agentID: sessionAgent.id,
                agentCommand: sessionAgent.command,
                workspace: workspace
            )
            modelContext.insert(session)
            self.activeSession = session
        }
        try? modelContext.save()

        let statusMsg: String
        if isRunning {
            statusMsg = "Session resumed (still running)"
        } else if result.state == "completed" {
            statusMsg = "Session resumed (completed)"
        } else {
            statusMsg = "Session resumed"
        }
        addSystemMessage(statusMsg)

        await refreshDaemonSessions()

        if !result.bufferedEvents.isEmpty && isRunning {
            Log.toFile("[AppState] Replayed \(result.bufferedEvents.count) buffered events")
        }
    }

    /// Resume a "history" session whose daemon has forgotten it.
    /// Creates a fresh ACP process and loads the old session's conversation into it.
    /// `command` is expected to be resolved and normalized by the caller.
    private func resumeHistorySession(
        oldSessionId: String,
        sourceSessionId: String,
        sourceSessionCwd: String?,
        workspace: Workspace,
        agentID: String,
        command: String,
        daemon: DaemonClient,
        modelContext: ModelContext
    ) async throws {
        Log.toFile("[AppState] Creating new session to recover history of \(sourceSessionId)...")

        // Create a fresh ACP process
        let launchCommand = command
        let newSessionId = try await daemon.createSession(
            cwd: workspace.path,
            command: launchCommand
        )

        await detachCurrentSessionIfNeeded(beforeAttaching: newSessionId, daemon: daemon)

        // Attach to the new session
        let _ = try await daemon.attachSession(sessionId: newSessionId, lastEventSeq: 0)
        self.currentSessionId = newSessionId
        self.lastEventSeq[newSessionId] = 0

        // Load old session's history into the new ACP process.
        // __routeToSession tells the daemon to forward this to the new session's ACP process,
        // while sessionId tells the ACP which conversation to load from disk.
        beginHistoryLoadScope(sessionIds: Set([sourceSessionId, newSessionId]))
        Log.toFile("[AppState] Loading history of \(sourceSessionId) into new session \(newSessionId)...")
        let sourceLoadCwds = loadCwdCandidates(
            preferred: [sourceSessionCwd, workspace.path],
            workspace: workspace
        )
        let loadedSourceCwd = await loadSessionFromCandidates(
            sessionId: sourceSessionId,
            routeToSessionId: newSessionId,
            candidateCwds: sourceLoadCwds
        )
        let historyLoadFailed = loadedSourceCwd == nil
        endHistoryLoadScope()
        for msg in messages where msg.isStreaming {
            msg.isStreaming = false
        }

        // Update local Session record: point old sessionId to new daemon session
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == oldSessionId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.sessionId = newSessionId
            existing.sessionCwd = workspace.path
            existing.historySessionId = sourceSessionId == newSessionId ? nil : sourceSessionId
            existing.historySessionCwd = sourceSessionId == newSessionId
                ? nil
                : (loadedSourceCwd ?? sourceSessionCwd)
            existing.agentID = agentID
            existing.agentCommand = launchCommand
            existing.lastUsedAt = Date()
            self.activeSession = existing
        } else {
            let session = Session(
                sessionId: newSessionId,
                sessionCwd: workspace.path,
                historySessionId: sourceSessionId == newSessionId ? nil : sourceSessionId,
                historySessionCwd: sourceSessionId == newSessionId
                    ? nil
                    : (loadedSourceCwd ?? sourceSessionCwd),
                agentID: agentID,
                agentCommand: launchCommand,
                workspace: workspace
            )
            modelContext.insert(session)
            self.activeSession = session
        }
        try? modelContext.save()

        // Refresh daemon session list
        await refreshDaemonSessions()

        if historyLoadFailed {
            addSystemMessage("Session recovered (conversation history unavailable)")
        } else {
            addSystemMessage("Session recovered from history")
        }
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
        let mt = mockTransport
        notificationTask?.cancel()
        ptyTask?.cancel()
        historyLoadCleanupTask?.cancel()
        historyLoadCleanupTask = nil
        acpClient = nil
        acpService = nil
        daemonClient = nil
        transport = nil
        mockTransport = nil
        connectionStatus = .disconnected
        currentSessionId = nil
        activeSession = nil
        activeNode = nil
        activeWorkspace = nil
        daemonSessions = []
        daemonUploadProgress = nil
        messages = []
        isPrompting = false
        isCreatingSession = false
        isLoadingHistory = false
        historyLoadSessionIds = []
        historyLoadGeneration = 0
        // lastEventSeq intentionally kept — needed for reconnect replay
        // Stop ACP client and close transport asynchronously
        Task.detached {
            if let client { await client.stop() }
            if let t { await t.close() }
            if let mt { await mt.close() }
        }
    }

    // MARK: - Chat

    func sendMessage(_ text: String) {
        guard !text.isEmpty else { return }
        guard !isPrompting else {
            Log.toFile("[AppState] sendMessage blocked — isPrompting=true, currentSessionId=\(currentSessionId ?? "nil")")
            addSystemMessage("Still waiting for response...")
            return
        }
        guard let service = acpService,
              let sessionId = currentSessionId else {
            addSystemMessage("Not connected — please reconnect")
            return
        }

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        // Set session title from first user message
        if let session = activeSession, session.title == nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
            session.title = String(firstLine.prefix(50))
        }

        let assistantMsg = ChatMessage(role: .assistant, isStreaming: true)
        messages.append(assistantMsg)
        isPrompting = true
        forceScrollToBottom = true
        Log.toFile("[AppState] sendMessage: isPrompting=true, sending prompt to \(sessionId)")

        Task {
            do {
                let _ = try await service.sendPrompt(sessionId: sessionId, text: text)
                Log.toFile("[AppState] sendPrompt returned successfully")
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
                await self.refreshDaemonSessions()
            } catch {
                Log.toFile("[AppState] sendPrompt error: \(error)")
                self.presentPromptError(error)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
                await self.refreshDaemonSessions()
            }
        }
    }

    // MARK: - Notifications

    private func startNotificationListener() {
        notificationTask?.cancel()
        guard let client = acpClient else { return }
        Log.toFile("[AppState] Starting notification listener")
        notificationTask = Task {
            for await notification in client.notifications {
                // Track __seq from daemon-forwarded notifications
                if case .notification(_, let params) = notification,
                   let seq = params?["__seq"]?.intValue,
                   let routedSessionId = self.currentSessionId {
                    self.lastEventSeq[routedSessionId] = UInt64(seq)
                }

                let notificationSessionId: String?
                if case .notification(_, let params) = notification {
                    notificationSessionId = params?["sessionId"]?.stringValue
                } else {
                    notificationSessionId = nil
                }

                guard self.shouldHandleSessionNotification(for: notificationSessionId) else {
                    Log.toFile("[AppState] Ignoring event for non-active session \(notificationSessionId ?? "nil")")
                    continue
                }

                guard let event = SessionUpdateParser.parse(notification) else { continue }
                Log.toFile("[AppState] Session event: \(event)")
                self.handleSessionEvent(event)

                if case .promptComplete = event,
                   let notificationSessionId,
                   self.historyLoadSessionIds.contains(notificationSessionId) {
                    self.historyLoadSessionIds.remove(notificationSessionId)
                    if self.historyLoadSessionIds.isEmpty {
                        self.historyLoadCleanupTask?.cancel()
                        self.historyLoadCleanupTask = nil
                    }
                }
            }
            Log.toFile("[AppState] Notification listener ended")
        }
    }

    private func shouldHandleSessionNotification(for sessionId: String?) -> Bool {
        guard let sessionId else { return true }
        if sessionId == currentSessionId { return true }

        // During/after session/load, allow source-session replay events to continue
        // until we observe prompt_complete or a fallback timeout.
        if historyLoadSessionIds.contains(sessionId) {
            return true
        }

        // During session/load, history events can be emitted for the loaded source
        // sessionId even though we're attached to a different live session.
        if isLoadingHistory {
            return historyLoadSessionIds.isEmpty
        }
        return false
    }

    private func handleSessionEvent(_ event: SessionEvent) {
        // Reset thought-streaming flag when a different event type arrives
        if case .thoughtDelta = event {} else {
            isStreamingThought = false
        }

        switch event {
        case .agentMessage(let text):
            lastAssistantMessage().content = text

        case .agentMessageDelta(let text):
            // If the last assistant message already has tool calls,
            // create a new message so text renders below tool cards.
            let msg = lastAssistantMessage()
            if !msg.toolCalls.isEmpty {
                msg.isStreaming = false
                let newMsg = ChatMessage(role: .assistant, isStreaming: isPrompting && !isLoadingHistory)
                newMsg.content = text
                messages.append(newMsg)
            } else {
                msg.content += text
            }

        case .userMessage(let text):
            if let last = messages.last, last.role == .user {
                last.content += text
            } else {
                messages.append(ChatMessage(role: .user, content: text))
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

        case .thought:
            // Suppressed — streaming thoughts into MarkdownView causes
            // heavy re-renders (blockquote re-layout) that trigger screen flicker.
            break

        case .thoughtDelta:
            break

        case .promptComplete(_):
            // Stop streaming on ALL assistant messages from this turn.
            for msg in messages where msg.role == .assistant && msg.isStreaming {
                msg.isStreaming = false
            }
            isPrompting = false
            Task { await self.refreshDaemonSessions() }
            // Force scroll regardless of isNearBottom — the final content
            // must be visible even if the anchor drifted off-screen.
            forceScrollToBottom = true
        }
        contentDidChange()
    }

    /// Notify the view that chat content changed.
    /// Uses throttle-with-trailing: fires at most every 300ms during
    /// continuous streaming, plus a trailing 150ms debounce after events stop.
    private var contentChangeTask: Task<Void, Never>?
    private var lastScrollTime = ContinuousClock.now

    private func contentDidChange() {
        contentChangeTask?.cancel()
        contentChangeTask = Task { @MainActor in
            let sinceLast = ContinuousClock.now - self.lastScrollTime
            if sinceLast < .milliseconds(300) {
                // Within max interval — debounce until quiet
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            // Past max interval or debounce completed — scroll now
            self.lastScrollTime = ContinuousClock.now
            self.contentVersion += 1
            self.contentChangeTask = nil
        }
    }

    /// Get or create the current assistant message for appending content.
    private func lastAssistantMessage() -> ChatMessage {
        if let last = messages.last, last.role == .assistant {
            return last
        }
        let msg = ChatMessage(role: .assistant, isStreaming: isPrompting && !isLoadingHistory)
        messages.append(msg)
        return msg
    }

    /// Resolve persisted session agent metadata into a usable launcher command.
    private func resolveSessionAgent(
        storedAgentID: String?,
        storedAgentCommand: String?,
        daemonCommand: String?
    ) -> (id: String, command: String) {
        let normalizedStoredCommand = normalizeOptionalAgentCommand(storedAgentCommand)
        let normalizedDaemonCommand = normalizeOptionalAgentCommand(daemonCommand)

        // Persisted metadata from the local session record has highest priority.
        if let storedAgent = AgentCommandStore.agent(forAgentID: storedAgentID) {
            return (
                storedAgent.rawValue,
                normalizedStoredCommand
                    ?? normalizedDaemonCommand
                    ?? AgentCommandStore.command(for: storedAgent)
            )
        }

        // Legacy sessions (without local metadata): prefer daemon-reported command.
        if let normalizedDaemonCommand {
            let inferred = AgentCommandStore.inferAgent(fromCommand: normalizedDaemonCommand) ?? .claude
            return (inferred.rawValue, normalizedDaemonCommand)
        }

        if let normalizedStoredCommand {
            let inferred = AgentCommandStore.inferAgent(fromCommand: normalizedStoredCommand) ?? .claude
            return (inferred.rawValue, normalizedStoredCommand)
        }

        // Final fallback for pre-agent-metadata sessions.
        return (AgentKind.claude.rawValue, AgentCommandStore.command(for: .claude))
    }

    private func normalizeAgentCommand(_ command: String?, fallback: String) -> String {
        normalizeOptionalAgentCommand(command) ?? fallback
    }

    private func normalizeOptionalAgentCommand(_ command: String?) -> String? {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Build a deduplicated list of cwd candidates for session/load.
    private func loadCwdCandidates(preferred: [String?], workspace: Workspace) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []

        func append(_ raw: String?) {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return
            }
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        for path in preferred {
            append(path)
        }
        append(workspace.path)
        for ws in workspace.node?.workspaces ?? [] {
            append(ws.path)
        }

        return candidates
    }

    /// Attempt session/load using candidate cwd paths until one succeeds.
    private func loadSessionFromCandidates(
        sessionId: String,
        routeToSessionId: String? = nil,
        candidateCwds: [String]
    ) async -> String? {
        guard let service = acpService else { return nil }
        for cwd in candidateCwds {
            do {
                try await service.loadSession(
                    sessionId: sessionId,
                    cwd: cwd,
                    routeToSessionId: routeToSessionId
                )
                return cwd
            } catch {
                Log.toFile(
                    "[AppState] session/load failed for \(sessionId) (route: \(routeToSessionId ?? "none"), cwd: \(cwd)): \(error)"
                )
                // Routing errors are terminal; cwd retries cannot fix missing attachment.
                // "Session not found" is often cwd-dependent, so keep trying candidates.
                if shouldStopSessionLoadRetries(after: error) {
                    break
                }
            }
        }
        return nil
    }

    /// Whether we should stop trying more cwd candidates for session/load.
    private func shouldStopSessionLoadRetries(after error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isNotAttached
    }

    /// Returns true when replay produced any user-visible conversation/tool output.
    private func hasRenderableConversation() -> Bool {
        messages.contains {
            guard $0.role != .system else { return false }
            if !$0.toolCalls.isEmpty { return true }
            return !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Detach the currently attached daemon session before switching to another one.
    /// Detach failures are logged but do not block the new attach flow.
    private func detachCurrentSessionIfNeeded(beforeAttaching targetSessionId: String, daemon: DaemonClient) async {
        guard let currentSessionId, currentSessionId != targetSessionId else { return }
        do {
            try await daemon.detachSession(sessionId: currentSessionId)
            Log.toFile("[AppState] Detached previous session \(currentSessionId)")
        } catch {
            Log.toFile("[AppState] Failed to detach previous session \(currentSessionId): \(error)")
        }
    }

    private func beginHistoryLoadScope(sessionIds: Set<String>) {
        historyLoadGeneration &+= 1
        historyLoadCleanupTask?.cancel()
        historyLoadCleanupTask = nil
        isLoadingHistory = true
        historyLoadSessionIds = sessionIds
    }

    private func endHistoryLoadScope() {
        isLoadingHistory = false
        guard !historyLoadSessionIds.isEmpty else { return }

        let generation = historyLoadGeneration
        historyLoadCleanupTask?.cancel()
        historyLoadCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard generation == self.historyLoadGeneration else { return }
            self.historyLoadSessionIds = []
            self.historyLoadCleanupTask = nil
        }
    }

    /// Present a concise prompt failure in chat and add actionable guidance.
    private func presentPromptError(_ error: Error) {
        let presentation = userFacingPromptError(error)
        let assistant = lastAssistantMessage()
        let errorLine = "[Error: \(presentation.inline)]"
        if assistant.content.isEmpty {
            assistant.content = errorLine
        } else {
            assistant.content += "\n\(errorLine)"
        }
        if let guidance = presentation.guidance {
            addSystemMessage(guidance)
        }
    }

    private func userFacingPromptError(_ error: Error) -> (inline: String, guidance: String?) {
        if error is CancellationError {
            return (
                "Connection interrupted while waiting for a response.",
                "Connection dropped during the request. Please resend after reconnecting."
            )
        }

        guard let acpError = error as? ACPError else {
            return (error.localizedDescription, nil)
        }

        if acpError.isModelUnavailable {
            if let requestID = acpError.backendRequestID {
                return (
                    "Model unavailable on current provider group.",
                    "Model routing failed (`model_not_found`, request id: \(requestID)). Try switching model/group, then resend."
                )
            }
            return (
                "Model unavailable on current provider group.",
                "Model routing failed (`model_not_found`). Try switching model/group, then resend."
            )
        }

        if acpError.isNotAttached {
            return (
                "Session is no longer attached.",
                "Server session detached. Re-open the session and retry."
            )
        }

        if acpError.isSessionNotFound {
            return (
                "Session not found on server.",
                "Session no longer exists remotely. Recover history or create a new session."
            )
        }

        if acpError.rpcCode == -32603 {
            return (
                "Server internal error while processing this prompt.",
                "Server returned JSON-RPC -32603. Please retry in a moment."
            )
        }

        return (acpError.errorDescription ?? error.localizedDescription, nil)
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
