import Foundation

struct ToolCallInfo: Identifiable {
    let id: String
    var name: String
    var input: JSONValue?
    var output: String?
    var isComplete: Bool
    var isFailed: Bool

    init(id: String, name: String, input: JSONValue? = nil, output: String? = nil, isComplete: Bool = false, isFailed: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.isComplete = isComplete
        self.isFailed = isFailed
    }
}

enum StopReason: String {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case unknown
}

/// Events parsed from session/update notifications
enum SessionEvent {
    case agentMessage(text: String)
    case agentMessageDelta(text: String)
    case toolCall(id: String, name: String, input: JSONValue?)
    case toolCallUpdate(id: String, title: String?, input: JSONValue?, output: String?)
    case toolCallComplete(id: String, title: String?, input: JSONValue?, output: String?, failed: Bool)
    case thought(text: String)
    case promptComplete(stopReason: StopReason)
}
