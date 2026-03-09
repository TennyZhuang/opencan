import Foundation
import SwiftData

@MainActor
protocol ConversationLifecycleAppState: AnyObject {
    var activeNode: Node? { get set }
    var activeWorkspace: Workspace? { get set }
    var activeSession: Session? { get set }
    var connectionStatus: AppState.ConnectionStatus { get set }
    var connectionError: String? { get set }
    var daemonConversations: [DaemonConversationInfo] { get set }
    var messages: [ChatMessage] { get set }
    var currentSessionId: String? { get set }
    var shouldAutoReconnectInterruptedSessionForLifecycle: Bool { get set }
    var isAutoReconnectInProgressForLifecycle: Bool { get set }
    var daemonAttachClientIDForLifecycle: String { get }
    var daemonClientForLifecycle: DaemonClient? { get }
    var lastEventSeqByRuntimeIDForLifecycle: [String: UInt64] { get set }
    var autoReconnectConnectHandler: ((Node) async -> Void)? { get }
    var autoReconnectOpenHandler: ((String, ModelContext) async throws -> Void)? { get }

    func newTraceIDForLifecycle() -> String
    func lifecycleConnect(node: Node, isAutoReconnect: Bool)
    func lifecycleWaitForConnectionResult(timeoutSeconds: TimeInterval) async -> Bool
    func lifecycleResolveSessionAgent(
        storedAgentID: String?,
        storedAgentCommand: String?,
        daemonCommand: String?
    ) -> (id: String, command: String)
    func lifecycleNormalizeAgentCommand(_ command: String?, fallback: String) -> String
    func lifecycleLocalSession(forConversationID conversationId: String, modelContext: ModelContext) -> Session?
    func lifecycleBackfillConversationIdentity(_ session: Session, conversationId: String?)
    func lifecycleMarkConversationUnavailable(
        conversationId: String,
        session: Session?,
        fallbackCwd: String,
        command: String?
    )
    func lifecycleUpsertDaemonConversationSnapshot(_ conversation: DaemonConversationInfo)
    func lifecycleUpsertDaemonSessionSnapshot(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?,
        updatedAt: Date
    )
    func lifecycleSettlePromptingStateForSessionSwitch(clearMessages: Bool)
    func lifecycleHandleSessionEvent(_ event: SessionEvent, sessionId: String?)
    func lifecycleRefreshDaemonSessions() async
    func lifecycleAddSystemMessage(_ text: String)
    func lifecycleRecoverBusyPromptingState(sessionId: String)
}

enum ConversationLifecycle {
    @MainActor
    static func openSession(
        appState: ConversationLifecycleAppState,
        conversationId: String,
        modelContext: ModelContext
    ) async throws {
        guard let daemon = appState.daemonClientForLifecycle,
              let workspace = appState.activeWorkspace else {
            throw AppStateError.notConnected
        }

        let traceId = appState.newTraceIDForLifecycle()
        let existingSession = appState.lifecycleLocalSession(
            forConversationID: conversationId,
            modelContext: modelContext
        )
        let daemonConversation = appState.daemonConversations.first { $0.conversationId == conversationId }
        let currentConversationId = appState.activeSession?.conversationId
        let sessionAgent = appState.lifecycleResolveSessionAgent(
            storedAgentID: existingSession?.agentID,
            storedAgentCommand: existingSession?.agentCommand,
            daemonCommand: daemonConversation?.command
        )

        if currentConversationId == conversationId,
           let activeRuntimeId = appState.activeSession?.runtimeId,
           appState.currentSessionId == activeRuntimeId,
           !appState.shouldAutoReconnectInterruptedSessionForLifecycle,
           !appState.messages.isEmpty {
            if let existingSession {
                appState.lifecycleBackfillConversationIdentity(existingSession, conversationId: conversationId)
                existingSession.lastUsedAt = Date()
                existingSession.conversationCwd = daemonConversation?.cwd ?? existingSession.conversationCwd ?? workspace.path
                existingSession.agentID = existingSession.agentID ?? sessionAgent.id
                existingSession.agentCommand = appState.lifecycleNormalizeAgentCommand(
                    existingSession.agentCommand,
                    fallback: sessionAgent.command
                )
                appState.activeSession = existingSession
                try? modelContext.save()
            }
            Log.log(
                component: "ConversationLifecycle",
                "reusing in-memory transcript for active conversation \(conversationId)",
                traceId: traceId,
                sessionId: appState.currentSessionId
            )
            return
        }

        let previousConversationId = currentConversationId
        let previousSessionId = appState.currentSessionId
        let previousSessionAttachSeq: UInt64 = {
            guard let previousSessionId else { return 0 }
            return appState.lastEventSeqByRuntimeIDForLifecycle[previousSessionId] ?? 0
        }()
        let lastRuntimeId = daemonConversation?.runtimeId ?? existingSession?.runtimeId
        let desiredAttachSeq = lastRuntimeId.flatMap { appState.lastEventSeqByRuntimeIDForLifecycle[$0] } ?? 0
        let cwdHint = daemonConversation?.cwd ?? existingSession?.conversationCwd ?? workspace.path

        Log.log(
            component: "ConversationLifecycle",
            "opening conversation via daemon",
            traceId: traceId,
            sessionId: conversationId,
            extra: [
                "conversationId": conversationId,
                "currentConversationId": currentConversationId ?? "",
                "previousRuntimeId": previousSessionId ?? "",
                "lastRuntimeId": lastRuntimeId ?? "",
                "desiredAttachSeq": String(desiredAttachSeq),
                "daemonConversationRuntimeId": daemonConversation?.runtimeId ?? "",
                "daemonConversationState": daemonConversation?.state ?? "",
                "localRuntimeId": existingSession?.runtimeId ?? "",
                "cwdHint": cwdHint,
                "preferredCommand": sessionAgent.command,
                "ownerId": appState.daemonAttachClientIDForLifecycle
            ]
        )

        appState.lifecycleSettlePromptingStateForSessionSwitch(clearMessages: false)
        await detachCurrentConversationIfNeeded(
            appState: appState,
            beforeOpening: conversationId,
            currentConversationId: currentConversationId,
            daemon: daemon,
            traceId: traceId
        )

        let result: DaemonConversationOpenResult
        do {
            result = try await Log.timed(
                "daemon/conversation.open",
                component: "ConversationLifecycle",
                traceId: traceId,
                sessionId: conversationId
            ) {
                try await daemon.openConversation(
                    conversationId: conversationId,
                    ownerId: appState.daemonAttachClientIDForLifecycle,
                    lastRuntimeId: lastRuntimeId,
                    lastEventSeq: desiredAttachSeq,
                    preferredCommand: sessionAgent.command,
                    cwdHint: cwdHint,
                    traceId: traceId
                )
            }
        } catch {
            await restorePreviousAttachmentIfNeeded(
                appState: appState,
                previousConversationId: previousConversationId,
                previousSessionId: previousSessionId,
                previousSessionAttachSeq: previousSessionAttachSeq,
                previousCommand: appState.activeSession?.agentCommand,
                previousCwd: appState.activeSession?.conversationCwd,
                failedTargetConversationId: conversationId,
                daemon: daemon,
                traceId: traceId
            )
            if shouldTreatAttachFailureAsOwnershipConflict(error) {
                throw AppStateError.sessionAttachedByAnotherClient(conversationId)
            }
            let lowercasedError = error.localizedDescription.lowercased()
            if shouldTreatAttachFailureAsSessionMissing(error)
                || lowercasedError.contains("conversation not found") {
                appState.lifecycleMarkConversationUnavailable(
                    conversationId: conversationId,
                    session: existingSession,
                    fallbackCwd: cwdHint,
                    command: sessionAgent.command
                )
                throw AppStateError.sessionNotRecoverable(conversationId)
            }
            throw error
        }

        let runtimeId = result.attachment.runtimeId
        if let lastRuntimeId, lastRuntimeId != runtimeId {
            appState.lastEventSeqByRuntimeIDForLifecycle.removeValue(forKey: lastRuntimeId)
        }
        appState.currentSessionId = runtimeId
        appState.lastEventSeqByRuntimeIDForLifecycle[runtimeId] = result.attachment.bufferedEvents.last?.seq ?? 0
        appState.lifecycleSettlePromptingStateForSessionSwitch(clearMessages: true)

        var bufferedPromptCompleted = false
        for buffered in result.attachment.bufferedEvents {
            if let event = SessionUpdateParser.parse(buffered.event) {
                if case .promptComplete = event {
                    bufferedPromptCompleted = true
                }
                appState.lifecycleHandleSessionEvent(event, sessionId: runtimeId)
            }
            appState.lastEventSeqByRuntimeIDForLifecycle[runtimeId] = buffered.seq
        }
        for msg in appState.messages where msg.isStreaming {
            msg.isStreaming = false
        }
        if attachmentRequiresPromptRecovery(result.attachment.state) && !bufferedPromptCompleted {
            appState.lifecycleRecoverBusyPromptingState(sessionId: runtimeId)
        }

        let persistedSession = ConversationPersistence.upsertLocalSessionForOpen(
            result: result,
            conversationId: conversationId,
            existingSession: existingSession,
            workspace: workspace,
            sessionAgent: sessionAgent,
            modelContext: modelContext
        )
        let resolvedCwd = persistedSession.conversationCwd ?? workspace.path
        let resolvedCommand = persistedSession.agentCommand
        appState.activeSession = persistedSession

        appState.lifecycleUpsertDaemonConversationSnapshot(result.conversation)
        appState.lifecycleUpsertDaemonSessionSnapshot(
            sessionId: runtimeId,
            cwd: resolvedCwd,
            state: result.attachment.state,
            lastEventSeq: result.attachment.bufferedEvents.last?.seq ?? 0,
            command: resolvedCommand,
            title: persistedSession.title ?? result.conversation.title,
            updatedAt: Date()
        )

        Log.log(
            component: "ConversationLifecycle",
            "conversation open applied locally",
            traceId: traceId,
            sessionId: runtimeId,
            extra: [
                "conversationId": conversationId,
                "runtimeId": runtimeId,
                "attachmentState": result.attachment.state,
                "reusedRuntime": result.attachment.reusedRuntime ? "true" : "false",
                "restoredFromHistory": result.attachment.restoredFromHistory ? "true" : "false",
                "bufferedEventCount": String(result.attachment.bufferedEvents.count),
                "resolvedCwd": resolvedCwd,
                "resolvedCommand": resolvedCommand ?? "",
                "activeSessionConversationId": appState.activeSession?.conversationId ?? "",
                "activeSessionRuntimeId": appState.activeSession?.runtimeId ?? "",
                "currentSessionId": appState.currentSessionId ?? ""
            ]
        )

        appState.lifecycleAddSystemMessage(statusMessage(for: result.attachment))
        await appState.lifecycleRefreshDaemonSessions()
    }

    @MainActor
    static func recoverInterruptedSessionIfNeeded(
        appState: ConversationLifecycleAppState,
        modelContext: ModelContext
    ) async {
        guard appState.shouldAutoReconnectInterruptedSessionForLifecycle else { return }
        guard !appState.isAutoReconnectInProgressForLifecycle else { return }
        guard appState.connectionStatus == .disconnected || appState.connectionStatus == .failed else { return }
        guard let node = appState.activeNode else { return }
        let recoveryTargetId = appState.activeSession?.conversationId
            ?? appState.currentSessionId
            ?? appState.activeSession?.runtimeId
        guard let sessionId = recoveryTargetId else { return }
        guard let workspace = appState.activeWorkspace ?? appState.activeSession?.workspace else { return }

        appState.isAutoReconnectInProgressForLifecycle = true
        defer { appState.isAutoReconnectInProgressForLifecycle = false }

        Log.log(
            component: "ConversationLifecycle",
            "attempting interrupted-session recovery",
            sessionId: sessionId
        )

        if let connectHandler = appState.autoReconnectConnectHandler {
            await connectHandler(node)
        } else {
            appState.lifecycleConnect(node: node, isAutoReconnect: true)
        }

        let connected: Bool
        if appState.autoReconnectConnectHandler != nil {
            connected = appState.connectionStatus == .connected
        } else {
            connected = await appState.lifecycleWaitForConnectionResult(timeoutSeconds: 30)
        }
        guard connected else {
            appState.shouldAutoReconnectInterruptedSessionForLifecycle = true
            Log.log(
                level: "warning",
                component: "ConversationLifecycle",
                "interrupted-session recovery connect phase failed",
                sessionId: sessionId
            )
            return
        }

        appState.activeWorkspace = workspace
        do {
            if let openHandler = appState.autoReconnectOpenHandler {
                try await openHandler(sessionId, modelContext)
            } else {
                try await openSession(appState: appState, conversationId: sessionId, modelContext: modelContext)
            }
            appState.connectionError = nil
            appState.shouldAutoReconnectInterruptedSessionForLifecycle = false
        } catch {
            appState.connectionError = error.localizedDescription
            appState.connectionStatus = .failed
            appState.shouldAutoReconnectInterruptedSessionForLifecycle = true
            Log.log(
                level: "error",
                component: "ConversationLifecycle",
                "interrupted-session recovery failed: \(error.localizedDescription)",
                sessionId: sessionId
            )
        }
    }

    private static func statusMessage(for attachment: DaemonConversationAttachment) -> String {
        let isRunningAttachment = attachment.state == "starting"
            || attachment.state == "prompting"
            || attachment.state == "draining"
        if isRunningAttachment {
            return attachment.reusedRuntime
                ? "Conversation reopened (still running)"
                : "Conversation restored (still running)"
        } else if attachment.restoredFromHistory {
            return "Conversation restored"
        } else if attachment.reusedRuntime {
            return "Conversation reopened"
        } else {
            return "Conversation opened"
        }
    }

    private static func attachmentRequiresPromptRecovery(_ state: String) -> Bool {
        state == "starting" || state == "prompting" || state == "draining"
    }

    @MainActor
    private static func detachCurrentConversationIfNeeded(
        appState: ConversationLifecycleAppState,
        beforeOpening targetConversationId: String,
        currentConversationId: String?,
        daemon: DaemonClient,
        traceId: String?
    ) async {
        guard let currentConversationId, currentConversationId != targetConversationId else { return }
        let currentRuntimeId = appState.currentSessionId
        do {
            try await daemon.detachConversation(conversationId: currentConversationId, traceId: traceId)
            Log.log(
                component: "ConversationLifecycle",
                "detached previous conversation \(currentConversationId)",
                traceId: traceId,
                sessionId: currentRuntimeId
            )
        } catch {
            Log.log(
                level: "warning",
                component: "ConversationLifecycle",
                "failed to detach previous conversation \(currentConversationId): \(error.localizedDescription)",
                traceId: traceId,
                sessionId: currentRuntimeId
            )
        }
    }

    @MainActor
    private static func restorePreviousAttachmentIfNeeded(
        appState: ConversationLifecycleAppState,
        previousConversationId: String?,
        previousSessionId: String?,
        previousSessionAttachSeq: UInt64,
        previousCommand: String?,
        previousCwd: String?,
        failedTargetConversationId: String,
        daemon: DaemonClient,
        traceId: String?
    ) async {
        guard let previousConversationId, previousConversationId != failedTargetConversationId else { return }
        do {
            let restored = try await daemon.openConversation(
                conversationId: previousConversationId,
                ownerId: appState.daemonAttachClientIDForLifecycle,
                lastRuntimeId: previousSessionId,
                lastEventSeq: previousSessionAttachSeq,
                preferredCommand: previousCommand,
                cwdHint: previousCwd,
                traceId: traceId
            )
            let restoredRuntimeId = restored.attachment.runtimeId
            appState.currentSessionId = restoredRuntimeId
            appState.lastEventSeqByRuntimeIDForLifecycle[restoredRuntimeId] = restored.attachment.bufferedEvents.last?.seq ?? previousSessionAttachSeq
            if let activeSession = appState.activeSession,
               activeSession.conversationId == previousConversationId {
                activeSession.runtimeId = restoredRuntimeId
                activeSession.conversationCwd = restored.conversation.cwd.isEmpty
                    ? (activeSession.conversationCwd ?? previousCwd)
                    : restored.conversation.cwd
            }
            appState.lifecycleUpsertDaemonConversationSnapshot(restored.conversation)
            appState.lifecycleUpsertDaemonSessionSnapshot(
                sessionId: restoredRuntimeId,
                cwd: restored.conversation.cwd,
                state: restored.attachment.state,
                lastEventSeq: restored.attachment.bufferedEvents.last?.seq ?? 0,
                command: restored.conversation.command,
                title: appState.activeSession?.title ?? restored.conversation.title,
                updatedAt: Date()
            )
            Log.log(
                level: "warning",
                component: "ConversationLifecycle",
                "restored previous conversation after failed switch",
                traceId: traceId,
                sessionId: restoredRuntimeId
            )
        } catch {
            if let previousSessionId,
               appState.currentSessionId == previousSessionId {
                appState.currentSessionId = nil
            }
            Log.log(
                level: "warning",
                component: "ConversationLifecycle",
                "failed to restore previous conversation after switch failure: \(error.localizedDescription)",
                traceId: traceId,
                sessionId: previousSessionId
            )
        }
    }

    private static func shouldTreatAttachFailureAsSessionMissing(_ error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isSessionNotFound
    }

    private static func shouldTreatAttachFailureAsOwnershipConflict(_ error: Error) -> Bool {
        guard let acpError = error as? ACPError else { return false }
        return acpError.isSessionAlreadyAttachedByAnotherClient
    }
}
