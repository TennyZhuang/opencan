import Foundation

/// Mock ACP transport for offline UI testing.
/// Receives JSON-RPC requests via `send()`, parses the method, and yields
/// appropriate responses + `session/update` notifications to its `messages` stream.
actor MockACPTransport: ACPTransport {
    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let messages: AsyncStream<JSONRPCMessage>
    private var scenario: MockScenario
    private var isClosed = false

    init(scenario: MockScenario = .simple) {
        self.scenario = scenario
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.messages = stream
        self.messageContinuation = cont
    }

    func send(_ message: JSONRPCMessage) async throws {
        guard !isClosed else { throw TransportError.notConnected }

        switch message {
        case .request(let id, let method, let params):
            await handleRequest(id: id, method: method, params: params)
        case .response, .notification, .error:
            // Responses from ACPClient (e.g. permission replies) — no action needed
            break
        }
    }

    func close() {
        isClosed = true
        messageContinuation.finish()
    }

    // MARK: - Request Handling

    private func handleRequest(
        id: JSONRPCMessage.JSONRPCID,
        method: String,
        params: JSONValue?
    ) async {
        switch method {
        case ACPMethods.initialize:
            let result: JSONValue = .object([
                "protocolVersion": .int(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true)
                ]),
                "agentInfo": .object([
                    "name": .string("mock-agent"),
                    "version": .string("1.0.0")
                ])
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case ACPMethods.sessionNew:
            let sessionId = "mock-sess-\(UUID().uuidString.prefix(8))"
            let result: JSONValue = .object([
                "sessionId": .string(sessionId)
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case ACPMethods.sessionList:
            let result: JSONValue = .object([
                "sessions": .array([
                    .object([
                        "sessionId": .string("mock-prev-session"),
                        "cwd": .string(params?["cwd"]?.stringValue ?? "/tmp"),
                        "title": .string("Previous mock session")
                    ])
                ])
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case ACPMethods.sessionLoad:
            messageContinuation.yield(.response(id: id, result: .object([:])))

        case ACPMethods.sessionPrompt:
            let sessionId = params?["sessionId"]?.stringValue ?? "unknown"
            // Stream scenario notifications, then respond
            await streamScenario(requestId: id, sessionId: sessionId)

        default:
            messageContinuation.yield(
                .error(id: id, code: -32601, message: "Method not found: \(method)", data: nil)
            )
        }
    }

    // MARK: - Scenario Streaming

    private func streamScenario(
        requestId: JSONRPCMessage.JSONRPCID,
        sessionId: String
    ) async {
        for step in scenario.steps {
            guard !isClosed else { return }

            switch step {
            case .delay(let ms):
                try? await Task.sleep(for: .milliseconds(ms))

            case .textDelta(let text):
                yieldSessionUpdate(sessionId: sessionId, update: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]))

            case .thoughtDelta(let text):
                yieldSessionUpdate(sessionId: sessionId, update: .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ]))

            case .toolCallStart(let id, let name):
                yieldSessionUpdate(sessionId: sessionId, update: .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string(id),
                    "title": .string(name),
                    "kind": .string("tool_use"),
                    "status": .string("running"),
                    "rawInput": .null
                ]))

            case .toolCallUpdate(let id, let output):
                var updateObj: [String: JSONValue] = [
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string(id),
                    "status": .string("running"),
                ]
                if let output {
                    updateObj["rawOutput"] = .string(output)
                }
                yieldSessionUpdate(sessionId: sessionId, update: .object(updateObj))

            case .toolCallComplete(let id, let output, let failed):
                yieldSessionUpdate(sessionId: sessionId, update: .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string(id),
                    "status": .string(failed ? "failed" : "completed"),
                    "rawOutput": .string(output)
                ]))

            case .promptComplete(let reason):
                yieldSessionUpdate(sessionId: sessionId, update: .object([
                    "sessionUpdate": .string("prompt_complete"),
                    "stopReason": .string(reason.rawValue)
                ]))
            }
        }

        // Finally, yield the response to resolve the sendPrompt() call
        let result: JSONValue = .object([
            "stopReason": .string("end_turn")
        ])
        messageContinuation.yield(.response(id: requestId, result: result))
    }

    private func yieldSessionUpdate(sessionId: String, update: JSONValue) {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "update": update
        ])
        messageContinuation.yield(.notification(method: ACPMethods.sessionUpdate, params: params))
    }

    // MARK: - Scenario Control

    /// Change the scenario for subsequent prompts.
    func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }
}
