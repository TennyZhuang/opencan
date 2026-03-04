import Foundation

/// Information returned by daemon/hello.
struct DaemonInfo: Sendable {
    let daemonVersion: String
    let sessions: [DaemonSessionInfo]
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

/// Result of daemon/session.attach, including buffered events for replay.
struct DaemonAttachResult {
    let state: String
    let bufferedEvents: [DaemonBufferedEvent]
}

/// A single buffered event with its sequence number.
struct DaemonBufferedEvent {
    let seq: UInt64
    let event: JSONRPCMessage  // The original notification
}

/// Merged view of a daemon session and/or a local SwiftData Session.
struct UnifiedSession: Identifiable {
    let sessionId: String
    let daemonState: String?   // nil = not in daemon
    let cwd: String?
    let lastEventSeq: UInt64?
    let title: String?
    let daemonTitle: String?   // title from daemon (e.g., ACP session/list for external sessions)
    let lastUsedAt: Date?
    let daemonUpdatedAt: Date?
    let agentID: String?
    let agentCommand: String?
    var id: String { sessionId }

    var effectiveLastUsedAt: Date? { lastUsedAt ?? daemonUpdatedAt }

    init(
        sessionId: String,
        daemonState: String?,
        cwd: String?,
        lastEventSeq: UInt64?,
        title: String?,
        daemonTitle: String?,
        lastUsedAt: Date?,
        daemonUpdatedAt: Date? = nil,
        agentID: String?,
        agentCommand: String?
    ) {
        self.sessionId = sessionId
        self.daemonState = daemonState
        self.cwd = cwd
        self.lastEventSeq = lastEventSeq
        self.title = title
        self.daemonTitle = daemonTitle
        self.lastUsedAt = lastUsedAt
        self.daemonUpdatedAt = daemonUpdatedAt
        self.agentID = agentID
        self.agentCommand = agentCommand
    }

    /// If daemon snapshot misses a local session ID, keep it resumable-looking.
    /// Some ACP backends can still load history even when session/list omits it.
    var displayState: String { daemonState ?? "external" }
    /// Session rows stay actionable so takeover/recovery flows can be initiated in-UI.
    var isResumable: Bool { true }
    /// Placeholder sessions with no title/events are typically accidental.
    var isEmptyPlaceholder: Bool {
        let hasLocalTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasDaemonTitle = !(daemonTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasEvents = (lastEventSeq ?? 0) > 0
        let state = daemonState ?? "dead"
        let isRunning = state == "starting" || state == "prompting" || state == "draining"
        let isExternal = state == "external"
        return !hasLocalTitle && !hasDaemonTitle && !hasEvents && !isRunning && !isExternal
    }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let daemonTitle, !daemonTitle.isEmpty { return daemonTitle }
        return sessionId
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
