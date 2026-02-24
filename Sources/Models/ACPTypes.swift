import Foundation

struct SessionInfo: Codable, Identifiable {
    let sessionId: String
    var id: String { sessionId }
}

struct ToolCallInfo: Identifiable, Codable {
    let id: String
    let name: String
    var input: JSONValue?
    var output: String?
    var isComplete: Bool

    init(id: String, name: String, input: JSONValue? = nil, output: String? = nil, isComplete: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.isComplete = isComplete
    }
}

enum StopReason: String, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = StopReason(rawValue: value) ?? .unknown
    }
}

/// Events parsed from session/update notifications
enum SessionEvent {
    case agentMessage(text: String)
    case agentMessageDelta(text: String)
    case toolCall(id: String, name: String, input: JSONValue?)
    case toolCallUpdate(id: String, output: String)
    case toolCallComplete(id: String)
    case thought(text: String)
    case promptComplete(stopReason: StopReason)
}
