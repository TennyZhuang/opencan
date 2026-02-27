import Foundation

/// Mock ACP transport for offline UI testing.
/// Receives JSON-RPC requests via `send()`, parses the method, and yields
/// appropriate responses + `session/update` notifications to its `messages` stream.
/// Supports both daemon protocol methods and ACP passthrough.
actor MockACPTransport: ACPTransport {
    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let messages: AsyncStream<JSONRPCMessage>
    private var scenario: MockScenario
    private var isClosed = false
    private var mockSessionId: String?

    /// Configurable attach result for testing different resume strategies.
    var mockAttachState: String = "idle"
    var mockAttachBufferedEvents: [[String: JSONValue]] = []

    /// Configurable session list for testing daemon state re-check.
    var mockSessionList: [[String: JSONValue]] = []

    /// If true, sessionAttach returns an error (simulates unknown session).
    var mockAttachShouldFail = false

    /// Steps to stream during session/load (simulates history replay).
    var mockLoadSteps: [MockStep] = []
    /// Session IDs that should fail on session/load (simulates load errors).
    var mockLoadFailSessionIDs: Set<String> = []
    /// Specific (sessionId, cwd) pairs that should fail on session/load.
    /// Format: "\(sessionId)|\(cwd)".
    var mockLoadFailSessionCwdPairs: Set<String> = []
    /// Tracks the most recent session/load params for assertions.
    var lastLoadSessionId: String?
    var lastLoadRouteToSessionId: String?
    var lastLoadCwd: String?

    /// Track last received method for test assertions.
    var lastReceivedMethod: String?

    /// Track all received methods in order.
    var receivedMethods: [String] = []
    /// Track detached session IDs in order.
    var detachedSessionIds: [String] = []
    /// Optional one-shot error injected for the next session/prompt request.
    var nextPromptError: (code: Int, message: String, data: JSONValue?)?

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
            lastReceivedMethod = method
            receivedMethods.append(method)
            await handleRequest(id: id, method: method, params: params)
        case .response, .notification, .error:
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
        // Daemon protocol methods
        case DaemonMethods.hello:
            let result: JSONValue = .object([
                "daemonVersion": .string("mock-0.1.0"),
                "sessions": .array(mockSessionList.map { .object($0) })
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case DaemonMethods.sessionCreate:
            let sessionId = "mock-sess-\(UUID().uuidString.prefix(8))"
            self.mockSessionId = sessionId
            let result: JSONValue = .object([
                "sessionId": .string(sessionId)
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case DaemonMethods.sessionAttach:
            if mockAttachShouldFail {
                messageContinuation.yield(
                    .error(id: id, code: -32000, message: "Session not found", data: nil)
                )
                // Reset after first failure so subsequent attaches succeed
                mockAttachShouldFail = false
                return
            }
            let bufferedArr: [JSONValue] = mockAttachBufferedEvents.map { .object($0) }
            let result: JSONValue = .object([
                "state": .string(mockAttachState),
                "bufferedEvents": .array(bufferedArr)
            ])
            messageContinuation.yield(.response(id: id, result: result))

        case DaemonMethods.sessionDetach:
            if let sessionId = params?["sessionId"]?.stringValue {
                detachedSessionIds.append(sessionId)
            }
            messageContinuation.yield(.response(id: id, result: .object([:])))

        case DaemonMethods.sessionList:
            messageContinuation.yield(.response(id: id, result: .object([
                "sessions": .array(mockSessionList.map { .object($0) })
            ])))

        case DaemonMethods.sessionKill:
            messageContinuation.yield(.response(id: id, result: .object([:])))

        // ACP passthrough (daemon forwards transparently)
        case ACPMethods.sessionPrompt:
            let sessionId = params?["sessionId"]?.stringValue ?? mockSessionId ?? "unknown"
            if let promptError = nextPromptError {
                nextPromptError = nil
                messageContinuation.yield(
                    .error(
                        id: id,
                        code: promptError.code,
                        message: promptError.message,
                        data: promptError.data
                    )
                )
                return
            }
            await streamScenario(requestId: id, sessionId: sessionId)

        case ACPMethods.sessionLoad:
            let sessionId = params?["sessionId"]?.stringValue ?? mockSessionId ?? "unknown"
            let routeToSessionId = params?["__routeToSession"]?.stringValue
            let cwd = params?["cwd"]?.stringValue ?? ""
            lastLoadSessionId = sessionId
            lastLoadRouteToSessionId = routeToSessionId
            lastLoadCwd = cwd
            let failKey = "\(sessionId)|\(cwd)"
            if mockLoadFailSessionIDs.contains(sessionId) || mockLoadFailSessionCwdPairs.contains(failKey) {
                messageContinuation.yield(
                    .error(id: id, code: -32603, message: "Internal error", data: .object([
                        "details": .string("Session not found")
                    ]))
                )
                return
            }
            await streamLoadHistory(requestId: id, sessionId: sessionId)

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
            await executeStep(step, sessionId: sessionId)
        }

        let result: JSONValue = .object([
            "stopReason": .string("end_turn")
        ])
        messageContinuation.yield(.response(id: requestId, result: result))
    }

    /// Stream history events during session/load, then return response.
    private func streamLoadHistory(
        requestId: JSONRPCMessage.JSONRPCID,
        sessionId: String
    ) async {
        for step in mockLoadSteps {
            guard !isClosed else { return }
            await executeStep(step, sessionId: sessionId)
        }

        let result: JSONValue = .object([
            "sessionId": .string(sessionId)
        ])
        messageContinuation.yield(.response(id: requestId, result: result))
    }

    private func executeStep(_ step: MockStep, sessionId: String) async {
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

        case .userMessageChunk(let text):
            yieldSessionUpdate(sessionId: sessionId, update: .object([
                "sessionUpdate": .string("user_message_chunk"),
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

    /// Testing hook: inject a session/update text delta notification.
    func emitSessionTextDeltaForTest(sessionId: String, text: String, seq: Int? = nil) {
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ])
        ]
        if let seq {
            params["__seq"] = .int(seq)
        }
        messageContinuation.yield(
            .notification(method: ACPMethods.sessionUpdate, params: .object(params))
        )
    }
}
