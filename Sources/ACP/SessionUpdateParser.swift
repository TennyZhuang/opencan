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
            if let text = update?["content"]?["text"]?.stringValue {
                return .agentMessageDelta(text: text)
            }

        case "agent_message":
            if let text = update?["content"]?["text"]?.stringValue {
                return .agentMessage(text: text)
            }

        case "thought":
            if let text = update?["content"]?["text"]?.stringValue {
                return .thought(text: text)
            }

        case "agent_thought_chunk":
            if let text = update?["content"]?["text"]?.stringValue {
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
                } else if let contentArr = update?["content"]?.arrayValue {
                    var parts: [String] = []
                    for item in contentArr {
                        if let text = item["content"]?["text"]?.stringValue {
                            parts.append(text)
                        }
                    }
                    if !parts.isEmpty { outputText = parts.joined() }
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

        case "user_message_chunk":
            if let text = update?["content"]?["text"]?.stringValue {
                return .userMessage(text: text)
            }

        default:
            Log.toFile("[SessionUpdateParser] Unknown: \(updateType ?? "nil")")
        }

        return nil
    }
}
