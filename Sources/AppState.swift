import Foundation
import SwiftUI
import SwiftData

/// Root state coordinator connecting SSH, ACP, and UI.
@MainActor @Observable
final class AppState {
    private let chatUploadTTLHours = 24
    private let chatUploadCleanupInterval: TimeInterval = 15 * 60
    private let maxChatImageBytes = 12 * 1024 * 1024
    private static let mentionRegex = try! NSRegularExpression(pattern: #"@[A-Za-z0-9_-]+"#)

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
    /// Built-in agents whose ACP launch commands were confirmed available on the connected node.
    var availableNodeAgents: [AgentKind] = []
    /// True only when availability comes from a successful daemon probe.
    var hasReliableAgentAvailability = false

    // Chat
    var messages: [ChatMessage] = []
    var currentSessionId: String?
    var isPrompting = false
    var isCreatingSession = false
    /// True while replaying history via session/load — suppresses streaming UI.
    var isLoadingHistory = false
    /// Suspend chat list row animations while history replay may still emit events.
    var suspendChatListAnimations: Bool {
        isLoadingHistory || !historyLoadSessionIds.isEmpty
    }
    /// Incremented (debounced) when chat content changes. The view
    /// auto-scrolls only if the user is already near the bottom.
    var contentVersion = 0
    /// Set to true when the user sends a message — forces scroll
    /// to bottom regardless of current scroll position.
    var forceScrollToBottom = false
    /// True while uploading an image mention to the remote node.
    var isUploadingImage = false
    /// Trace ID for the most recent user-triggered action.
    var currentTraceId: String?

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
    /// Source sessions whose first replayed user message should be rendered as a system prompt.
    private var historySystemPromptCandidateSessionIds: Set<String> = []
    /// Source sessions currently streaming a demoted system-prompt message.
    private var historySystemPromptStreamingSessionIds: Set<String> = []
    /// Number of user-message updates seen per replayed session during history load.
    private var historyReplayUserMessageCount: [String: Int] = [:]
    /// Active demoted system-prompt message IDs keyed by replay source session.
    private var historySystemPromptMessageIdBySession: [String: UUID] = [:]
    /// Guards against concurrent `refreshDaemonSessions` calls.
    private var isRefreshingDaemonSessions = false
    /// Session-scoped uploaded image mentions.
    private var imageMentionsBySession: [String: [UploadedImageMention]] = [:]
    /// Last time we ran remote upload cleanup.
    private var lastChatUploadCleanupAt: Date?
    /// True when an unexpected transport drop should trigger auto reconnect on chat reopen.
    private var shouldAutoReconnectInterruptedSession = false
    /// Guards against overlapping reconnect+resume recovery attempts.
    private var isAutoReconnectInProgress = false
    /// Test hook for mocking the auto-reconnect connect step.
    var autoReconnectConnectHandler: ((Node) async -> Void)?
    /// Test hook for mocking the auto-reconnect resume step.
    var autoReconnectResumeHandler: ((String, ModelContext) async throws -> Void)?

    /// Uploaded image mentions available to the active chat session.
    var availableImageMentions: [UploadedImageMention] {
        guard let sessionId = currentSessionId else { return [] }
        return imageMentionsBySession[sessionId] ?? []
    }

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed
    }

    private func newTraceId() -> String {
        let traceId = UUID().uuidString.lowercased()
        currentTraceId = traceId
        return traceId
    }

    func fetchDaemonLogs(count: Int = 200, traceId: String? = nil) async throws -> [DaemonLogEntry] {
        guard let daemonClient else {
            throw AppStateError.notConnected
        }
        return try await daemonClient.fetchLogs(count: count, traceId: traceId)
    }

    var connectionStatusLabel: String {
        switch connectionStatus {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    // MARK: - Connection

    /// Connect to a node via SSH and the daemon.
    /// After this, set activeWorkspace and call createNewSession() or resumeSession() to start chatting.
    /// If already connected, tears down the old connection first.
    func connect(node: Node, isAutoReconnect: Bool = false) {
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
        if !isAutoReconnect {
            shouldAutoReconnectInterruptedSession = false
        }
        activeNode = node
        availableNodeAgents = []
        hasReliableAgentAvailability = false
        let traceId = newTraceId()

        Log.log(
            component: "AppState",
            "connect started for \(node.host):\(node.port)",
            traceId: traceId
        )

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
                let t = try await Log.timed(
                    "ssh.connect",
                    component: "AppState",
                    traceId: traceId
                ) {
                    try await sshManager.connect(params: params)
                }
                self.transport = t

                // Ensure daemon binary is installed on the server
                try await sshManager.ensureDaemonInstalled { [weak self] fraction in
                    Task { @MainActor in
                        self?.daemonUploadProgress = fraction
                    }
                }
                self.daemonUploadProgress = nil

                await performUploadCleanupIfNeeded()

                ptyTask = Task.detached { [weak self, sshManager] in
                    do {
                        if #available(macOS 15.0, iOS 18.0, *) {
                            try await sshManager.startPTY(
                                transport: t,
                                command: params.command
                            )
                        } else {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        await t.close()
                        await MainActor.run {
                            self?.markTransportInterrupted("SSH channel closed")
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        // PTY died — close the transport so the ACP client's
                        // message stream ends and pending requests are cancelled.
                        await t.close()
                        await MainActor.run {
                            self?.markTransportInterrupted("PTY closed: \(error.localizedDescription)")
                        }
                    }
                }

                // Wait for PTY to be ready before sending messages
                await t.waitUntilReady()
                Log.log(
                    component: "AppState",
                    "PTY ready, waiting for daemon/attached signal",
                    traceId: traceId
                )

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
                Log.log(component: "AppState", "daemon bridge attached", traceId: traceId)

                // ACPService is kept for sendPrompt (daemon forwards transparently)
                let service = ACPService(client: client)
                self.acpService = service

                // Initialize daemon connection with timeout
                let daemon = DaemonClient(client: client)
                let info = try await withThrowingTimeout(seconds: 30) {
                    try await Log.timed("daemon/hello", component: "AppState", traceId: traceId) {
                        try await daemon.hello(traceId: traceId)
                    }
                }
                self.daemonClient = daemon
                self.daemonSessions = info.sessions
                await self.refreshAvailableAgents()
                Log.app.info("Daemon connected: v\(info.daemonVersion), \(info.sessions.count) sessions")
                Log.log(
                    component: "AppState",
                    "daemon connected: v\(info.daemonVersion)",
                    traceId: traceId
                )

                // Start notification listener once for the entire connection.
                // Do NOT restart it per-session — AsyncStream only supports one consumer.
                startNotificationListener()

                self.connectionStatus = .connected
            } catch {
                Log.app.error("Connection error: \(error)")
                Log.log(
                    level: "error",
                    component: "AppState",
                    "connect failed: \(error.localizedDescription)",
                    traceId: traceId
                )
                self.connectionError = error.localizedDescription
                self.connectionStatus = .failed
                // Keep active node/session context on failure so retries and
                // interrupted-session recovery can reuse the current page state.
                self.clearRuntimeConnectionState()
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
        shouldAutoReconnectInterruptedSession = false
        activeWorkspace = workspace
        activeNode = workspace.node
        availableNodeAgents = []
        hasReliableAgentAvailability = false

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
                await self.refreshAvailableAgents()
                Log.toFile("[AppState] Mock daemon connected")

                startNotificationListener()

                self.connectionStatus = .connected
            } catch {
                Log.toFile("[AppState] Mock connection error: \(error)")
                self.connectionError = error.localizedDescription
                self.connectionStatus = .failed
                self.clearRuntimeConnectionState()
            }
        }
    }

    /// Refresh daemon session snapshot used by SessionPicker state badges.
    /// Concurrent calls are coalesced — if a refresh is already in flight,
    /// subsequent calls wait for it instead of issuing a duplicate request.
    func refreshDaemonSessions() async {
        guard let daemon = daemonClient else { return }
        guard !isRefreshingDaemonSessions else { return }
        isRefreshingDaemonSessions = true
        defer {
            Task { @MainActor in
                // Keep the coalescing gate for one extra turn so near-simultaneous
                // callers reuse this refresh instead of issuing a second list request.
                await Task.yield()
                self.isRefreshingDaemonSessions = false
            }
        }
        let workspaceCwd = activeWorkspace?.path
        if let updated = try? await daemon.listSessions(cwd: workspaceCwd) {
            self.daemonSessions = updated
        }
    }

    /// Probe remote ACP launch command availability for built-in agents.
    func refreshAvailableAgents() async {
        guard let daemon = daemonClient else { return }

        let previousAgents = availableNodeAgents
        let previousReliability = hasReliableAgentAvailability

        let probeRequests = AgentKind.allCases.map { agent in
            (id: agent.rawValue, command: AgentCommandStore.command(for: agent))
        }

        do {
            let results = try await daemon.probeAgents(probeRequests)
            let availableIDs = Set(results.filter(\.available).map(\.id))
            let available = AgentKind.allCases.filter { availableIDs.contains($0.rawValue) }
            self.availableNodeAgents = available
            self.hasReliableAgentAvailability = true
            Log.toFile("[AppState] Agent probe: available=\(available.map(\.rawValue).joined(separator: ","))")
        } catch {
            // Keep last known state to avoid UI flicker on transient probe failures.
            self.availableNodeAgents = previousAgents
            self.hasReliableAgentAvailability = previousReliability
            Log.toFile("[AppState] Agent probe failed, keeping previous availability: \(error)")
        }
    }

    /// Check whether a remote workspace directory exists on the active node.
    func workspaceDirectoryExists(path: String) async throws -> Bool {
        if mockTransport != nil {
            return true
        }
        guard connectionStatus == .connected else {
            throw AppStateError.notConnected
        }
        return try await sshManager.remoteDirectoryExists(path: path)
    }

    /// Create a remote workspace directory (`mkdir -p`) on the active node.
    func createWorkspaceDirectory(path: String) async throws {
        if mockTransport != nil {
            return
        }
        guard connectionStatus == .connected else {
            throw AppStateError.notConnected
        }
        try await sshManager.createRemoteDirectory(path: path)
    }

    /// Create a new ACP session via the daemon using the app's default agent.
    func createNewSession(modelContext: ModelContext) async throws {
        if !hasReliableAgentAvailability {
            let defaultAgent = AgentCommandStore.defaultAgent()
            try await createNewSession(modelContext: modelContext, agent: defaultAgent)
            return
        }
        let preferredAgent = AgentCommandStore.defaultAgent()
        if availableNodeAgents.contains(preferredAgent) {
            try await createNewSession(modelContext: modelContext, agent: preferredAgent)
            return
        }
        if let fallbackAgent = availableNodeAgents.first {
            try await createNewSession(modelContext: modelContext, agent: fallbackAgent)
            return
        }
        throw AppStateError.noAvailableAgents
    }

    /// Create a new ACP session via the daemon using a specific built-in agent.
    func createNewSession(modelContext: ModelContext, agent: AgentKind) async throws {
        guard !hasReliableAgentAvailability || availableNodeAgents.contains(agent) else {
            throw AppStateError.agentUnavailable(agent.displayName)
        }
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

        let traceId = newTraceId()

        messages = []
        let launchCommand = normalizeAgentCommand(command, fallback: AgentCommandStore.command(forAgentID: agentID))

        Log.log(component: "AppState", "creating session via daemon", traceId: traceId)
        let sessionId = try await Log.timed(
            "daemon/session.create",
            component: "AppState",
            traceId: traceId
        ) {
            try await daemon.createSession(
                cwd: workspace.path,
                command: launchCommand,
                traceId: traceId
            )
        }
        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon, traceId: traceId)
        self.currentSessionId = sessionId
        self.lastEventSeq[sessionId] = 0

        // Auto-attach to the new session
        let _ = try await Log.timed(
            "daemon/session.attach",
            component: "AppState",
            traceId: traceId,
            sessionId: sessionId
        ) {
            try await daemon.attachSession(sessionId: sessionId, lastEventSeq: 0, traceId: traceId)
        }

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

        let traceId = newTraceId()

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

        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon, traceId: traceId)

        // External sessions (not managed by daemon) go straight to history recovery.
        if daemonKnownSession?.state == "external" {
            Log.log(
                component: "AppState",
                "external session \(sessionId), recovering via session/load",
                traceId: traceId,
                sessionId: sessionId
            )
            try await resumeHistorySession(
                oldSessionId: sessionId,
                sourceSessionId: sourceSessionId,
                sourceSessionCwd: sourceSessionCwd,
                workspace: workspace,
                agentID: sessionAgent.id,
                command: sessionAgent.command,
                daemon: daemon,
                traceId: traceId,
                modelContext: modelContext
            )
            return
        }

        Log.log(component: "AppState", "attaching to session \(sessionId)", traceId: traceId, sessionId: sessionId)
        let shouldReplayFullBuffer = daemonKnownSession?.state == "idle" || daemonKnownSession?.state == "completed"
        let desiredAttachSeq = shouldReplayFullBuffer ? 0 : (lastEventSeq[sessionId] ?? 0)
        let result: DaemonAttachResult
        do {
            result = try await Log.timed(
                "daemon/session.attach",
                component: "AppState",
                traceId: traceId,
                sessionId: sessionId
            ) {
                try await daemon.attachSession(
                    sessionId: sessionId,
                    lastEventSeq: desiredAttachSeq,
                    traceId: traceId
                )
            }
        } catch {
            // Daemon doesn't know this session — recover via session/load
            Log.log(
                level: "warning",
                component: "AppState",
                "attach failed, recovering history session: \(error.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId
            )
            try await resumeHistorySession(
                oldSessionId: sessionId,
                sourceSessionId: sourceSessionId,
                sourceSessionCwd: sourceSessionCwd,
                workspace: workspace,
                agentID: sessionAgent.id,
                command: sessionAgent.command,
                daemon: daemon,
                traceId: traceId,
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
                    handleSessionEvent(event, sessionId: sessionId)
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
                    handleSessionEvent(event, sessionId: sessionId)
                }
                lastEventSeq[sessionId] = buffered.seq
            }

            let hasHistorySource = (historySessionId != nil && historySessionId != sessionId)
            let hasVisibleReplay = hasRenderableConversation()
            if !hasVisibleReplay || hasHistorySource {
                beginHistoryLoadScope(sessionIds: Set([sessionId]))
                prepareHistoryReplayTracking(for: sessionId)
                Log.toFile("[AppState] Loading history via session/load for \(sessionId)...")
                let primaryCwds = loadCwdCandidates(
                    preferred: [existingSession?.sessionCwd, daemonKnownCwd, workspace.path],
                    workspace: workspace
                )
                let loadedPrimaryCwd = await loadSessionFromCandidates(
                    sessionId: sessionId,
                    traceId: traceId,
                    candidateCwds: primaryCwds
                )

                if let loadedPrimaryCwd {
                    resolvedSessionCwd = loadedPrimaryCwd
                } else if let historySessionId, historySessionId != sessionId {
                    historyLoadSessionIds.insert(historySessionId)
                    prepareHistoryReplayTracking(for: historySessionId)
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
                        traceId: traceId,
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
        traceId: String,
        modelContext: ModelContext
    ) async throws {
        Log.log(
            component: "AppState",
            "creating new session to recover history of \(sourceSessionId)",
            traceId: traceId,
            sessionId: oldSessionId
        )

        // Create a fresh ACP process
        let launchCommand = command
        let newSessionId = try await Log.timed(
            "daemon/session.create",
            component: "AppState",
            traceId: traceId
        ) {
            try await daemon.createSession(
                cwd: workspace.path,
                command: launchCommand,
                traceId: traceId
            )
        }

        await detachCurrentSessionIfNeeded(beforeAttaching: newSessionId, daemon: daemon, traceId: traceId)

        // Attach to the new session
        let _ = try await Log.timed(
            "daemon/session.attach",
            component: "AppState",
            traceId: traceId,
            sessionId: newSessionId
        ) {
            try await daemon.attachSession(sessionId: newSessionId, lastEventSeq: 0, traceId: traceId)
        }
        self.currentSessionId = newSessionId
        self.lastEventSeq[newSessionId] = 0

        // Load old session's history into the new ACP process.
        // __routeToSession tells the daemon to forward this to the new session's ACP process,
        // while sessionId tells the ACP which conversation to load from disk.
        beginHistoryLoadScope(sessionIds: Set([sourceSessionId, newSessionId]))
        prepareHistoryReplayTracking(for: sourceSessionId)
        prepareHistoryReplayTracking(for: newSessionId)
        Log.toFile("[AppState] Loading history of \(sourceSessionId) into new session \(newSessionId)...")
        let sourceLoadCwds = loadCwdCandidates(
            preferred: [sourceSessionCwd, workspace.path],
            workspace: workspace
        )
        let loadedSourceCwd = await loadSessionFromCandidates(
            sessionId: sourceSessionId,
            routeToSessionId: newSessionId,
            traceId: traceId,
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

    /// Reconnect and restore the active chat after an unexpected transport drop.
    /// Intended to be called when ChatView reappears (for example, app foreground).
    func recoverInterruptedSessionIfNeeded(modelContext: ModelContext) async {
        guard shouldAutoReconnectInterruptedSession else { return }
        guard !isAutoReconnectInProgress else { return }
        guard connectionStatus == .disconnected || connectionStatus == .failed else { return }
        guard let node = activeNode else { return }
        guard let sessionId = currentSessionId ?? activeSession?.sessionId else { return }
        guard let workspace = activeWorkspace ?? activeSession?.workspace else { return }

        isAutoReconnectInProgress = true
        defer { isAutoReconnectInProgress = false }

        Log.log(
            component: "AppState",
            "attempting interrupted-session recovery",
            sessionId: sessionId
        )

        if let connectHandler = autoReconnectConnectHandler {
            await connectHandler(node)
        } else {
            connect(node: node, isAutoReconnect: true)
        }

        let connected: Bool
        if autoReconnectConnectHandler != nil {
            connected = connectionStatus == .connected
        } else {
            connected = await waitForConnectionResult(timeoutSeconds: 30)
        }
        guard connected else {
            shouldAutoReconnectInterruptedSession = true
            Log.log(
                level: "warning",
                component: "AppState",
                "interrupted-session recovery connect phase failed",
                sessionId: sessionId
            )
            return
        }

        // Session resume requires a workspace context.
        activeWorkspace = workspace
        do {
            if let resumeHandler = autoReconnectResumeHandler {
                try await resumeHandler(sessionId, modelContext)
            } else {
                try await resumeSession(sessionId: sessionId, modelContext: modelContext)
            }
            connectionError = nil
            shouldAutoReconnectInterruptedSession = false
        } catch {
            connectionError = error.localizedDescription
            connectionStatus = .failed
            shouldAutoReconnectInterruptedSession = true
            Log.log(
                level: "error",
                component: "AppState",
                "interrupted-session recovery failed: \(error.localizedDescription)",
                sessionId: sessionId
            )
        }
    }

    /// Mark the current chat transport as unexpectedly interrupted and preserve
    /// enough UI/session context for automatic reconnect on next page reopen.
    func markTransportInterrupted(_ errorMessage: String) {
        let hasLiveConnection = acpClient != nil || daemonClient != nil || transport != nil || mockTransport != nil
        guard hasLiveConnection || connectionStatus == .connected || connectionStatus == .connecting else {
            return
        }

        if activeWorkspace == nil {
            activeWorkspace = activeSession?.workspace
        }
        if currentSessionId == nil {
            currentSessionId = activeSession?.sessionId
        }

        connectionError = errorMessage
        connectionStatus = .disconnected
        shouldAutoReconnectInterruptedSession = activeNode != nil && currentSessionId != nil
        isAutoReconnectInProgress = false
        clearRuntimeConnectionState()
    }

    private func clearRuntimeConnectionState() {
        let client = acpClient
        let t = transport
        let mt = mockTransport
        let sshManager = self.sshManager

        notificationTask?.cancel()
        ptyTask?.cancel()
        historyLoadCleanupTask?.cancel()
        historyLoadCleanupTask = nil
        acpClient = nil
        acpService = nil
        daemonClient = nil
        transport = nil
        mockTransport = nil
        daemonSessions = []
        daemonUploadProgress = nil
        currentTraceId = nil
        isPrompting = false
        isCreatingSession = false
        isLoadingHistory = false
        isUploadingImage = false
        isRefreshingDaemonSessions = false
        availableNodeAgents = []
        hasReliableAgentAvailability = false
        historyLoadSessionIds = []
        historyLoadGeneration = 0
        historySystemPromptCandidateSessionIds = []
        historySystemPromptStreamingSessionIds = []
        historyReplayUserMessageCount = [:]
        historySystemPromptMessageIdBySession = [:]
        for msg in messages where msg.isStreaming {
            msg.isStreaming = false
        }

        Task.detached {
            if let client { await client.stop() }
            if let t { await t.close() }
            if let mt { await mt.close() }
            await sshManager.disconnect()
        }
    }

    private func waitForConnectionResult(timeoutSeconds: TimeInterval) async -> Bool {
        let timeout = max(timeoutSeconds, 1)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch connectionStatus {
            case .connected:
                return true
            case .failed:
                return false
            case .connecting, .disconnected:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return connectionStatus == .connected
    }

    func disconnect() {
        cleanupConnection()
        shouldPopToRoot = true
    }

    /// Tear down the current connection and reset navigation/chat context.
    private func cleanupConnection() {
        shouldAutoReconnectInterruptedSession = false
        isAutoReconnectInProgress = false
        clearRuntimeConnectionState()
        connectionStatus = .disconnected
        currentSessionId = nil
        activeSession = nil
        activeNode = nil
        activeWorkspace = nil
        messages = []
        imageMentionsBySession = [:]
        lastChatUploadCleanupAt = nil
    }

    // MARK: - Chat

    /// Upload a local image to the connected server and register an @mention alias.
    @discardableResult
    func uploadImageMention(
        data: Data,
        mimeType: String,
        fileExtension: String,
        originalFilename: String? = nil
    ) async -> UploadedImageMention? {
        guard let sessionId = currentSessionId else {
            addSystemMessage("Please start a session before attaching images")
            return nil
        }
        guard !isUploadingImage else {
            addSystemMessage("Image upload already in progress")
            return nil
        }
        guard !data.isEmpty else {
            addSystemMessage("Image data is empty")
            return nil
        }
        guard data.count <= maxChatImageBytes else {
            let maxMB = maxChatImageBytes / (1024 * 1024)
            addSystemMessage("Image too large (\(data.count / (1024 * 1024))MB). Limit is \(maxMB)MB.")
            return nil
        }

        // Mock mode: skip SSH and register an in-memory mention directly.
        if mockTransport != nil {
            let mentionName = generateMentionName(for: sessionId)
            let filename = "\(mentionName).\(fileExtension)"
            let remotePath = "/mock/.opencan/uploads/\(sessionId)/\(filename)"
            let mention = UploadedImageMention(
                sessionId: sessionId,
                mentionName: mentionName,
                remotePath: remotePath,
                uri: fileURIString(forRemotePath: remotePath),
                mimeType: mimeType,
                sizeBytes: data.count,
                originalFilename: originalFilename,
                createdAt: Date()
            )
            var mentions = imageMentionsBySession[sessionId] ?? []
            mentions.append(mention)
            imageMentionsBySession[sessionId] = mentions
            return mention
        }

        isUploadingImage = true
        defer { isUploadingImage = false }

        do {
            await performUploadCleanupIfNeeded()

            let upload = try await sshManager.uploadChatImage(
                sessionId: sessionId,
                data: data,
                fileExtension: fileExtension
            )
            let mentionName = generateMentionName(for: sessionId)
            let mention = UploadedImageMention(
                sessionId: sessionId,
                mentionName: mentionName,
                remotePath: upload.remotePath,
                uri: upload.fileURI,
                mimeType: mimeType,
                sizeBytes: upload.sizeBytes,
                originalFilename: originalFilename,
                createdAt: Date()
            )
            var mentions = imageMentionsBySession[sessionId] ?? []
            mentions.append(mention)
            imageMentionsBySession[sessionId] = mentions
            Log.toFile("[AppState] Uploaded image mention \(mention.mentionToken) -> \(upload.remotePath)")
            return mention
        } catch {
            Log.toFile("[AppState] Image upload failed: \(error)")
            addSystemMessage("Image upload failed: \(error.localizedDescription)")
            return nil
        }
    }

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
        let promptTarget = resolvePromptTargetSession(daemonSessionId: sessionId)

        let mentionTokens = extractMentionTokens(in: text)
        let referencedMentions = resolveMentionedImages(in: text, sessionId: sessionId)
        let resolvedTokenSet = Set(referencedMentions.map(\.mentionToken))
        let unresolvedTokens = mentionTokens.filter { !resolvedTokenSet.contains($0) }
        if !unresolvedTokens.isEmpty {
            addSystemMessage("Unknown image mention(s): \(unresolvedTokens.joined(separator: ", "))")
        }

        var promptBlocks: [PromptBlock] = [.text(text)]
        promptBlocks.append(contentsOf: referencedMentions.map { .resourceLink($0.promptResourceLink) })

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

        let traceId = newTraceId()
        Log.log(
            component: "AppState",
            "sendMessage dispatching prompt, resourceLinks=\(referencedMentions.count), promptSessionId=\(promptTarget.sessionId), routeToSessionId=\(promptTarget.routeToSessionId ?? "none")",
            traceId: traceId,
            sessionId: sessionId
        )

        Task {
            do {
                let _ = try await Log.timed(
                    "session/prompt",
                    component: "AppState",
                    traceId: traceId,
                    sessionId: sessionId
                ) {
                    try await service.sendPrompt(
                        sessionId: promptTarget.sessionId,
                        prompt: promptBlocks,
                        routeToSessionId: promptTarget.routeToSessionId,
                        traceId: traceId
                    )
                }
                Log.log(component: "AppState", "sendPrompt returned", traceId: traceId, sessionId: sessionId)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
            } catch {
                Log.log(
                    level: "error",
                    component: "AppState",
                    "sendPrompt error: \(error.localizedDescription)",
                    traceId: traceId,
                    sessionId: sessionId
                )
                self.presentPromptError(error)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
            }
        }
    }

    /// Resolve ACP prompt routing for recovered sessions.
    /// When a daemon session is recovered via `session/load`, prompts should
    /// continue targeting the original history session and route through the
    /// currently attached daemon session.
    private func resolvePromptTargetSession(daemonSessionId: String) -> (sessionId: String, routeToSessionId: String?) {
        guard let sourceSessionId = activeSession?.historySessionId,
              sourceSessionId != daemonSessionId else {
            return (daemonSessionId, nil)
        }
        return (sourceSessionId, daemonSessionId)
    }

    private func generateMentionName(for sessionId: String) -> String {
        let existing = Set((imageMentionsBySession[sessionId] ?? []).map(\.mentionName))
        for _ in 0..<100 {
            let suffix = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(6)
                .lowercased()
            let candidate = "img_\(suffix)"
            if !existing.contains(candidate) {
                return candidate
            }
        }
        return "img_\(Int(Date().timeIntervalSince1970))"
    }

    private func extractMentionTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var tokens: [String] = []
        var seen = Set<String>()
        Self.mentionRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let token = String(text[r])
            if seen.insert(token).inserted {
                tokens.append(token)
            }
        }
        return tokens
    }

    private func resolveMentionedImages(in text: String, sessionId: String) -> [UploadedImageMention] {
        let mentions = imageMentionsBySession[sessionId] ?? []
        guard !mentions.isEmpty else { return [] }
        let byToken = Dictionary(
            mentions.map { ($0.mentionToken, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return extractMentionTokens(in: text).compactMap { byToken[$0] }
    }

    private func fileURIString(forRemotePath remotePath: String) -> String {
        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        return "file://\(encodedPath)"
    }

    private func performUploadCleanupIfNeeded() async {
        let now = Date()
        if let last = lastChatUploadCleanupAt,
           now.timeIntervalSince(last) < chatUploadCleanupInterval {
            return
        }
        do {
            try await sshManager.cleanupExpiredChatUploads(ttlHours: chatUploadTTLHours)
            lastChatUploadCleanupAt = now
        } catch {
            Log.toFile("[AppState] Skipped chat upload cleanup: \(error)")
        }
    }

    /// Delete the current session if it has no user-visible content.
    /// Called when leaving ChatView so accidental empty sessions don't pollute the list.
    func discardEmptyActiveSessionIfNeeded(modelContext: ModelContext) async {
        guard let session = activeSession else { return }
        guard shouldDiscardEmptySession(session) else { return }

        let sessionId = session.sessionId
        Log.toFile("[AppState] Discarding empty session \(sessionId)")

        if let daemon = daemonClient {
            if currentSessionId == sessionId {
                do {
                    try await daemon.detachSession(sessionId: sessionId)
                } catch {
                    Log.toFile("[AppState] Failed to detach empty session \(sessionId): \(error)")
                }
            }
            do {
                try await daemon.killSession(sessionId: sessionId)
            } catch {
                Log.toFile("[AppState] Failed to kill empty session \(sessionId): \(error)")
            }
        }

        modelContext.delete(session)
        try? modelContext.save()

        if currentSessionId == sessionId {
            currentSessionId = nil
            messages = []
        }
        if activeSession?.persistentModelID == session.persistentModelID {
            activeSession = nil
        }
        lastEventSeq.removeValue(forKey: sessionId)

        await refreshDaemonSessions()
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
                self.handleSessionEvent(event, sessionId: notificationSessionId)

                if case .promptComplete = event,
                   let notificationSessionId,
                   self.historyLoadSessionIds.contains(notificationSessionId) {
                    self.historyLoadSessionIds.remove(notificationSessionId)
                    self.clearHistoryReplayTracking(for: notificationSessionId)
                    if self.historyLoadSessionIds.isEmpty {
                        self.historyLoadCleanupTask?.cancel()
                        self.historyLoadCleanupTask = nil
                    }
                }
            }
            Log.toFile("[AppState] Notification listener ended")
            if !Task.isCancelled {
                self.markTransportInterrupted(self.connectionError ?? "SSH connection interrupted")
            }
        }
    }

    private func shouldHandleSessionNotification(for sessionId: String?) -> Bool {
        guard let sessionId else { return true }
        if activeSessionNotificationIDs().contains(sessionId) { return true }

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

    /// Notification session IDs that belong to the currently active chat.
    /// Recovered chats can emit updates under the original history session ID.
    private func activeSessionNotificationIDs() -> Set<String> {
        guard let currentSessionId else { return [] }
        var ids: Set<String> = [currentSessionId]
        if let sourceSessionId = activeSession?.historySessionId,
           sourceSessionId != currentSessionId {
            ids.insert(sourceSessionId)
        }
        return ids
    }

    private func handleSessionEvent(_ event: SessionEvent, sessionId: String? = nil) {
        // Reset thought-streaming flag when a different event type arrives
        if case .thoughtDelta = event {} else {
            isStreamingThought = false
        }
        if case .userMessage = event {} else if let sessionId {
            historySystemPromptStreamingSessionIds.remove(sessionId)
            historySystemPromptMessageIdBySession.removeValue(forKey: sessionId)
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
            if let sessionId,
               shouldRenderHistoryUserMessageAsSystem(text: text, sessionId: sessionId) {
                appendHistorySystemPromptChunk(text, sessionId: sessionId)
                break
            }
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

    private func shouldRenderHistoryUserMessageAsSystem(text: String, sessionId: String) -> Bool {
        guard historyLoadSessionIds.contains(sessionId) || isLoadingHistory else {
            return false
        }

        if historySystemPromptStreamingSessionIds.contains(sessionId) {
            return true
        }

        let count = historyReplayUserMessageCount[sessionId, default: 0]
        historyReplayUserMessageCount[sessionId] = count + 1
        guard count == 0 else { return false }

        if historySystemPromptCandidateSessionIds.contains(sessionId)
            || looksLikeAgentBootstrapPrompt(text) {
            historySystemPromptStreamingSessionIds.insert(sessionId)
            return true
        }

        return false
    }

    private func appendHistorySystemPromptChunk(_ text: String, sessionId: String) {
        if let messageID = historySystemPromptMessageIdBySession[sessionId],
           let existing = messages.first(where: { $0.id == messageID }) {
            existing.content += text
            return
        }

        let message = ChatMessage(role: .system, content: text)
        messages.append(message)
        historySystemPromptMessageIdBySession[sessionId] = message.id
    }

    private func looksLikeAgentBootstrapPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 180 else { return false }

        let lower = trimmed.lowercased()
        let startsLikePrompt = lower.hasPrefix("you are ")
            || lower.hasPrefix("you are \"")
            || lower.hasPrefix("system prompt")
        let hasInstructionStructure = trimmed.contains("\n## ")
            || lower.contains("who you are")
            || lower.contains("you are not")
            || lower.contains("long-running")
        return startsLikePrompt && hasInstructionStructure
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
        traceId: String? = nil,
        candidateCwds: [String]
    ) async -> String? {
        guard let service = acpService else { return nil }
        for cwd in candidateCwds {
            do {
                try await Log.timed(
                    "session/load",
                    component: "AppState",
                    traceId: traceId,
                    sessionId: routeToSessionId ?? sessionId
                ) {
                    try await service.loadSession(
                        sessionId: sessionId,
                        cwd: cwd,
                        routeToSessionId: routeToSessionId,
                        traceId: traceId
                    )
                }
                return cwd
            } catch {
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "session/load failed for \(sessionId) (route: \(routeToSessionId ?? "none"), cwd: \(cwd)): \(error.localizedDescription)",
                    traceId: traceId,
                    sessionId: routeToSessionId ?? sessionId
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

    private func shouldDiscardEmptySession(_ session: Session) -> Bool {
        guard !isPrompting else { return false }
        guard !isLoadingHistory else { return false }
        guard hasRenderableConversation() == false else { return false }

        let hasLocalTitle = !(session.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !hasLocalTitle else { return false }

        guard let daemonSession = daemonSessions.first(where: { $0.sessionId == session.sessionId }) else {
            return true
        }

        let state = daemonSession.state
        if state == "starting" || state == "prompting" || state == "draining" || state == "external" {
            return false
        }
        if daemonSession.lastEventSeq > 0 {
            return false
        }
        let hasDaemonTitle = !(daemonSession.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return !hasDaemonTitle
    }

    /// Detach the currently attached daemon session before switching to another one.
    /// Detach failures are logged but do not block the new attach flow.
    private func detachCurrentSessionIfNeeded(
        beforeAttaching targetSessionId: String,
        daemon: DaemonClient,
        traceId: String? = nil
    ) async {
        guard let currentSessionId, currentSessionId != targetSessionId else { return }
        do {
            try await daemon.detachSession(sessionId: currentSessionId, traceId: traceId)
            Log.log(
                component: "AppState",
                "detached previous session \(currentSessionId)",
                traceId: traceId,
                sessionId: currentSessionId
            )
        } catch {
            Log.log(
                level: "warning",
                component: "AppState",
                "failed to detach previous session \(currentSessionId): \(error.localizedDescription)",
                traceId: traceId,
                sessionId: currentSessionId
            )
        }
    }

    private func beginHistoryLoadScope(sessionIds: Set<String>) {
        historyLoadGeneration &+= 1
        historyLoadCleanupTask?.cancel()
        historyLoadCleanupTask = nil
        isLoadingHistory = true
        historyLoadSessionIds = sessionIds
        historySystemPromptCandidateSessionIds = []
        historySystemPromptStreamingSessionIds = []
        historyReplayUserMessageCount = [:]
        historySystemPromptMessageIdBySession = [:]
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
            self.historySystemPromptCandidateSessionIds = []
            self.historySystemPromptStreamingSessionIds = []
            self.historyReplayUserMessageCount = [:]
            self.historySystemPromptMessageIdBySession = [:]
            self.historyLoadCleanupTask = nil
        }
    }

    private func prepareHistoryReplayTracking(for sessionId: String) {
        historyReplayUserMessageCount[sessionId] = 0
        if sessionId.hasPrefix("agent-") {
            historySystemPromptCandidateSessionIds.insert(sessionId)
        }
    }

    private func clearHistoryReplayTracking(for sessionId: String) {
        historySystemPromptCandidateSessionIds.remove(sessionId)
        historySystemPromptStreamingSessionIds.remove(sessionId)
        historyReplayUserMessageCount.removeValue(forKey: sessionId)
        historySystemPromptMessageIdBySession.removeValue(forKey: sessionId)
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
    case noAvailableAgents
    case agentUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a workspace"
        case .timeout: "Connection timed out — server did not respond"
        case .noAvailableAgents: "No available ACP agents on this node"
        case .agentUnavailable(let displayName): "\(displayName) is not available on this node"
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
