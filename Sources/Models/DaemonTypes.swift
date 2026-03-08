import Foundation

/// Information returned by daemon/hello.
struct DaemonInfo: Sendable {
    let daemonVersion: String
    let sessions: [DaemonSessionInfo]
}

/// Conversation-centric daemon snapshot exposed by daemon/conversation.* APIs.
struct DaemonConversationInfo: Identifiable, Codable, Sendable {
    let conversationId: String
    let runtimeId: String?
    let state: String
    let cwd: String
    let command: String?
    let title: String?
    let updatedAt: Date?
    let ownerId: String?
    let origin: String?
    let lastEventSeq: UInt64

    var id: String { conversationId }
}

/// Attachment details returned by daemon/conversation.create and open.
struct DaemonConversationAttachment: Sendable {
    let runtimeId: String
    let state: String
    let bufferedEvents: [DaemonBufferedEvent]
    let reusedRuntime: Bool
    let restoredFromHistory: Bool
}

/// Result of daemon/conversation.create and open.
struct DaemonConversationOpenResult: Sendable {
    let conversation: DaemonConversationInfo
    let attachment: DaemonConversationAttachment
}

/// Agent command availability on the connected node.
struct DaemonAgentAvailability: Equatable, Sendable {
    let id: String
    let command: String
    let available: Bool
}

/// Snapshot of a daemon-managed session.
struct DaemonSessionInfo: Identifiable, Codable, Sendable {
    let sessionId: String
    let cwd: String
    let state: String      // "starting", "idle", "prompting", "draining", "completed", "dead", "external"
    let lastEventSeq: UInt64
    let command: String?
    let title: String?
    let updatedAt: Date?

    init(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?,
        updatedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.state = state
        self.lastEventSeq = lastEventSeq
        self.command = command
        self.title = title
        self.updatedAt = updatedAt
    }

    var id: String { sessionId }
}

/// A structured daemon log line returned by daemon/logs.
struct DaemonLogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: String
    let level: String
    let message: String
    let attrs: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: String,
        level: String,
        message: String,
        attrs: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.attrs = attrs
    }
}

/// A single buffered event with its sequence number.
struct DaemonBufferedEvent {
    let seq: UInt64
    let event: JSONRPCMessage  // The original notification
}

/// Merged view of a daemon conversation row and/or a local SwiftData cache.
struct UnifiedSession: Identifiable {
    let conversationId: String
    let runtimeId: String?
    let daemonState: String?   // nil = local-only cache row
    let cwd: String?
    let lastEventSeq: UInt64?
    let title: String?
    let daemonTitle: String?
    let lastUsedAt: Date?
    let daemonUpdatedAt: Date?
    let agentID: String?
    let agentCommand: String?
    let hasLocalRecord: Bool
    var id: String { conversationId }

    var effectiveLastUsedAt: Date? { lastUsedAt ?? daemonUpdatedAt }
    var effectiveRuntimeId: String? { runtimeId }

    init(
        conversationId: String,
        runtimeId: String? = nil,
        daemonState: String?,
        cwd: String?,
        lastEventSeq: UInt64?,
        title: String?,
        daemonTitle: String?,
        lastUsedAt: Date?,
        daemonUpdatedAt: Date? = nil,
        agentID: String?,
        agentCommand: String?,
        hasLocalRecord: Bool = false
    ) {
        self.conversationId = conversationId
        self.runtimeId = runtimeId
        self.daemonState = daemonState
        self.cwd = cwd
        self.lastEventSeq = lastEventSeq
        self.title = title
        self.daemonTitle = daemonTitle
        self.lastUsedAt = lastUsedAt
        self.daemonUpdatedAt = daemonUpdatedAt
        self.agentID = agentID
        self.agentCommand = agentCommand
        self.hasLocalRecord = hasLocalRecord
    }

    /// Local cache rows stay actionable even when currently unavailable.
    var displayState: String { daemonState ?? "unavailable" }
    var isResumable: Bool { true }

    /// Placeholder rows without any visible metadata are usually accidental.
    var isEmptyPlaceholder: Bool {
        let hasLocalTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasDaemonTitle = !(daemonTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasEvents = (lastEventSeq ?? 0) > 0
        let state = displayState
        let isMeaningfulState = [
            "attached", "running", "restorable", "unavailable",
            "prompting", "draining", "starting", "external", "dead"
        ].contains(state)
        if hasLocalRecord && daemonState == nil {
            return false
        }
        return !hasLocalTitle && !hasDaemonTitle && !hasEvents && !isMeaningfulState
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let daemonTitle, !daemonTitle.isEmpty { return daemonTitle }
        return conversationId
    }

    var agentDisplayName: String? {
        if let known = AgentCommandStore.agent(forAgentID: agentID)?.displayName {
            return known
        }
        if let inferred = AgentCommandStore.inferAgent(fromCommand: agentCommand) {
            return inferred.displayName
        }
        guard let agentID, !agentID.isEmpty else { return nil }
        return agentID
    }
}
