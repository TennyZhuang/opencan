import Foundation
import SwiftData

@Model
final class Session {
    var sessionId: String
    /// CWD used to load `sessionId` from disk.
    var sessionCwd: String?
    var createdAt: Date
    var lastUsedAt: Date
    var title: String?
    /// Built-in agent identifier ("claude" / "codex") used for session creation.
    var agentID: String?
    /// ACP launch command that created the session.
    var agentCommand: String?

    var workspace: Workspace?

    init(
        sessionId: String,
        sessionCwd: String? = nil,
        agentID: String? = nil,
        agentCommand: String? = nil,
        workspace: Workspace? = nil
    ) {
        self.sessionId = sessionId
        self.sessionCwd = sessionCwd
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.agentID = agentID
        self.agentCommand = agentCommand
        self.workspace = workspace
    }
}
