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

    // Active connection context
    var activeNode: Node?
    var activeWorkspace: Workspace?
    var activeSession: Session?
    var connectionStatus: ConnectionStatus = .disconnected
    var connectionError: String?

    // Navigation
    var shouldPopToRoot = false

    // Daemon runtime/session snapshots used by chat/runtime recovery.
    var daemonSessions: [DaemonSessionInfo] = []
    // Daemon conversation snapshots used by SessionPicker/open flows.
    var daemonConversations: [DaemonConversationInfo] = []
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
    /// Guards against overlapping reconnect+open recovery attempts.
    private var isAutoReconnectInProgress = false
    /// Test hook for mocking the auto-reconnect connect step.
    var autoReconnectConnectHandler: ((Node) async -> Void)?
    /// Test hook for mocking the auto-reconnect open step.
    var autoReconnectOpenHandler: ((String, ModelContext) async throws -> Void)?

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
    /// After this, set activeWorkspace and call createNewSession() or openSession() to start chatting.
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
                self.daemonConversations = []
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
                self.daemonConversations = []
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

    /// Refresh daemon runtime + conversation snapshots.
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
        // Fetch unscoped snapshots to avoid false negatives from daemon-side cwd
        // scoping (path aliases/normalization may differ by client environment).
        if let updatedSessions = try? await daemon.listSessions() {
            self.daemonSessions = updatedSessions
        }
        if let updatedConversations = try? await daemon.listConversations() {
            self.daemonConversations = updatedConversations
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

    /// Create a new daemon-owned conversation using explicit agent metadata.
    private func createNewSession(modelContext: ModelContext, agentID: String, command: String) async throws {
        guard let daemon = daemonClient,
              let workspace = activeWorkspace else {
            throw AppStateError.notConnected
        }

        let traceId = newTraceId()
        let launchCommand = ConversationPersistence.normalizeAgentCommand(
            command,
            fallback: AgentCommandStore.command(forAgentID: agentID)
        )

        Log.log(
            component: "AppState",
            "creating conversation via daemon",
            traceId: traceId,
            extra: [
                "workspacePath": workspace.path,
                "agentID": agentID,
                "command": launchCommand,
                "ownerId": daemonAttachClientID
            ]
        )
        let result = try await Log.timed(
            "daemon/conversation.create",
            component: "AppState",
            traceId: traceId
        ) {
            try await daemon.createConversation(
                cwd: workspace.path,
                command: launchCommand,
                ownerId: daemonAttachClientID,
                traceId: traceId
            )
        }

        let runtimeId = result.attachment.runtimeId
        settlePromptingStateForSessionSwitch(clearMessages: true)
        currentSessionId = runtimeId
        lastEventSeq[runtimeId] = result.attachment.bufferedEvents.last?.seq ?? 0

        let session = ConversationPersistence.createLocalSession(
            from: result,
            workspace: workspace,
            agentID: agentID,
            command: launchCommand,
            modelContext: modelContext
        )
        activeSession = session

        upsertDaemonConversationSnapshot(result.conversation)
        upsertDaemonSessionSnapshot(
            sessionId: runtimeId,
            cwd: workspace.path,
            state: result.attachment.state,
            lastEventSeq: result.attachment.bufferedEvents.last?.seq ?? 0,
            command: launchCommand,
            title: session.title,
            updatedAt: Date()
        )

        addSystemMessage("New session on \(workspace.name)")
    }

    /// Open a stable conversation from SessionPicker, reusing an existing
    /// runtime when available or restoring it into a fresh daemon runtime.
    func openSession(sessionId conversationId: String, modelContext: ModelContext) async throws {
        try await ConversationLifecycle.openSession(
            appState: self,
            sessionId: conversationId,
            modelContext: modelContext
        )
    }

    /// Reconnect and restore the active chat after an unexpected transport drop.
    /// Intended to be called when ChatView reappears (for example, app foreground).
    func recoverInterruptedSessionIfNeeded(modelContext: ModelContext) async {
        await ConversationLifecycle.recoverInterruptedSessionIfNeeded(
            appState: self,
            modelContext: modelContext
        )
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
        daemonConversations = []
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
            sessionId: sessionId,
            extra: [
                "promptSessionId": sessionId,
                "activeConversationId": activeSession?.stableConversationId ?? "",
                "activeRuntimeId": activeSession?.sessionId ?? "",
                "currentSessionId": currentSessionId ?? "",
                "resourceLinkCount": String(referencedMentions.count)
            ]
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
                    try await daemon.detachConversation(conversationId: session.stableConversationId)
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
        do {
            try modelContext.save()
        } catch {
            Log.toFile("[AppState] Failed to persist empty-session deletion \(sessionId): \(error)")
        }

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
                let context = self.notificationRoutingContext(for: notification)

                guard self.shouldHandleSessionNotification(context) else {
                    Log.toFile(
                        "[AppState] Ignoring event for runtime=\(context.runtimeId ?? "nil") conversation=\(context.conversationId ?? "nil") session=\(context.legacySessionId ?? "nil")"
                    )
                    continue
                }

                if let seq = context.seq,
                   let cursorSessionId = context.cursorSessionId(currentRuntimeId: self.currentSessionId) {
                    self.lastEventSeq[cursorSessionId] = seq
                }

                guard let event = SessionUpdateParser.parse(notification) else { continue }
                let effectiveSessionId = context.effectiveSessionId(currentRuntimeId: self.currentSessionId)
                Log.toFile("[AppState] Session event: \(event)")
                self.handleSessionEvent(event, sessionId: effectiveSessionId)
            }
            Log.toFile("[AppState] Notification listener ended")
            if !Task.isCancelled {
                self.markTransportInterrupted(self.connectionError ?? "SSH connection interrupted")
            }
        }
    }

    private struct NotificationRoutingContext {
        let runtimeId: String?
        let conversationId: String?
        let legacySessionId: String?
        let seq: UInt64?

        func effectiveSessionId(currentRuntimeId: String?) -> String? {
            runtimeId ?? currentRuntimeId ?? legacySessionId
        }

        func cursorSessionId(currentRuntimeId: String?) -> String? {
            runtimeId ?? currentRuntimeId ?? legacySessionId
        }
    }

    private func notificationRoutingContext(for notification: JSONRPCMessage) -> NotificationRoutingContext {
        guard case .notification(_, let params) = notification else {
            return NotificationRoutingContext(
                runtimeId: nil,
                conversationId: nil,
                legacySessionId: nil,
                seq: nil
            )
        }
        return NotificationRoutingContext(
            runtimeId: normalizedNotificationID(params?["runtimeId"]?.stringValue),
            conversationId: normalizedNotificationID(params?["conversationId"]?.stringValue),
            legacySessionId: normalizedNotificationID(params?["sessionId"]?.stringValue),
            seq: params?["__seq"]?.intValue.flatMap { UInt64($0) }
        )
    }

    private func shouldHandleSessionNotification(_ context: NotificationRoutingContext) -> Bool {
        if let runtimeId = context.runtimeId {
            guard let currentSessionId else { return true }
            return runtimeId == currentSessionId
        }

        let activeConversationId = normalizedNotificationID(activeSession?.stableConversationId)
        if let conversationId = context.conversationId,
           let activeConversationId {
            return conversationId == activeConversationId
        }

        if let legacySessionId = context.legacySessionId {
            if let currentSessionId {
                return legacySessionId == currentSessionId
            }
            if let activeConversationId {
                return legacySessionId == activeConversationId
            }
            return false
        }

        return true
    }

    private func normalizedNotificationID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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
        ConversationPersistence.resolveSessionAgent(
            storedAgentID: storedAgentID,
            storedAgentCommand: storedAgentCommand,
            daemonCommand: daemonCommand
        )
    }

    private func normalizeAgentCommand(_ command: String?, fallback: String) -> String {
        ConversationPersistence.normalizeAgentCommand(command, fallback: fallback)
    }

    private func normalizeOptionalAgentCommand(_ command: String?) -> String? {
        ConversationPersistence.normalizeOptionalAgentCommand(command)
    }

    /// Resolve a legacy runtime/session identifier back to a stable conversation ID.
    private func resolveConversationID(forLegacySessionID sessionId: String, modelContext: ModelContext) -> String {
        ConversationPersistence.resolveConversationID(
            forLegacySessionID: sessionId,
            daemonConversations: daemonConversations,
            modelContext: modelContext
        )
    }

    private func localSession(forConversationID conversationId: String, modelContext: ModelContext) -> Session? {
        ConversationPersistence.localSession(
            forConversationID: conversationId,
            modelContext: modelContext
        )
    }

    private func backfillConversationIdentity(_ session: Session, conversationId: String? = nil) {
        ConversationPersistence.backfillConversationIdentity(session, conversationId: conversationId)
    }

    private func markConversationUnavailable(
        conversationId: String,
        session: Session?,
        fallbackCwd: String,
        command: String?
    ) {
        ConversationPersistence.markConversationUnavailable(
            conversationId: conversationId,
            session: session,
            fallbackCwd: fallbackCwd,
            command: command,
            daemonConversations: &daemonConversations
        )
    }

    private func upsertDaemonConversationSnapshot(_ conversation: DaemonConversationInfo) {
        ConversationPersistence.upsertDaemonConversationSnapshot(
            conversation,
            into: &daemonConversations
        )
    }

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

    private func upsertDaemonSessionSnapshot(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?,
        updatedAt: Date
    ) {
        ConversationPersistence.upsertDaemonSessionSnapshot(
            sessionId: sessionId,
            cwd: cwd,
            state: state,
            lastEventSeq: lastEventSeq,
            command: command,
            title: title,
            updatedAt: updatedAt,
            activeWorkspacePath: activeWorkspace?.path,
            daemonSessions: &daemonSessions
        )
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


extension AppState: ConversationLifecycleAppState {
    var shouldAutoReconnectInterruptedSessionForLifecycle: Bool {
        get { shouldAutoReconnectInterruptedSession }
        set { shouldAutoReconnectInterruptedSession = newValue }
    }

    var isAutoReconnectInProgressForLifecycle: Bool {
        get { isAutoReconnectInProgress }
        set { isAutoReconnectInProgress = newValue }
    }

    var daemonAttachClientIDForLifecycle: String { daemonAttachClientID }
    var daemonClientForLifecycle: DaemonClient? { daemonClient }

    var lastEventSeqByRuntimeIDForLifecycle: [String: UInt64] {
        get { lastEventSeq }
        set { lastEventSeq = newValue }
    }

    func newTraceIDForLifecycle() -> String {
        newTraceId()
    }

    func lifecycleConnect(node: Node, isAutoReconnect: Bool) {
        connect(node: node, isAutoReconnect: isAutoReconnect)
    }

    func lifecycleWaitForConnectionResult(timeoutSeconds: TimeInterval) async -> Bool {
        await waitForConnectionResult(timeoutSeconds: timeoutSeconds)
    }

    func lifecycleResolveSessionAgent(
        storedAgentID: String?,
        storedAgentCommand: String?,
        daemonCommand: String?
    ) -> (id: String, command: String) {
        resolveSessionAgent(
            storedAgentID: storedAgentID,
            storedAgentCommand: storedAgentCommand,
            daemonCommand: daemonCommand
        )
    }

    func lifecycleNormalizeAgentCommand(_ command: String?, fallback: String) -> String {
        normalizeAgentCommand(command, fallback: fallback)
    }

    func lifecycleLocalSession(forConversationID conversationId: String, modelContext: ModelContext) -> Session? {
        localSession(forConversationID: conversationId, modelContext: modelContext)
    }

    func lifecycleBackfillConversationIdentity(_ session: Session, conversationId: String?) {
        backfillConversationIdentity(session, conversationId: conversationId)
    }

    func lifecycleMarkConversationUnavailable(
        conversationId: String,
        session: Session?,
        fallbackCwd: String,
        command: String?
    ) {
        markConversationUnavailable(
            conversationId: conversationId,
            session: session,
            fallbackCwd: fallbackCwd,
            command: command
        )
    }

    func lifecycleUpsertDaemonConversationSnapshot(_ conversation: DaemonConversationInfo) {
        upsertDaemonConversationSnapshot(conversation)
    }

    func lifecycleUpsertDaemonSessionSnapshot(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?,
        updatedAt: Date
    ) {
        upsertDaemonSessionSnapshot(
            sessionId: sessionId,
            cwd: cwd,
            state: state,
            lastEventSeq: lastEventSeq,
            command: command,
            title: title,
            updatedAt: updatedAt
        )
    }

    func lifecycleSettlePromptingStateForSessionSwitch(clearMessages: Bool) {
        settlePromptingStateForSessionSwitch(clearMessages: clearMessages)
    }

    func lifecycleHandleSessionEvent(_ event: SessionEvent, sessionId: String?) {
        handleSessionEvent(event, sessionId: sessionId)
    }

    func lifecycleRefreshDaemonSessions() async {
        await refreshDaemonSessions()
    }

    func lifecycleAddSystemMessage(_ text: String) {
        addSystemMessage(text)
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
