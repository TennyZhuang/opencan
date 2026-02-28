import Foundation

/// Defines canned response sequences for mock ACP testing.
enum MockScenario {
    /// Simple text reply, no tool calls.
    case simple
    /// Simple text reply but intentionally omits prompt_complete.
    case missingPromptComplete
    /// Reply with a tool call (e.g. Read file), then text after.
    case withToolCall
    /// Reply with extended thinking, then text.
    case withThought
    /// Reply with multiple tool calls and interleaved text.
    case complex
    /// Simulates an error mid-stream.
    case error
    /// Long streaming response for timeline/scroll stress tests.
    case longStream

    var steps: [MockStep] {
        switch self {
        case .simple:
            return [
                .delay(milliseconds: 100),
                .textDelta("Hello! "),
                .delay(milliseconds: 50),
                .textDelta("I'm the mock assistant. "),
                .delay(milliseconds: 50),
                .textDelta("How can I help you today?"),
                .delay(milliseconds: 50),
                .promptComplete(.endTurn),
            ]

        case .missingPromptComplete:
            return [
                .delay(milliseconds: 100),
                .textDelta("Hello! "),
                .delay(milliseconds: 50),
                .textDelta("I'm the mock assistant. "),
                .delay(milliseconds: 50),
                .textDelta("This stream intentionally omits prompt_complete."),
            ]

        case .withToolCall:
            return [
                .textDelta("Let me check that file for you."),
                .delay(milliseconds: 100),
                .toolCallStart(id: "tc-001", name: "Read"),
                .delay(milliseconds: 50),
                .toolCallUpdate(id: "tc-001", output: nil),
                .delay(milliseconds: 100),
                .toolCallComplete(id: "tc-001", output: "file contents here\nline 2\nline 3", failed: false),
                .delay(milliseconds: 100),
                .textDelta("The file contains 3 lines of content."),
                .delay(milliseconds: 50),
                .promptComplete(.endTurn),
            ]

        case .withThought:
            return [
                .delay(milliseconds: 100),
                .thoughtDelta("Let me think "),
                .delay(milliseconds: 50),
                .thoughtDelta("about this carefully..."),
                .delay(milliseconds: 100),
                .textDelta("After careful consideration, "),
                .delay(milliseconds: 50),
                .textDelta("here is my answer."),
                .delay(milliseconds: 50),
                .promptComplete(.endTurn),
            ]

        case .complex:
            return [
                .textDelta("I'll help with that. Let me look at the code."),
                .delay(milliseconds: 100),
                .toolCallStart(id: "tc-001", name: "Read"),
                .delay(milliseconds: 100),
                .toolCallComplete(id: "tc-001", output: "fn main() {\n    println!(\"hello\");\n}", failed: false),
                .delay(milliseconds: 100),
                .textDelta("Now let me make the change."),
                .delay(milliseconds: 100),
                .toolCallStart(id: "tc-002", name: "Edit"),
                .delay(milliseconds: 100),
                .toolCallComplete(id: "tc-002", output: "File updated successfully", failed: false),
                .delay(milliseconds: 100),
                .textDelta("Done! I've updated the file."),
                .delay(milliseconds: 50),
                .promptComplete(.endTurn),
            ]

        case .error:
            return [
                .textDelta("Working on it..."),
                .delay(milliseconds: 100),
                .toolCallStart(id: "tc-err", name: "Bash"),
                .delay(milliseconds: 100),
                .toolCallComplete(id: "tc-err", output: "Permission denied", failed: true),
                .delay(milliseconds: 100),
                .textDelta("The command failed due to a permission error."),
                .delay(milliseconds: 50),
                .promptComplete(.endTurn),
            ]
        case .longStream:
            var steps: [MockStep] = [
                .delay(milliseconds: 80),
                .textDelta("Starting long stream test.\n\n"),
            ]
            for index in 1 ... 40 {
                steps.append(.delay(milliseconds: 30))
                steps.append(.textDelta("Line \(index): The quick brown fox jumps over the lazy dog.\n"))
            }
            steps.append(.delay(milliseconds: 40))
            steps.append(.textDelta("\nEND_LONG_STREAM_TOKEN"))
            steps.append(.delay(milliseconds: 30))
            steps.append(.promptComplete(.endTurn))
            return steps
        }
    }
}

/// Individual steps that make up a mock scenario's notification stream.
enum MockStep {
    /// Yields an `agent_message_chunk` notification.
    case textDelta(String)
    /// Yields a `user_message_chunk` notification (for history replay).
    case userMessageChunk(String)
    /// Yields an `agent_thought_chunk` notification.
    case thoughtDelta(String)
    /// Yields a `tool_call` notification to start a tool call.
    case toolCallStart(id: String, name: String)
    /// Yields a `tool_call_update` notification with optional output.
    case toolCallUpdate(id: String, output: String?)
    /// Yields a `tool_call_update` with status=completed/failed.
    case toolCallComplete(id: String, output: String, failed: Bool)
    /// Pauses for the given duration to simulate latency.
    case delay(milliseconds: Int)
    /// Yields the `prompt_complete` notification.
    case promptComplete(StopReason)
}
