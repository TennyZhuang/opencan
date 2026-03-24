import Foundation

enum ConversationAttachmentTurnState: String, Equatable {
    case idle
    case prompting
    case draining
}

/// Derived view of the active conversation attachment.
/// This intentionally adapts the current `AppState` fields without yet
/// becoming the single writable source of truth.
enum ConversationAttachmentState: Equatable {
    case none
    case attached(
        conversationId: String,
        runtimeId: String,
        turnState: ConversationAttachmentTurnState
    )
    case recovering(
        conversationId: String,
        lastKnownRuntimeId: String?,
        lastEventSeq: UInt64,
        transportState: AppState.ConnectionStatus
    )
    case unavailable(conversationId: String)

    var conversationId: String? {
        switch self {
        case .none:
            return nil
        case .attached(let conversationId, _, _),
             .recovering(let conversationId, _, _, _),
             .unavailable(let conversationId):
            return conversationId
        }
    }

    var runtimeId: String? {
        switch self {
        case .attached(_, let runtimeId, _):
            return runtimeId
        case .recovering(_, let lastKnownRuntimeId, _, _):
            return lastKnownRuntimeId
        case .none, .unavailable:
            return nil
        }
    }

    var showsReconnectOverlay: Bool {
        if case .recovering = self {
            return true
        }
        return false
    }

    var allowsPromptSend: Bool {
        if case .attached = self {
            return true
        }
        return false
    }

    static func derive(
        connectionStatus: AppState.ConnectionStatus,
        activeSession: Session?,
        currentSessionId: String?,
        daemonConversations: [DaemonConversationInfo],
        daemonSessions: [DaemonSessionInfo],
        isPrompting: Bool,
        shouldAutoReconnectInterruptedSession: Bool,
        isAutoReconnectInProgress: Bool,
        lastEventSeqByRuntimeID: [String: UInt64]
    ) -> ConversationAttachmentState {
        let conversationId = normalizedID(activeSession?.conversationId) ?? normalizedID(currentSessionId)
        let runtimeId = normalizedID(currentSessionId) ?? normalizedID(activeSession?.runtimeId)

        if shouldAutoReconnectInterruptedSession || isAutoReconnectInProgress {
            guard let conversationId else { return .none }
            let lastEventSeq = runtimeId.flatMap { lastEventSeqByRuntimeID[$0] } ?? 0
            return .recovering(
                conversationId: conversationId,
                lastKnownRuntimeId: runtimeId,
                lastEventSeq: lastEventSeq,
                transportState: connectionStatus
            )
        }

        if let conversationId,
           let daemonConversationState = daemonConversations
            .first(where: { $0.conversationId == conversationId })
            .map(\.state)
           .flatMap(normalizedState),
           daemonConversationState == "unavailable" || daemonConversationState == "dead" {
            return .unavailable(conversationId: conversationId)
        }

        guard connectionStatus == .connected else {
            return .none
        }

        guard let conversationId, let runtimeId else {
            return .none
        }

        let daemonState = daemonSessions.first(where: { $0.sessionId == runtimeId })?.state
            ?? daemonConversations.first(where: { $0.conversationId == conversationId })?.state
        let turnState = deriveTurnState(
            daemonState: daemonState,
            isPrompting: isPrompting
        )
        return .attached(
            conversationId: conversationId,
            runtimeId: runtimeId,
            turnState: turnState
        )
    }

    private static func deriveTurnState(
        daemonState: String?,
        isPrompting: Bool
    ) -> ConversationAttachmentTurnState {
        if let normalizedDaemonState = normalizedState(daemonState) {
            if normalizedDaemonState == "draining" {
                return .draining
            }
            if normalizedDaemonState == "starting" || normalizedDaemonState == "prompting" {
                return .prompting
            }
        }
        if isPrompting {
            return .prompting
        }
        return .idle
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedState(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
