import Foundation

@MainActor @Observable
final class ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var toolCalls: [ToolCallInfo]
    var isStreaming: Bool
    let timestamp: Date

    enum Role: String {
        case user, assistant, system
    }

    init(
        role: Role,
        content: String = "",
        toolCalls: [ToolCallInfo] = [],
        isStreaming: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        self.timestamp = Date()
    }
}
