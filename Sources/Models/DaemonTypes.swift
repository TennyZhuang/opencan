import Foundation

/// Information returned by daemon/hello.
struct DaemonInfo {
    let daemonVersion: String
    let sessions: [DaemonSessionInfo]
}

/// Snapshot of a daemon-managed session.
struct DaemonSessionInfo: Identifiable {
    let sessionId: String
    let cwd: String
    let state: String      // "starting", "idle", "prompting", "draining", "completed", "dead", "external"
    let lastEventSeq: UInt64
    let command: String?
    let title: String?

    var id: String { sessionId }
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
    let agentID: String?
    let agentCommand: String?
    var id: String { sessionId }

    var displayState: String { daemonState ?? "history" }
    /// Even dead daemon sessions are resumable via history recovery.
    var isResumable: Bool { true }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let daemonTitle, !daemonTitle.isEmpty { return daemonTitle }
        return String(sessionId.prefix(8))
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
