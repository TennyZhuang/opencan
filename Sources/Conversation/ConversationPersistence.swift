import Foundation
import SwiftData

enum ConversationPersistence {
    static func resolveSessionAgent(
        storedAgentID: String?,
        storedAgentCommand: String?,
        daemonCommand: String?
    ) -> (id: String, command: String) {
        let normalizedStoredCommand = normalizeOptionalAgentCommand(storedAgentCommand)
        let normalizedDaemonCommand = normalizeOptionalAgentCommand(daemonCommand)

        if let storedAgent = AgentCommandStore.agent(forAgentID: storedAgentID) {
            return (
                storedAgent.rawValue,
                normalizedStoredCommand
                    ?? normalizedDaemonCommand
                    ?? AgentCommandStore.command(for: storedAgent)
            )
        }

        if let normalizedDaemonCommand {
            let inferred = AgentCommandStore.inferAgent(fromCommand: normalizedDaemonCommand) ?? .claude
            return (inferred.rawValue, normalizedDaemonCommand)
        }

        if let normalizedStoredCommand {
            let inferred = AgentCommandStore.inferAgent(fromCommand: normalizedStoredCommand) ?? .claude
            return (inferred.rawValue, normalizedStoredCommand)
        }

        return (AgentKind.claude.rawValue, AgentCommandStore.command(for: .claude))
    }

    static func normalizeAgentCommand(_ command: String?, fallback: String) -> String {
        normalizeOptionalAgentCommand(command) ?? fallback
    }

    static func normalizeOptionalAgentCommand(_ command: String?) -> String? {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func resolveConversationID(
        forLegacySessionID sessionId: String,
        daemonConversations: [DaemonConversationInfo],
        modelContext: ModelContext
    ) -> String {
        let trimmedSessionID = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return sessionId }

        if let conversation = daemonConversations.first(where: { $0.conversationId == trimmedSessionID }) {
            return conversation.conversationId
        }
        if let conversation = daemonConversations.first(where: { $0.runtimeId == trimmedSessionID }) {
            return conversation.conversationId
        }

        let descriptor = FetchDescriptor<Session>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        if let local = sessions
            .filter({ $0.sessionId == trimmedSessionID || $0.stableConversationId == trimmedSessionID })
            .sorted(by: { $0.lastUsedAt > $1.lastUsedAt })
            .first {
            return local.stableConversationId
        }

        return trimmedSessionID
    }

    static func localSession(
        forConversationID conversationId: String,
        modelContext: ModelContext
    ) -> Session? {
        let trimmedConversationID = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Session>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        return sessions
            .filter { $0.stableConversationId == trimmedConversationID }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .first
    }

    static func backfillConversationIdentity(_ session: Session, conversationId: String? = nil) {
        let resolvedConversationID = (conversationId ?? session.stableConversationId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedConversationID.isEmpty else { return }
        if session.conversationId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            session.conversationId = resolvedConversationID
        }
        if resolvedConversationID != session.sessionId,
           session.canonicalSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            session.canonicalSessionId = resolvedConversationID
        }
    }

    static func createLocalSession(
        from result: DaemonConversationOpenResult,
        workspace: Workspace,
        agentID: String,
        command: String,
        modelContext: ModelContext
    ) -> Session {
        let conversationId = result.conversation.conversationId
        let runtimeId = result.attachment.runtimeId
        let session = Session(
            sessionId: runtimeId,
            conversationId: conversationId,
            canonicalSessionId: conversationId == runtimeId ? nil : conversationId,
            sessionCwd: workspace.path,
            agentID: agentID,
            agentCommand: command,
            workspace: workspace
        )
        modelContext.insert(session)
        try? modelContext.save()
        return session
    }

    static func upsertLocalSessionForOpen(
        result: DaemonConversationOpenResult,
        conversationId: String,
        existingSession: Session?,
        workspace: Workspace,
        sessionAgent: (id: String, command: String),
        modelContext: ModelContext
    ) -> Session {
        let runtimeId = result.attachment.runtimeId
        let resolvedCwd = (!result.conversation.cwd.isEmpty ? result.conversation.cwd : nil)
            ?? existingSession?.sessionCwd
            ?? workspace.path
        let resolvedCommand = normalizeAgentCommand(
            existingSession?.agentCommand,
            fallback: result.conversation.command ?? sessionAgent.command
        )

        let persistedSession: Session
        if let existingSession {
            existingSession.sessionId = runtimeId
            existingSession.conversationId = conversationId
            if conversationId != runtimeId, existingSession.canonicalSessionId == nil {
                existingSession.canonicalSessionId = conversationId
            }
            existingSession.sessionCwd = resolvedCwd
            existingSession.agentID = existingSession.agentID ?? sessionAgent.id
            existingSession.agentCommand = resolvedCommand
            existingSession.lastUsedAt = Date()
            backfillConversationIdentity(existingSession, conversationId: conversationId)
            persistedSession = existingSession
        } else {
            let session = Session(
                sessionId: runtimeId,
                conversationId: conversationId,
                canonicalSessionId: conversationId == runtimeId ? nil : conversationId,
                sessionCwd: resolvedCwd,
                agentID: sessionAgent.id,
                agentCommand: resolvedCommand,
                workspace: workspace
            )
            modelContext.insert(session)
            backfillConversationIdentity(session, conversationId: conversationId)
            persistedSession = session
        }
        try? modelContext.save()
        return persistedSession
    }

    static func markConversationUnavailable(
        conversationId: String,
        session: Session?,
        fallbackCwd: String,
        command: String?,
        daemonConversations: inout [DaemonConversationInfo]
    ) {
        let resolvedCwd = session?.sessionCwd ?? session?.workspace?.path ?? fallbackCwd
        let resolvedCommand = normalizeOptionalAgentCommand(command) ?? session?.agentCommand
        let conversation = DaemonConversationInfo(
            conversationId: conversationId,
            runtimeId: nil,
            state: "unavailable",
            cwd: resolvedCwd,
            command: resolvedCommand,
            title: session?.title,
            updatedAt: Date(),
            ownerId: nil,
            origin: "managed",
            lastEventSeq: 0
        )
        upsertDaemonConversationSnapshot(conversation, into: &daemonConversations)
    }

    static func upsertDaemonConversationSnapshot(
        _ conversation: DaemonConversationInfo,
        into daemonConversations: inout [DaemonConversationInfo]
    ) {
        if let index = daemonConversations.firstIndex(where: { $0.conversationId == conversation.conversationId }) {
            let existing = daemonConversations[index]
            daemonConversations[index] = DaemonConversationInfo(
                conversationId: conversation.conversationId,
                runtimeId: conversation.runtimeId ?? existing.runtimeId,
                state: conversation.state,
                cwd: conversation.cwd.isEmpty ? existing.cwd : conversation.cwd,
                command: conversation.command ?? existing.command,
                title: conversation.title ?? existing.title,
                updatedAt: conversation.updatedAt ?? existing.updatedAt,
                ownerId: conversation.ownerId ?? existing.ownerId,
                origin: conversation.origin ?? existing.origin,
                lastEventSeq: max(existing.lastEventSeq, conversation.lastEventSeq)
            )
            return
        }
        daemonConversations.append(conversation)
    }

    static func upsertDaemonSessionSnapshot(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?,
        updatedAt: Date,
        activeWorkspacePath: String?,
        daemonSessions: inout [DaemonSessionInfo]
    ) {
        if let index = daemonSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            let existing = daemonSessions[index]
            daemonSessions[index] = DaemonSessionInfo(
                sessionId: sessionId,
                cwd: cwd.isEmpty ? existing.cwd : cwd,
                state: state,
                lastEventSeq: max(existing.lastEventSeq, lastEventSeq),
                command: command ?? existing.command,
                title: title ?? existing.title,
                updatedAt: updatedAt
            )
            return
        }

        daemonSessions.append(
            DaemonSessionInfo(
                sessionId: sessionId,
                cwd: cwd.isEmpty ? (activeWorkspacePath ?? ".") : cwd,
                state: state,
                lastEventSeq: lastEventSeq,
                command: command,
                title: title,
                updatedAt: updatedAt
            )
        )
    }
}
