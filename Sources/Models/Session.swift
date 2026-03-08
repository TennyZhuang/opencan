import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(originalName: "sessionId")
    var runtimeId: String

    /// Durable conversation identity. Backed by the historical `conversationId` column,
    /// with a one-time fallback from `canonicalSessionId` for migrated installs.
    @Attribute(originalName: "conversationId")
    var persistedConversationId: String?

    /// Migration-only fallback for older installs that persisted the stable identity
    /// under `canonicalSessionId`. New writes clear this field.
    @Attribute(originalName: "canonicalSessionId")
    var legacyCanonicalConversationId: String?

    @Attribute(originalName: "sessionCwd")
    var conversationCwd: String?

    var createdAt: Date
    var lastUsedAt: Date
    var title: String?
    /// Built-in agent identifier ("claude" / "codex") used for session creation.
    var agentID: String?
    /// ACP launch command that created the session.
    var agentCommand: String?

    var workspace: Workspace?

    init(
        runtimeId: String,
        conversationId: String? = nil,
        conversationCwd: String? = nil,
        agentID: String? = nil,
        agentCommand: String? = nil,
        workspace: Workspace? = nil
    ) {
        self.runtimeId = runtimeId
        self.persistedConversationId = Self.normalizedIdentity(conversationId)
        self.legacyCanonicalConversationId = nil
        self.conversationCwd = conversationCwd
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.agentID = agentID
        self.agentCommand = agentCommand
        self.workspace = workspace
    }

    var conversationId: String {
        get {
            Self.normalizedIdentity(persistedConversationId)
                ?? Self.normalizedIdentity(legacyCanonicalConversationId)
                ?? runtimeId
        }
        set {
            persistedConversationId = Self.normalizedIdentity(newValue) ?? runtimeId
            legacyCanonicalConversationId = nil
        }
    }

    private static func normalizedIdentity(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
