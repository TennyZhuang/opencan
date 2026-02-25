import Foundation
import SwiftData

@Model
final class Session {
    var sessionId: String
    var createdAt: Date
    var lastUsedAt: Date
    var title: String?

    var workspace: Workspace?

    init(sessionId: String, workspace: Workspace? = nil) {
        self.sessionId = sessionId
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.workspace = workspace
    }
}
