import Foundation

/// Parses session/update notifications into typed SessionEvents.
/// ACP spec: params.update.sessionUpdate is the discriminator.
enum SessionUpdateParser {
    static func parse(_ notification: JSONRPCMessage) -> SessionEvent? {
        guard case .notification(let method, let params) = notification,
              method == ACPMethods.sessionUpdate,
              let params else { return nil }

        let update = params["update"]
        let updateType = update?["sessionUpdate"]?.stringValue

        switch updateType {
        case "agent_message_chunk":
            if let text = extractText(from: update?["content"]) {
                return .agentMessageDelta(text: text)
            }

        case "agent_message":
            if let text = extractText(from: update?["content"]) {
                return .agentMessage(text: text)
            }

        case "thought":
            if let text = extractText(from: update?["content"]) {
                return .thought(text: text)
            }

        case "agent_thought_chunk":
            if let text = extractText(from: update?["content"]) {
                return .thoughtDelta(text: text)
            }

        case "tool_call":
            if let id = update?["toolCallId"]?.stringValue {
                let name = update?["title"]?.stringValue ?? "tool"
                let input = update?["rawInput"]
                return .toolCall(id: id, name: name, input: input)
            }

        case "tool_call_update":
            if let id = update?["toolCallId"]?.stringValue {
                let status = update?["status"]?.stringValue

                // Extract title update
                let title = update?["title"]?.stringValue

                // Extract rawInput if present (often arrives here, not on tool_call)
                let rawInput = update?["rawInput"]

                // Extract output from rawOutput or content array
                var outputText: String?
                if let raw = update?["rawOutput"]?.stringValue {
                    outputText = raw
                } else if let contentText = extractText(from: update?["content"]) {
                    outputText = contentText
                }

                if status == "completed" || status == "failed" {
                    return .toolCallComplete(
                        id: id, title: title,
                        input: rawInput, output: outputText,
                        failed: status == "failed"
                    )
                } else {
                    return .toolCallUpdate(
                        id: id, title: title,
                        input: rawInput, output: outputText
                    )
                }
            }

        case "prompt_complete":
            let rawReason = update?["stopReason"]?.stringValue ?? "end_turn"
            let reason = StopReason(rawValue: rawReason) ?? .unknown
            return .promptComplete(stopReason: reason)

        case "plan", "available_commands_update", "mode_update":
            return nil

        case "user_message", "user_message_chunk":
            if let text = extractText(from: update?["content"]) {
                return .userMessage(text: text)
            }

        default:
            Log.toFile("[SessionUpdateParser] Unknown: \(updateType ?? "nil")")
        }

        return nil
    }

    /// Extract text from ACP content payloads that may be:
    /// - a plain string
    /// - a single content object ({type: "text", text: ...})
    /// - an array of content objects
    private static func extractText(from value: JSONValue?) -> String? {
        guard let value else { return nil }

        switch value {
        case .string(let text):
            return text

        case .object(let object):
            if let text = object["text"]?.stringValue {
                return text
            }
            if let nestedContent = object["content"] {
                return extractText(from: nestedContent)
            }
            return nil

        case .array(let array):
            let parts = array.compactMap { extractText(from: $0) }
            guard !parts.isEmpty else { return nil }
            return parts.joined()

        default:
            return nil
        }
    }
}
