import Foundation

/// Parses session/update notifications into typed SessionEvents.
enum SessionUpdateParser {
    static func parse(_ notification: JSONRPCMessage) -> SessionEvent? {
        guard case .notification(let method, let params) = notification,
              method == ACPMethods.sessionUpdate,
              let params else { return nil }

        let eventType = params["type"]?.stringValue

        switch eventType {
        case "agent_message":
            if let text = params["message"]?["content"]?.stringValue
                ?? params["text"]?.stringValue {
                return .agentMessage(text: text)
            }

        case "agent_message_delta", "text_delta":
            if let text = params["delta"]?.stringValue
                ?? params["text"]?.stringValue {
                return .agentMessageDelta(text: text)
            }

        case "tool_call", "tool_use":
            if let id = params["id"]?.stringValue
                ?? params["toolCallId"]?.stringValue,
               let name = params["name"]?.stringValue
                ?? params["toolName"]?.stringValue {
                return .toolCall(
                    id: id, name: name,
                    input: params["input"]
                )
            }

        case "tool_call_update", "tool_result":
            if let id = params["id"]?.stringValue
                ?? params["toolCallId"]?.stringValue,
               let output = params["output"]?.stringValue
                ?? params["result"]?.stringValue {
                return .toolCallUpdate(id: id, output: output)
            }

        case "tool_call_complete":
            if let id = params["id"]?.stringValue
                ?? params["toolCallId"]?.stringValue {
                return .toolCallComplete(id: id)
            }

        case "thought":
            if let text = params["text"]?.stringValue {
                return .thought(text: text)
            }

        case "prompt_complete":
            let reason = params["stopReason"]?.stringValue ?? "end_turn"
            return .promptComplete(stopReason: StopReason(rawValue: reason) ?? .unknown)

        default:
            print("[SessionUpdateParser] Unknown event type: \(eventType ?? "nil")")
        }

        return nil
    }
}