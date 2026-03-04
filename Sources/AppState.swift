import Foundation
import SwiftUI
import SwiftData

/// Root state coordinator connecting SSH, ACP, and UI.
@MainActor @Observable
final class AppState {
    private let chatUploadTTLHours = 24
    private let chatUploadCleanupInterval: TimeInterval = 15 * 60
    private let maxChatImageBytes = 12 * 1024 * 1024
    /// Stable per-install ID used to reclaim daemon session ownership after reconnect.
    private let daemonAttachClientID = AppState.loadOrCreateDaemonAttachClientID()
    /// Fallback timeout when session/prompt never returns a terminal response.
    private(set) var promptResponseTimeoutSeconds: TimeInterval = 45
    /// Absolute cap for unresolved prompts to avoid hanging forever on stale daemon state.
    private(set) var promptResponseMaxWaitSeconds: TimeInterval = 15 * 60
    /// Poll cadence while waiting for terminal `session/prompt` response.
    private let promptResponsePollIntervalSeconds: TimeInterval = 1
    /// Per-attempt timeout for `session/load` so resume never waits forever.
    private(set) var sessionLoadTimeoutSeconds: TimeInterval = 12
    private static let mentionRegex = try! NSRegularExpression(pattern: #"@[A-Za-z0-9_-]+"#)
    private static let daemonAttachClientIDDefaultsKey = "opencan.daemonAttachClientID"

    private static func loadOrCreateDaemonAttachClientID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: daemonAttachClientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: daemonAttachClientIDDefaultsKey)
        return generated
    }

    /// Test-only knob for prompt watchdog timings.
    func configurePromptTimeoutsForTesting(
        responseTimeoutSeconds: TimeInterval,
        maxWaitSeconds: TimeInterval? = nil
    ) {
        promptResponseTimeoutSeconds = responseTimeoutSeconds
        if let maxWaitSeconds {
            promptResponseMaxWaitSeconds = maxWaitSeconds
        }
    }

    /// Test-only knob for `session/load` timeout.
    func configureSessionLoadTimeoutForTesting(seconds: TimeInterval) {
        sessionLoadTimeoutSeconds = max(0.05, seconds)
    }

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
    /// Extra session IDs accepted by the notification listener during
    /// temporary history replay flows (for example, external takeover).
    private var temporaryNotificationSessionIDs: Set<String> = []
    /// Suspend chat list row animations while replaying history.
    var suspendChatListAnimations: Bool { isLoadingHistory }
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
    /// Last observed prompt-related activity timestamp per session.
    private var promptLastActivityAt: [String: Date] = [:]
    /// Per-session event sequence tracking for daemon replay.
    private var lastEventSeq: [String: UInt64] = [:]
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

        let privateKeyPEM: Data
        let jumpKeyPEM: Data?
        do {
            privateKeyPEM = try key.privateKeyDataForConnection()
            if let jumpKey = node.jumpServer?.sshKey {
                jumpKeyPEM = try jumpKey.privateKeyDataForConnection()
            } else {
                jumpKeyPEM = nil
            }
        } catch {
            connectionError = "Failed to load SSH key: \(error.localizedDescription)"
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

        let params = SSHConnectionManager.ConnectionParams(
            host: node.host,
            port: node.port,
            username: node.username,
            privateKeyPEM: privateKeyPEM,
            // Force raw TTY mode before attach so large JSON-RPC lines are not
            // mangled by line discipline (which leads to daemon-side parse errors).
            command: "stty raw -echo -icrnl -inlcr -ixon -ixoff 2>/dev/null || true; exec ~/.opencan/bin/opencan-daemon attach",
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
        // Fetch unscoped session snapshots to avoid false negatives from daemon-side
        // cwd scoping (path aliases/normalization may differ by client environment).
        // SessionPicker still filters rows by workspace path on the UI side.
        if let updated = try? await daemon.listSessions() {
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
        settlePromptingStateForSessionSwitch(clearMessages: false)
        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon, traceId: traceId)

        // Auto-attach to the new session
        let _ = try await Log.timed(
            "daemon/session.attach",
            component: "AppState",
            traceId: traceId,
            sessionId: sessionId
        ) {
            try await daemon.attachSession(
                sessionId: sessionId,
                lastEventSeq: 0,
                clientId: daemonAttachClientID,
                traceId: traceId
            )
        }
        self.currentSessionId = sessionId
        self.lastEventSeq[sessionId] = 0
        settlePromptingStateForSessionSwitch(clearMessages: true)

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

    /// Resume an existing session via daemon attach and history replay.
    /// Missing managed ownership falls back to external takeover recovery.
    func resumeSession(sessionId: String, modelContext: ModelContext) async throws {
        guard let daemon = daemonClient,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        let traceId = newTraceId()

        if let externalDaemonSession = daemonSessions.first(where: { $0.sessionId == sessionId }),
           externalDaemonSession.state == "external",
           let mappedManagedSession = mappedManagedSessionForExternal(
               externalSessionId: sessionId,
               workspace: workspace,
               modelContext: modelContext
           ),
           mappedManagedSession.sessionId != sessionId,
           let mappedDaemonSession = daemonSessions.first(where: { $0.sessionId == mappedManagedSession.sessionId }),
           mappedDaemonSession.state != "dead",
           mappedDaemonSession.state != "external" {
            Log.log(
                component: "AppState",
                "redirecting external session \(sessionId) to existing managed session \(mappedManagedSession.sessionId)",
                traceId: traceId,
                sessionId: sessionId
            )
            try await resumeSession(sessionId: mappedManagedSession.sessionId, modelContext: modelContext)
            return
        }

        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let existingSession = try? modelContext.fetch(sessionDescriptor).first
        let daemonKnownSession = daemonSessions.first(where: { $0.sessionId == sessionId })
        let daemonKnownCwd = daemonKnownSession?.cwd
        let daemonKnownCommand = daemonKnownSession?.command
        let sessionAgent = resolveSessionAgent(
            storedAgentID: existingSession?.agentID,
            storedAgentCommand: existingSession?.agentCommand,
            daemonCommand: daemonKnownCommand
        )

        // If the user exits ChatView and re-enters the same live session without
        // disconnecting, reuse in-memory transcript/state directly.
        if currentSessionId == sessionId,
           activeSession?.sessionId == sessionId,
           !messages.isEmpty {
            if let existing = existingSession {
                existing.lastUsedAt = Date()
                existing.sessionCwd = daemonKnownCwd ?? existing.sessionCwd ?? workspace.path
                existing.agentID = existing.agentID ?? sessionAgent.id
                existing.agentCommand = normalizeAgentCommand(
                    existing.agentCommand,
                    fallback: sessionAgent.command
                )
                activeSession = existing
                try? modelContext.save()
            }
            Log.log(
                component: "AppState",
                "reusing in-memory transcript for active session \(sessionId)",
                traceId: traceId,
                sessionId: sessionId
            )
            return
        }

        let previousSessionId = currentSessionId
        let previousSessionAttachSeq: UInt64 = {
            guard let previousSessionId else { return 0 }
            return lastEventSeq[previousSessionId] ?? 0
        }()
        settlePromptingStateForSessionSwitch(clearMessages: false)

        // External sessions are discovered from ACP but not owned by this daemon.
        if daemonKnownSession?.state == "external" {
            try await takeOverExternalSession(
                externalSessionId: sessionId,
                externalSessionCwd: daemonKnownCwd ?? existingSession?.sessionCwd ?? workspace.path,
                workspace: workspace,
                agentID: sessionAgent.id,
                command: sessionAgent.command,
                daemon: daemon,
                traceId: traceId,
                modelContext: modelContext,
                previousSessionId: previousSessionId,
                previousSessionAttachSeq: previousSessionAttachSeq
            )
            return
        }

        await detachCurrentSessionIfNeeded(beforeAttaching: sessionId, daemon: daemon, traceId: traceId)

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
                try await attachSessionWithRetryIfNeeded(
                    daemon: daemon,
                    sessionId: sessionId,
                    lastEventSeq: desiredAttachSeq,
                    traceId: traceId
                )
            }
        } catch {
            if shouldTreatAttachFailureAsOwnershipConflict(error) {
                await restorePreviousAttachmentIfNeeded(
                    previousSessionId: previousSessionId,
                    previousSessionAttachSeq: previousSessionAttachSeq,
                    failedTargetSessionId: sessionId,
                    daemon: daemon,
                    traceId: traceId
                )
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "attach rejected by active owner",
                    traceId: traceId,
                    sessionId: sessionId
                )
                throw AppStateError.sessionAttachedByAnotherClient(sessionId)
            }

            if shouldTreatAttachFailureAsSessionMissing(error) {
                let takeoverSessionReference = existingSession?.canonicalSessionId ?? sessionId
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "attach reported missing session, attempting takeover recovery",
                    traceId: traceId,
                    sessionId: sessionId
                )
                do {
                    try await takeOverExternalSession(
                        externalSessionId: takeoverSessionReference,
                        externalSessionCwd: daemonKnownCwd ?? existingSession?.sessionCwd ?? workspace.path,
                        workspace: workspace,
                        agentID: sessionAgent.id,
                        command: sessionAgent.command,
                        daemon: daemon,
                        traceId: traceId,
                        modelContext: modelContext,
                        previousSessionId: previousSessionId,
                        previousSessionAttachSeq: previousSessionAttachSeq
                    )
                    return
                } catch {
                    await restorePreviousAttachmentIfNeeded(
                        previousSessionId: previousSessionId,
                        previousSessionAttachSeq: previousSessionAttachSeq,
                        failedTargetSessionId: sessionId,
                        daemon: daemon,
                        traceId: traceId
                    )
                    markSessionDead(sessionId: sessionId, modelContext: modelContext)
                    throw AppStateError.sessionNotRecoverable(takeoverSessionReference)
                }
            }

            await restorePreviousAttachmentIfNeeded(
                previousSessionId: previousSessionId,
                previousSessionAttachSeq: previousSessionAttachSeq,
                failedTargetSessionId: sessionId,
                daemon: daemon,
                traceId: traceId
            )
            Log.log(
                level: "error",
                component: "AppState",
                "attach failed: \(error.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId
            )
            throw error
        }

        self.currentSessionId = sessionId
        settlePromptingStateForSessionSwitch(clearMessages: true)

        let isRunning = result.state == "prompting" || result.state == "draining"
        var resolvedSessionCwd = daemonKnownCwd ?? existingSession?.sessionCwd ?? workspace.path
        var didAttemptHistoryBackfill = false
        var didSucceedHistoryBackfill = false
        var didObserveHistoryNotFound = false

        if isRunning {
            // Running session: replay daemon buffer first. In-flight prompts can
            // keep ACP busy and block concurrent session/load for a long time,
            // so we only run blocking load backfill when replay produced no
            // renderable transcript.
            isPrompting = true
            for buffered in result.bufferedEvents {
                if let event = SessionUpdateParser.parse(buffered.event) {
                    handleSessionEvent(event, sessionId: sessionId)
                }
                lastEventSeq[sessionId] = buffered.seq
            }

            let hasVisibleReplay = hasRenderableConversation()
            if !hasVisibleReplay {
                isLoadingHistory = true
                defer { isLoadingHistory = false }
                Log.toFile("[AppState] Loading history via session/load for running session \(sessionId)...")
                let primaryCwds = loadCwdCandidates(
                    preferred: [existingSession?.sessionCwd, daemonKnownCwd, workspace.path],
                    workspace: workspace
                )
                let primaryLoadResult = await loadSessionFromCandidates(
                    sessionId: sessionId,
                    traceId: traceId,
                    candidateCwds: primaryCwds
                )
                didAttemptHistoryBackfill = true
                didObserveHistoryNotFound = primaryLoadResult.sawNotFound
                if let loadedPrimaryCwd = primaryLoadResult.loadedCwd {
                    didSucceedHistoryBackfill = true
                    resolvedSessionCwd = loadedPrimaryCwd
                }
            } else {
                Log.toFile(
                    "[AppState] Resumed running session \(sessionId) via buffered replay (\(result.bufferedEvents.count) events), skipping blocking session/load"
                )
            }

            // Always clear isPrompting after resume to avoid locking input.
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

            let hasVisibleReplay = hasRenderableConversation()
            if !hasVisibleReplay {
                isLoadingHistory = true
                defer { isLoadingHistory = false }
                Log.toFile("[AppState] Loading history via session/load for \(sessionId)...")
                let primaryCwds = loadCwdCandidates(
                    preferred: [existingSession?.sessionCwd, daemonKnownCwd, workspace.path],
                    workspace: workspace
                )
                let primaryLoadResult = await loadSessionFromCandidates(
                    sessionId: sessionId,
                    traceId: traceId,
                    candidateCwds: primaryCwds
                )
                didAttemptHistoryBackfill = true
                didObserveHistoryNotFound = primaryLoadResult.sawNotFound
                if let loadedPrimaryCwd = primaryLoadResult.loadedCwd {
                    didSucceedHistoryBackfill = true
                    resolvedSessionCwd = loadedPrimaryCwd
                }
            } else {
                Log.toFile(
                    "[AppState] Resumed \(sessionId) via buffered replay (\(result.bufferedEvents.count) events), skipping session/load"
                )
            }
            // Ensure no stale streaming indicators
            for msg in messages where msg.isStreaming {
                msg.isStreaming = false
            }
        }

        // Find or create local Session record
        if let existing = existingSession {
            existing.lastUsedAt = Date()
            existing.sessionCwd = resolvedSessionCwd
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
        } else if didAttemptHistoryBackfill && !didSucceedHistoryBackfill {
            statusMsg = didObserveHistoryNotFound
                ? "Session resumed (history unavailable)"
                : "Session resumed (history load failed)"
        } else {
            statusMsg = "Session resumed"
        }
        addSystemMessage(statusMsg)

        await refreshDaemonSessions()

        if !result.bufferedEvents.isEmpty && isRunning {
            Log.toFile("[AppState] Replayed \(result.bufferedEvents.count) buffered events")
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
        acpClient = nil
        acpService = nil
        daemonClient = nil
        transport = nil
        mockTransport = nil
        daemonSessions = []
        daemonUploadProgress = nil
        currentTraceId = nil
        isPrompting = false
        clearAllPromptActivity()
        isCreatingSession = false
        isLoadingHistory = false
        isUploadingImage = false
        isRefreshingDaemonSessions = false
        availableNodeAgents = []
        hasReliableAgentAvailability = false
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

    @discardableResult
    func sendMessage(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard !isPrompting else {
            Log.toFile("[AppState] sendMessage blocked — isPrompting=true, currentSessionId=\(currentSessionId ?? "nil")")
            addSystemMessage("Still waiting for response...")
            return false
        }
        guard let service = acpService,
              let sessionId = currentSessionId else {
            addSystemMessage("Not connected — please reconnect")
            return false
        }
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
        markPromptActivity(for: sessionId)
        forceScrollToBottom = true

        let traceId = newTraceId()
        Log.log(
            component: "AppState",
            "sendMessage dispatching prompt, resourceLinks=\(referencedMentions.count), promptSessionId=\(sessionId)",
            traceId: traceId,
            sessionId: sessionId
        )

        Task {
            let timeoutSeconds = self.promptResponseTimeoutSeconds
            do {
                let _ = try await Log.timed(
                    "session/prompt",
                    component: "AppState",
                    traceId: traceId,
                    sessionId: sessionId
                ) {
                    try await self.sendPromptAwaitingTerminalResponse(
                        service: service,
                        sessionId: sessionId,
                        prompt: promptBlocks,
                        monitorSessionId: sessionId,
                        traceId: traceId,
                        inactivityTimeoutSeconds: timeoutSeconds
                    )
                }
                let promptStillActive = self.isPrompting && self.currentSessionId == sessionId
                guard promptStillActive else {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "sendPrompt returned after prompt already settled",
                        traceId: traceId,
                        sessionId: sessionId
                    )
                    return
                }
                Log.log(component: "AppState", "sendPrompt returned", traceId: traceId, sessionId: sessionId)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
                self.clearPromptActivity(for: sessionId)
            } catch {
                let normalizedError = self.normalizePromptSendError(error, timeoutSeconds: timeoutSeconds)
                let promptStillActive = self.isPrompting && self.currentSessionId == sessionId
                guard promptStillActive else {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "sendPrompt finished after prompt already settled: \(normalizedError.localizedDescription)",
                        traceId: traceId,
                        sessionId: sessionId
                    )
                    return
                }
                Log.log(
                    level: "error",
                    component: "AppState",
                    "sendPrompt error: \(normalizedError.localizedDescription)",
                    traceId: traceId,
                    sessionId: sessionId
                )
                self.presentPromptError(normalizedError)
                for msg in self.messages where msg.role == .assistant && msg.isStreaming {
                    msg.isStreaming = false
                }
                self.isPrompting = false
                self.clearPromptActivity(for: sessionId)
                self.forceScrollToBottom = true
                Task { await self.refreshDaemonSessions() }
            }
        }
        return true
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

                // Track __seq only for notifications that are actually accepted.
                if case .notification(_, let params) = notification,
                   let seq = params?["__seq"]?.intValue,
                   let notificationSessionId {
                    self.lastEventSeq[notificationSessionId] = UInt64(seq)
                }

                guard let event = SessionUpdateParser.parse(notification) else { continue }
                Log.toFile("[AppState] Session event: \(event)")
                self.handleSessionEvent(event, sessionId: notificationSessionId)
            }
            Log.toFile("[AppState] Notification listener ended")
            if !Task.isCancelled {
                self.markTransportInterrupted(self.connectionError ?? "SSH connection interrupted")
            }
        }
    }

    private func shouldHandleSessionNotification(for sessionId: String?) -> Bool {
        guard let sessionId else { return true }
        return activeSessionNotificationIDs().contains(sessionId)
    }

    /// Notification session IDs that belong to the currently active chat.
    private func activeSessionNotificationIDs() -> Set<String> {
        var ids = temporaryNotificationSessionIDs
        if let currentSessionId {
            ids.insert(currentSessionId)
        }
        return ids
    }

    private func handleSessionEvent(_ event: SessionEvent, sessionId: String? = nil) {
        if let sessionId, isPrompting {
            markPromptActivity(for: sessionId)
        }

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
            if let sessionId {
                clearPromptActivity(for: sessionId)
            } else if let currentSessionId {
                clearPromptActivity(for: currentSessionId)
            }
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

    /// Resolve a previously recovered managed session for an external history id.
    /// Returns the most recently used local mapping in the same workspace.
    private func mappedManagedSessionForExternal(
        externalSessionId: String,
        workspace: Workspace,
        modelContext: ModelContext
    ) -> Session? {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.canonicalSessionId == externalSessionId }
        )
        guard let mapped = try? modelContext.fetch(descriptor), !mapped.isEmpty else {
            return nil
        }
        let workspaceID = workspace.persistentModelID
        return mapped
            .filter { $0.workspace?.persistentModelID == workspaceID }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .first
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
        traceId: String? = nil,
        candidateCwds: [String]
    ) async -> SessionLoadResult {
        guard let service = acpService else {
            return SessionLoadResult(loadedCwd: nil, sawNotFound: false, lastError: nil)
        }
        var sawNotFound = false
        var lastError: Error?
        for (index, cwd) in candidateCwds.enumerated() {
            Log.log(
                component: "AppState",
                "session/load attempt started",
                traceId: traceId,
                sessionId: sessionId,
                extra: sessionLoadObservabilityExtra(
                    error: nil,
                    cwd: cwd,
                    candidateIndex: index,
                    candidateCount: candidateCwds.count
                )
            )
            do {
                try await Log.timed(
                    "session/load",
                    component: "AppState",
                    traceId: traceId,
                    sessionId: sessionId
                ) {
                    try await withThrowingTimeout(seconds: max(1, sessionLoadTimeoutSeconds)) {
                        try await service.loadSession(
                            sessionId: sessionId,
                            cwd: cwd,
                            traceId: traceId
                        )
                    }
                }
                Log.log(
                    component: "AppState",
                    "session/load succeeded for \(sessionId) (cwd: \(cwd))",
                    traceId: traceId,
                    sessionId: sessionId,
                    extra: sessionLoadObservabilityExtra(
                        error: nil,
                        cwd: cwd,
                        candidateIndex: index,
                        candidateCount: candidateCwds.count
                    )
                )
                return SessionLoadResult(loadedCwd: cwd, sawNotFound: sawNotFound, lastError: nil)
            } catch {
                lastError = error
                if shouldTreatSessionLoadFailureAsNotFound(error) {
                    sawNotFound = true
                }
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "session/load failed for \(sessionId) (cwd: \(cwd)): \(error.localizedDescription)",
                    traceId: traceId,
                    sessionId: sessionId,
                    extra: sessionLoadObservabilityExtra(
                        error: error,
                        cwd: cwd,
                        candidateIndex: index,
                        candidateCount: candidateCwds.count
                    )
                )
                // "Session not found" is often cwd-dependent, so keep trying candidates.
                if shouldStopSessionLoadRetries(after: error) {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "stopping further session/load cwd retries after terminal load error",
                        traceId: traceId,
                        sessionId: sessionId,
                        extra: sessionLoadObservabilityExtra(
                            error: error,
                            cwd: cwd,
                            candidateIndex: index,
                            candidateCount: candidateCwds.count
                        )
                    )
                    break
                }
            }
        }
        return SessionLoadResult(loadedCwd: nil, sawNotFound: sawNotFound, lastError: lastError)
    }

    /// Whether we should stop trying more cwd candidates for session/load.
    private func shouldStopSessionLoadRetries(after error: Error) -> Bool {
        if let appStateError = error as? AppStateError,
           case .timeout = appStateError {
            return true
        }
        guard let acpError = error as? ACPError else { return false }
        return acpError.isNotAttached || acpError.isQueryClosedBeforeResponse
    }

    private func shouldTreatSessionLoadFailureAsNotFound(_ error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isSessionNotFound || acpError.isSessionLoadResourceNotFound
    }

    /// Structured diagnostics for session/load attempts.
    /// Keep keys stable so we can grep/analyze logs across real-device runs.
    private func sessionLoadObservabilityExtra(
        error: Error?,
        cwd: String,
        candidateIndex: Int,
        candidateCount: Int
    ) -> [String: String] {
        var extra: [String: String] = [
            "cwd": cwd,
            "candidateIndex": "\(candidateIndex + 1)",
            "candidateCount": "\(candidateCount)"
        ]
        extra.merge(acpErrorObservabilityExtra(error)) { current, _ in current }
        return extra
    }

    private func acpErrorObservabilityExtra(_ error: Error?) -> [String: String] {
        guard let error else { return [:] }
        var extra: [String: String] = [
            "errorType": String(describing: type(of: error))
        ]
        if let acpError = error as? ACPError {
            if let rpcCode = acpError.rpcCode {
                extra["rpcCode"] = "\(rpcCode)"
            }
            if let details = acpError.details, !details.isEmpty {
                extra["details"] = truncateLogField(details)
            }
            if let backendRequestID = acpError.backendRequestID {
                extra["backendRequestId"] = backendRequestID
            }
            extra["isSessionNotFound"] = acpError.isSessionNotFound ? "true" : "false"
            extra["isResourceNotFound"] = acpError.isResourceNotFound ? "true" : "false"
            extra["isQueryClosedBeforeResponse"] = acpError.isQueryClosedBeforeResponse ? "true" : "false"
            extra["isNotAttached"] = acpError.isNotAttached ? "true" : "false"
        }
        return extra
    }

    private func truncateLogField(_ value: String, limit: Int = 300) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + "...(truncated)"
    }

    /// Build ordered takeover command candidates, starting with the session's
    /// resolved command and then trying other available launchers.
    private func externalTakeoverCommandCandidates(primaryCommand: String) -> [String] {
        var commands: [String] = []
        var seen: Set<String> = []

        func append(_ raw: String?) {
            guard let normalized = normalizeOptionalAgentCommand(raw) else { return }
            guard seen.insert(normalized).inserted else { return }
            commands.append(normalized)
        }

        append(primaryCommand)

        let fallbackAgents = hasReliableAgentAvailability ? availableNodeAgents : AgentKind.allCases
        for agent in fallbackAgents {
            append(AgentCommandStore.command(for: agent))
        }

        if commands.isEmpty {
            append(AgentCommandStore.command(for: .claude))
        }

        return commands
    }

    /// Retry external takeover with another launcher command only when the
    /// upstream backend rejected the query in a terminal way.
    private func shouldRetryExternalTakeoverWithAlternateCommand(after error: Error?) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isQueryClosedBeforeResponse
            || acpError.isSessionNotFound
            || acpError.isSessionLoadResourceNotFound
    }

    private struct SessionLoadResult {
        let loadedCwd: String?
        let sawNotFound: Bool
        let lastError: Error?
    }

    /// End in-flight prompt UI when transitioning away from the current session.
    private func settlePromptingStateForSessionSwitch(clearMessages: Bool) {
        isPrompting = false
        clearAllPromptActivity()
        for msg in messages where msg.isStreaming {
            msg.isStreaming = false
        }
        if clearMessages {
            messages = []
        }
    }

    /// Take over an external (daemon-unmanaged) session by creating a managed proxy
    /// and loading the external history into it.
    private func takeOverExternalSession(
        externalSessionId: String,
        externalSessionCwd: String,
        workspace: Workspace,
        agentID: String,
        command: String,
        daemon: DaemonClient,
        traceId: String,
        modelContext: ModelContext,
        previousSessionId: String?,
        previousSessionAttachSeq: UInt64
    ) async throws {
        Log.log(
            component: "AppState",
            "taking over external session \(externalSessionId)",
            traceId: traceId,
            sessionId: externalSessionId
        )

        let takeoverCwds = loadCwdCandidates(
            preferred: [externalSessionCwd, workspace.path],
            workspace: workspace
        )
        let commandCandidates = externalTakeoverCommandCandidates(primaryCommand: command)

        var selectedSessionId: String?
        var selectedCommand: String?
        var selectedLoadResult: SessionLoadResult?
        var firstCreatedSessionId: String?

        isLoadingHistory = true
        defer { isLoadingHistory = false }
        temporaryNotificationSessionIDs.insert(externalSessionId)
        defer { temporaryNotificationSessionIDs.remove(externalSessionId) }

        for (index, candidateCommand) in commandCandidates.enumerated() {
            Log.log(
                component: "AppState",
                "external takeover create+attach attempt \(index + 1)/\(commandCandidates.count) command=\(candidateCommand)",
                traceId: traceId,
                sessionId: externalSessionId
            )

            let newSessionId = try await Log.timed(
                "daemon/session.create",
                component: "AppState",
                traceId: traceId
            ) {
                try await daemon.createSession(
                    cwd: workspace.path,
                    command: candidateCommand,
                    traceId: traceId
                )
            }
            if firstCreatedSessionId == nil {
                firstCreatedSessionId = newSessionId
            }

            await detachCurrentSessionIfNeeded(beforeAttaching: newSessionId, daemon: daemon, traceId: traceId)

            let attachResult: DaemonAttachResult
            do {
                attachResult = try await Log.timed(
                    "daemon/session.attach",
                    component: "AppState",
                    traceId: traceId,
                    sessionId: newSessionId
                ) {
                    try await attachSessionWithRetryIfNeeded(
                        daemon: daemon,
                        sessionId: newSessionId,
                        lastEventSeq: 0,
                        traceId: traceId
                    )
                }
            } catch {
                do {
                    try await daemon.killSession(sessionId: newSessionId, traceId: traceId)
                } catch let killError {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "failed to cleanup takeover attach-failure session \(newSessionId): \(killError.localizedDescription)",
                        traceId: traceId,
                        sessionId: newSessionId
                    )
                }
                await restorePreviousAttachmentIfNeeded(
                    previousSessionId: previousSessionId,
                    previousSessionAttachSeq: previousSessionAttachSeq,
                    failedTargetSessionId: newSessionId,
                    daemon: daemon,
                    traceId: traceId
                )
                throw error
            }

            self.currentSessionId = newSessionId
            self.lastEventSeq[newSessionId] = 0
            settlePromptingStateForSessionSwitch(clearMessages: true)

            // Replay attach buffer if any.
            for buffered in attachResult.bufferedEvents {
                if let event = SessionUpdateParser.parse(buffered.event) {
                    handleSessionEvent(event, sessionId: newSessionId)
                }
                lastEventSeq[newSessionId] = buffered.seq
            }
            for msg in messages where msg.isStreaming {
                msg.isStreaming = false
            }

            // Coupled with daemon `session/load` fallback routing:
            // we intentionally send the external history sessionId while attached
            // to the new managed proxy, and daemon routes this load request to the
            // sole live attached proxy for this client.
            let loadResult = await loadSessionFromCandidates(
                sessionId: externalSessionId,
                traceId: traceId,
                candidateCwds: takeoverCwds
            )
            // Let the notification listener drain load replay updates that may
            // arrive immediately around the response boundary.
            await Task.yield()

            let shouldRetryWithAlternateCommand =
                loadResult.loadedCwd == nil
                && shouldRetryExternalTakeoverWithAlternateCommand(after: loadResult.lastError)
                && index < commandCandidates.count - 1

            if shouldRetryWithAlternateCommand {
                var retryExtra = acpErrorObservabilityExtra(loadResult.lastError)
                retryExtra["candidateCommand"] = candidateCommand
                retryExtra["takeoverAttempt"] = "\(index + 1)"
                retryExtra["takeoverAttemptCount"] = "\(commandCandidates.count)"
                retryExtra["externalSessionCwd"] = externalSessionCwd
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "external takeover load failed for command \(candidateCommand); retrying alternate command",
                    traceId: traceId,
                    sessionId: externalSessionId,
                    extra: retryExtra
                )
                do {
                    try await daemon.killSession(sessionId: newSessionId, traceId: traceId)
                } catch {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "failed to cleanup takeover attempt session \(newSessionId): \(error.localizedDescription)",
                        traceId: traceId,
                        sessionId: newSessionId
                    )
                }
                self.currentSessionId = nil
                self.lastEventSeq.removeValue(forKey: newSessionId)
                continue
            }

            // Only persist a takeover mapping after session/load succeeds.
            // Otherwise we can permanently rewrite local session IDs to
            // throwaway managed IDs that cannot be loaded later.
            guard loadResult.loadedCwd != nil else {
                var failureExtra = acpErrorObservabilityExtra(loadResult.lastError)
                failureExtra["candidateCommand"] = candidateCommand
                failureExtra["takeoverAttempt"] = "\(index + 1)"
                failureExtra["takeoverAttemptCount"] = "\(commandCandidates.count)"
                failureExtra["externalSessionCwd"] = externalSessionCwd
                Log.log(
                    level: "warning",
                    component: "AppState",
                    "external takeover load failed; aborting takeover without persisting managed session id",
                    traceId: traceId,
                    sessionId: externalSessionId,
                    extra: failureExtra
                )
                do {
                    try await daemon.killSession(sessionId: newSessionId, traceId: traceId)
                } catch {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "failed to cleanup failed takeover session \(newSessionId): \(error.localizedDescription)",
                        traceId: traceId,
                        sessionId: newSessionId
                    )
                }
                self.currentSessionId = previousSessionId
                self.lastEventSeq.removeValue(forKey: newSessionId)
                await restorePreviousAttachmentIfNeeded(
                    previousSessionId: previousSessionId,
                    previousSessionAttachSeq: previousSessionAttachSeq,
                    failedTargetSessionId: newSessionId,
                    daemon: daemon,
                    traceId: traceId
                )
                throw AppStateError.sessionNotRecoverable(externalSessionId)
            }

            selectedSessionId = newSessionId
            selectedCommand = candidateCommand
            selectedLoadResult = loadResult
            break
        }

        guard let managedSessionId = selectedSessionId,
              let managedCommand = selectedCommand,
              let loadResult = selectedLoadResult else {
            await restorePreviousAttachmentIfNeeded(
                previousSessionId: previousSessionId,
                previousSessionAttachSeq: previousSessionAttachSeq,
                failedTargetSessionId: firstCreatedSessionId ?? externalSessionId,
                daemon: daemon,
                traceId: traceId
            )
            throw AppStateError.sessionNotRecoverable(externalSessionId)
        }

        let resolvedSessionCwd = loadResult.loadedCwd ?? externalSessionCwd
        let directDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == externalSessionId }
        )
        let canonicalDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.canonicalSessionId == externalSessionId }
        )
        let existingBySessionID = try? modelContext.fetch(directDescriptor).first
        let existingByCanonical = (try? modelContext.fetch(canonicalDescriptor))?
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .first

        if let existing = existingBySessionID ?? existingByCanonical {
            existing.sessionId = managedSessionId
            existing.canonicalSessionId = externalSessionId
            existing.sessionCwd = resolvedSessionCwd
            existing.agentID = existing.agentID ?? agentID
            existing.agentCommand = normalizeAgentCommand(
                existing.agentCommand,
                fallback: managedCommand
            )
            existing.lastUsedAt = Date()
            activeSession = existing
        } else {
            let session = Session(
                sessionId: managedSessionId,
                canonicalSessionId: externalSessionId,
                sessionCwd: resolvedSessionCwd,
                agentID: agentID,
                agentCommand: managedCommand,
                workspace: workspace
            )
            modelContext.insert(session)
            activeSession = session
        }
        try? modelContext.save()

        if loadResult.loadedCwd != nil {
            addSystemMessage("External session resumed")
        } else if loadResult.sawNotFound {
            addSystemMessage("External session resumed (history unavailable)")
        } else {
            addSystemMessage("External session resumed (history load failed)")
        }

        await refreshDaemonSessions()
    }

    private func restorePreviousAttachmentIfNeeded(
        previousSessionId: String?,
        previousSessionAttachSeq: UInt64,
        failedTargetSessionId: String,
        daemon: DaemonClient,
        traceId: String?
    ) async {
        guard let previousSessionId, previousSessionId != failedTargetSessionId else { return }
        do {
            let _ = try await attachSessionWithRetryIfNeeded(
                daemon: daemon,
                sessionId: previousSessionId,
                lastEventSeq: previousSessionAttachSeq,
                traceId: traceId
            )
            currentSessionId = previousSessionId
            Log.log(
                level: "warning",
                component: "AppState",
                "restored previous attachment after failed switch",
                traceId: traceId,
                sessionId: previousSessionId
            )
        } catch {
            // Both target attach and rollback attach failed. Clear stale active
            // attachment pointer so UI does not think the detached session is live.
            if currentSessionId == previousSessionId || currentSessionId == failedTargetSessionId {
                currentSessionId = nil
            }
            Log.log(
                level: "warning",
                component: "AppState",
                "failed to restore previous attachment after switch failure: \(error.localizedDescription)",
                traceId: traceId,
                sessionId: previousSessionId
            )
        }
    }

    /// Attach errors that mean daemon no longer owns this session.
    private func shouldTreatAttachFailureAsSessionMissing(_ error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isSessionNotFound
    }

    private func markSessionDead(sessionId: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let localSession = try? modelContext.fetch(descriptor).first
        let localCwd = localSession?.sessionCwd ?? localSession?.workspace?.path ?? activeWorkspace?.path ?? ""
        let localCommand = localSession?.agentCommand
        let localTitle = localSession?.title

        if let index = daemonSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            let existing = daemonSessions[index]
            daemonSessions[index] = DaemonSessionInfo(
                sessionId: existing.sessionId,
                cwd: existing.cwd,
                state: "dead",
                lastEventSeq: existing.lastEventSeq,
                command: existing.command,
                title: existing.title,
                updatedAt: Date()
            )
            return
        }

        guard !localCwd.isEmpty || localTitle != nil else { return }
        daemonSessions.append(
            DaemonSessionInfo(
                sessionId: sessionId,
                cwd: localCwd.isEmpty ? (activeWorkspace?.path ?? ".") : localCwd,
                state: "dead",
                lastEventSeq: 0,
                command: localCommand,
                title: localTitle,
                updatedAt: Date()
            )
        )
    }

    private func shouldTreatAttachFailureAsOwnershipConflict(_ error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isSessionAlreadyAttachedByAnotherClient
    }

    /// Retry daemon/session.attach when ownership is briefly stale during reconnect.
    private func attachSessionWithRetryIfNeeded(
        daemon: DaemonClient,
        sessionId: String,
        lastEventSeq: UInt64,
        traceId: String?
    ) async throws -> DaemonAttachResult {
        do {
            return try await daemon.attachSession(
                sessionId: sessionId,
                lastEventSeq: lastEventSeq,
                clientId: daemonAttachClientID,
                traceId: traceId
            )
        } catch {
            guard shouldTreatAttachFailureAsOwnershipConflict(error) else {
                throw error
            }

            let retryDelays: [Duration] = [
                .milliseconds(100),
                .milliseconds(200),
                .milliseconds(400),
                .milliseconds(800),
            ]
            var lastError = error
            for delay in retryDelays {
                try? await Task.sleep(for: delay)
                do {
                    return try await daemon.attachSession(
                        sessionId: sessionId,
                        lastEventSeq: lastEventSeq,
                        clientId: daemonAttachClientID,
                        traceId: traceId
                    )
                } catch {
                    lastError = error
                    guard shouldTreatAttachFailureAsOwnershipConflict(error) else {
                        throw error
                    }
                }
            }
            throw lastError
        }
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

    /// Wait for terminal `session/prompt` response with an inactivity timeout.
    /// As long as streaming updates keep arriving, we keep waiting past the base timeout.
    private func sendPromptAwaitingTerminalResponse(
        service: ACPService,
        sessionId: String,
        prompt: [PromptBlock],
        monitorSessionId: String,
        traceId: String?,
        inactivityTimeoutSeconds: TimeInterval
    ) async throws -> StopReason {
        let startedAt = Date()
        markPromptActivity(for: monitorSessionId)
        let pollIntervalSeconds = min(
            promptResponsePollIntervalSeconds,
            max(0.05, inactivityTimeoutSeconds / 2)
        )
        let maxWaitSeconds = max(inactivityTimeoutSeconds, promptResponseMaxWaitSeconds)
        let client = service.client

        return try await withThrowingTaskGroup(of: StopReason.self) { group in
            group.addTask {
                try await ACPService(client: client).sendPrompt(
                    sessionId: sessionId,
                    prompt: prompt,
                    traceId: traceId
                )
            }

            group.addTask { @MainActor in
                while true {
                    try await Task.sleep(for: .seconds(pollIntervalSeconds))
                    let inactivity = self.promptInactivitySeconds(for: monitorSessionId, fallback: startedAt)
                    if inactivity < inactivityTimeoutSeconds {
                        continue
                    }

                    let promptStillActive = self.isPrompting && self.currentSessionId == monitorSessionId
                    if !promptStillActive {
                        throw CancellationError()
                    }

                    let elapsedSeconds = max(0, Date().timeIntervalSince(startedAt))
                    if elapsedSeconds >= maxWaitSeconds {
                        throw PromptResponseTimeoutError(seconds: maxWaitSeconds)
                    }

                    let shouldKeepWaiting = await self.shouldKeepWaitingForPromptAfterInactivity(
                        sessionId: monitorSessionId,
                        traceId: traceId
                    )
                    if shouldKeepWaiting {
                        self.markPromptActivity(for: monitorSessionId)
                        continue
                    }

                    throw PromptResponseTimeoutError(seconds: inactivityTimeoutSeconds)
                }
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    /// When the watchdog reaches inactivity timeout, confirm whether daemon still
    /// considers this session actively running before surfacing a timeout to UI.
    private func shouldKeepWaitingForPromptAfterInactivity(
        sessionId: String,
        traceId: String?
    ) async -> Bool {
        let cachedState = daemonSessions.first(where: { $0.sessionId == sessionId })?.state
        guard let daemon = daemonClient else {
            return isBusyDaemonSessionState(cachedState)
        }

        do {
            let sessions = try await fetchDaemonSessionsForPromptWatchdog(
                daemon: daemon,
                traceId: traceId
            )
            if let refreshed = sessions.first(where: { $0.sessionId == sessionId }) {
                if let index = daemonSessions.firstIndex(where: { $0.sessionId == sessionId }) {
                    daemonSessions[index] = refreshed
                } else {
                    daemonSessions.append(refreshed)
                }
                let busy = isBusyDaemonSessionState(refreshed.state)
                if busy {
                    Log.log(
                        level: "warning",
                        component: "AppState",
                        "prompt watchdog deferred timeout; daemon state=\(refreshed.state)",
                        traceId: traceId,
                        sessionId: sessionId
                    )
                }
                return busy
            }
            return false
        } catch {
            let cachedBusy = isBusyDaemonSessionState(cachedState)
            Log.log(
                level: "warning",
                component: "AppState",
                "prompt watchdog daemon state check failed (cachedBusy=\(cachedBusy)): \(error.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId
            )
            return cachedBusy
        }
    }

    /// Nonisolated helper for prompt watchdog polling.
    /// `DaemonClient` is its own actor; this just avoids implicitly binding the
    /// polling helper itself to MainActor.
    nonisolated private func fetchDaemonSessionsForPromptWatchdog(
        daemon: DaemonClient,
        traceId: String?
    ) async throws -> [DaemonSessionInfo] {
        try await daemon.listSessions(traceId: traceId)
    }

    private func isBusyDaemonSessionState(_ state: String?) -> Bool {
        guard let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "starting"
            || normalized == "prompting"
            || normalized == "draining"
    }

    private func markPromptActivity(for sessionId: String) {
        promptLastActivityAt[sessionId] = Date()
    }

    private func clearPromptActivity(for sessionId: String) {
        promptLastActivityAt.removeValue(forKey: sessionId)
    }

    private func clearAllPromptActivity() {
        promptLastActivityAt.removeAll()
    }

    private func promptInactivitySeconds(for sessionId: String, fallback: Date) -> TimeInterval {
        let lastActivity = promptLastActivityAt[sessionId] ?? fallback
        return max(0, Date().timeIntervalSince(lastActivity))
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
        if let promptTimeout = error as? PromptResponseTimeoutError {
            let seconds = max(1, Int(promptTimeout.seconds.rounded()))
            return (
                "Timed out waiting for model response.",
                "No terminal response or streaming updates were received within \(seconds)s. You can resend the message."
            )
        }

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
                "Session no longer exists remotely. Create a new session to continue."
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

    private func normalizePromptSendError(_ error: Error, timeoutSeconds: TimeInterval) -> Error {
        if let appStateError = error as? AppStateError,
           case .timeout = appStateError {
            return PromptResponseTimeoutError(seconds: timeoutSeconds)
        }
        return error
    }

    private func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }
}

private struct PromptResponseTimeoutError: LocalizedError {
    let seconds: TimeInterval

    var errorDescription: String? {
        let roundedSeconds = max(1, Int(seconds.rounded()))
        return "Timed out waiting for session/prompt after \(roundedSeconds)s"
    }
}

enum AppStateError: Error, LocalizedError {
    case notConnected
    case timeout
    case noAvailableAgents
    case agentUnavailable(String)
    case sessionAttachedByAnotherClient(String)
    case sessionNotRecoverable(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a workspace"
        case .timeout: "Connection timed out — server did not respond"
        case .noAvailableAgents: "No available ACP agents on this node"
        case .agentUnavailable(let displayName): "\(displayName) is not available on this node"
        case .sessionAttachedByAnotherClient(let sessionId):
            "Session \(sessionId) is currently attached by another client. Close that client and retry."
        case .sessionNotRecoverable(let sessionId):
            "Session \(sessionId) is no longer recoverable. Start a new session."
        }
    }
}

/// Run an async operation with a timeout.
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let timeoutSeconds = max(0.001, seconds)
    let box = TimeoutRaceBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.installContinuation(continuation)

            let operationTask = Task {
                do {
                    let value = try await operation()
                    box.resolve(.success(value))
                } catch {
                    box.resolve(.failure(error))
                }
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    // Canceled because the operation completed first.
                    return
                }
                box.resolve(.failure(AppStateError.timeout))
            }

            box.installTasks(operationTask: operationTask, timeoutTask: timeoutTask)
        }
    } onCancel: {
        box.resolve(.failure(CancellationError()))
    }
}

/// Coordinates timeout-vs-operation races without waiting for canceled tasks to
/// cooperatively finish. This avoids hangs when the canceled operation is stuck
/// in a non-cancellation-aware await.
private final class TimeoutRaceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolved = false

    func installContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func installTasks(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func resolve(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        continuation = self.continuation
        self.continuation = nil
        operationTask = self.operationTask
        self.operationTask = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
