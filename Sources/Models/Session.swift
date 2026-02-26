import Foundation
import SwiftData

@Model
final class Session {
    var sessionId: String
    /// CWD used to load `sessionId` from disk.
    var sessionCwd: String?
    /// Original conversation ID used for history recovery when `sessionId`
    /// points to a transient recovered daemon session.
    var historySessionId: String?
    /// CWD used to load `historySessionId` from disk.
    var historySessionCwd: String?
    var createdAt: Date
    var lastUsedAt: Date
    var title: String?

    var workspace: Workspace?

    init(
        sessionId: String,
        sessionCwd: String? = nil,
        historySessionId: String? = nil,
        historySessionCwd: String? = nil,
        workspace: Workspace? = nil
    ) {
        self.sessionId = sessionId
        self.sessionCwd = sessionCwd
        self.historySessionId = historySessionId
        self.historySessionCwd = historySessionCwd
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.workspace = workspace
    }
}
