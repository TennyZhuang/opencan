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

    /// Configurable attach result for testing different open/reconnect strategies.
    var mockAttachState: String = "idle"
    var mockAttachBufferedEvents: [[String: JSONValue]] = []

    /// Configurable session/runtime list for testing daemon state re-check.
    var mockSessionList: [[String: JSONValue]] = []
    /// Configurable conversation list for picker/open flows. If empty, a
    /// conversation-centric view is derived from `mockSessionList`.
    var mockConversationList: [[String: JSONValue]] = []

    /// If true, conversation open returns an error (simulates unknown session).
    var mockAttachShouldFail = false
    /// Optional attach error override for `daemon/conversation.open`.
    var mockAttachError: (code: Int, message: String, data: JSONValue?)?
    /// Optional one-shot attach error injected for the next `daemon/conversation.open`.
    var nextAttachError: (code: Int, message: String, data: JSONValue?)?

    /// Steps to stream during session/load (simulates history replay).
    var mockLoadSteps: [MockStep] = []
    /// Session IDs that should fail on session/load (simulates load errors).
    var mockLoadFailSessionIDs: Set<String> = []
    /// Specific (sessionId, cwd) pairs that should fail on session/load.
    /// Format: "\(sessionId)|\(cwd)".
    var mockLoadFailSessionCwdPairs: Set<String> = []
    /// If true, session/load receives no response (simulates upstream hang).
    var mockLoadShouldHang = false
    /// Optional one-shot error injected for the next session/load request.
    var nextLoadError: (code: Int, message: String, data: JSONValue?)?
    /// Tracks the most recent session/load params for assertions.
    var lastLoadSessionId: String?
    var lastLoadCwd: String?
    /// Tracks the most recent `daemon/conversation.create` parameters.
    var lastCreateCwd: String?
    var lastCreateCommand: String?
    /// Tracks all `daemon/conversation.create` commands in order.
    var createCommands: [String] = []
    /// Tracks the most recent `daemon/conversation.open` params.
    var lastAttachSessionId: String?
    var lastAttachLastEventSeq: UInt64?
    /// Tracks the most recent daemon/conversation.open params.
    var lastOpenConversationId: String?
    var lastOpenLastRuntimeId: String?
    /// Tracks the most recent session/prompt content blocks.
    var lastPromptSessionId: String?
    var lastPromptBlocks: [JSONValue]?

    /// Track last received method for test assertions.
    var lastReceivedMethod: String?

    /// Track all received methods in order.
    var receivedMethods: [String] = []
    /// Track detached session IDs in order.
    var detachedSessionIds: [String] = []
    /// Track killed session IDs in order.
    var killedSessionIds: [String] = []
    /// Optional one-shot error injected for the next session/prompt request.
    var nextPromptError: (code: Int, message: String, data: JSONValue?)?
    /// If true, session/prompt request receives no updates and no response.
    var mockPromptShouldHang = false
    /// If true, session/prompt streams updates but intentionally drops terminal response.
    var mockDropPromptResponse = false
    /// Optional per-agent probe results. If absent, probes default to available.
    var mockAgentAvailabilityByID: [String: Bool] = [:]
    /// If true, daemon/agent.probe returns method not found.
    var mockAgentProbeUnsupported = false
    /// Configurable daemon/logs payload.
    var mockDaemonLogs: [[String: JSONValue]] = []

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

        case DaemonMethods.agentProbe:
            if mockAgentProbeUnsupported {
                messageContinuation.yield(
                    .error(id: id, code: -32601, message: "Method not found: \(DaemonMethods.agentProbe)", data: nil)
                )
                return
            }
            let requestedAgents = params?["agents"]?.arrayValue ?? []
            let results = requestedAgents.compactMap { agent -> JSONValue? in
                guard let id = agent["id"]?.stringValue else { return nil }
                let command = agent["command"]?.stringValue ?? ""
                let available = mockAgentAvailabilityByID[id] ?? true
                return .object([
                    "id": .string(id),
                    "command": .string(command),
                    "available": .bool(available)
                ])
            }
            messageContinuation.yield(.response(id: id, result: .object([
                "agents": .array(results)
            ])))

        case DaemonMethods.conversationCreate:
            lastCreateCwd = params?["cwd"]?.stringValue
            lastCreateCommand = params?["command"]?.stringValue
            if let cmd = lastCreateCommand {
                createCommands.append(cmd)
            }
            let runtimeId = "mock-sess-\(UUID().uuidString.prefix(8))"
            self.mockSessionId = runtimeId
            let conversation = makeConversationValue(
                conversationId: runtimeId,
                runtimeId: runtimeId,
                state: "attached",
                cwd: lastCreateCwd ?? "",
                command: lastCreateCommand,
                title: nil,
                lastEventSeq: 0,
                origin: "managed"
            )
            upsertMockConversation(conversationId: runtimeId, value: conversation)
            upsertMockSession(
                sessionId: runtimeId,
                cwd: lastCreateCwd ?? "",
                state: mockAttachState,
                lastEventSeq: 0,
                command: lastCreateCommand,
                title: nil
            )
            let bufferedArr = decoratedBufferedEvents(mockAttachBufferedEvents, runtimeId: runtimeId, conversationId: runtimeId)
            messageContinuation.yield(.response(id: id, result: .object([
                "conversation": conversation,
                "attachment": .object([
                    "runtimeId": .string(runtimeId),
                    "state": .string(mockAttachState),
                    "bufferedEvents": .array(bufferedArr),
                    "reusedRuntime": .bool(false),
                    "restoredFromHistory": .bool(false)
                ])
            ])))

        case DaemonMethods.conversationOpen:
            let conversationId = params?["conversationId"]?.stringValue ?? ""
            let preferredCommand = params?["preferredCommand"]?.stringValue
            let cwdHint = params?["cwdHint"]?.stringValue ?? ""
            lastOpenConversationId = conversationId
            lastOpenLastRuntimeId = params?["lastRuntimeId"]?.stringValue

            var conversation = conversationValue(for: conversationId)
            if conversation == nil {
                let synthesizedState: String = switch mockAttachState {
                case "starting", "prompting", "draining": "running"
                default: "attached"
                }
                conversation = [
                    "conversationId": .string(conversationId),
                    "runtimeId": .string(conversationId),
                    "state": .string(synthesizedState),
                    "cwd": .string(cwdHint),
                    "lastEventSeq": .int(0),
                    "origin": .string("managed")
                ]
            }
            guard let conversation else {
                messageContinuation.yield(
                    .error(id: id, code: -32000, message: "conversation not found: \(conversationId)", data: nil)
                )
                return
            }
            if let nextAttachError {
                self.nextAttachError = nil
                messageContinuation.yield(
                    .error(
                        id: id,
                        code: nextAttachError.code,
                        message: nextAttachError.message,
                        data: nextAttachError.data
                    )
                )
                return
            }
            if let mockAttachError {
                messageContinuation.yield(
                    .error(
                        id: id,
                        code: mockAttachError.code,
                        message: mockAttachError.message,
                        data: mockAttachError.data
                    )
                )
                return
            }
            if mockAttachShouldFail {
                mockAttachShouldFail = false
                messageContinuation.yield(
                    .error(id: id, code: -32000, message: "conversation not found: \(conversationId)", data: nil)
                )
                return
            }
            if let runtimeId = conversation["runtimeId"]?.stringValue, !runtimeId.isEmpty {
                lastAttachSessionId = runtimeId
                if let attachSeqInt = params?["lastEventSeq"]?.intValue {
                    lastAttachLastEventSeq = UInt64(attachSeqInt)
                } else {
                    lastAttachLastEventSeq = nil
                }
                let bufferedArr = decoratedBufferedEvents(mockAttachBufferedEvents, runtimeId: runtimeId, conversationId: conversationId)
                messageContinuation.yield(.response(id: id, result: .object([
                    "conversation": .object(conversation),
                    "attachment": .object([
                        "runtimeId": .string(runtimeId),
                        "state": .string(mockAttachState),
                        "bufferedEvents": .array(bufferedArr),
                        "reusedRuntime": .bool(true),
                        "restoredFromHistory": .bool(false)
                    ])
                ])))
                return
            }

            let runtimeId = "mock-sess-\(UUID().uuidString.prefix(8))"
            let command = preferredCommand ?? conversation["command"]?.stringValue
            if let nextLoadError {
                self.nextLoadError = nil
                messageContinuation.yield(
                    .error(
                        id: id,
                        code: nextLoadError.code,
                        message: nextLoadError.message,
                        data: nextLoadError.data
                    )
                )
                return
            }
            let failSessionIDs = mockLoadFailSessionIDs
            let failSessionCwdPairs = mockLoadFailSessionCwdPairs
            let requestedCwd = conversation["cwd"]?.stringValue ?? cwdHint
            let failKey = "\(conversationId)|\(requestedCwd)"
            if failSessionIDs.contains(conversationId) || failSessionCwdPairs.contains(failKey) {
                messageContinuation.yield(
                    .error(id: id, code: -32603, message: "Internal error", data: .object([
                        "details": .string("Session not found")
                    ]))
                )
                return
            }
            let bufferedArr = bufferedEventsFromLoadSteps(sessionId: conversationId, runtimeId: runtimeId, conversationId: conversationId)
            let restoredConversation = makeConversationValue(
                conversationId: conversationId,
                runtimeId: runtimeId,
                state: "attached",
                cwd: requestedCwd,
                command: command,
                title: conversation["title"]?.stringValue,
                lastEventSeq: UInt64(bufferedArr.count),
                origin: "managed"
            )
            upsertMockConversation(conversationId: conversationId, value: restoredConversation)
            upsertMockSession(
                sessionId: runtimeId,
                cwd: requestedCwd,
                state: mockAttachState,
                lastEventSeq: UInt64(bufferedArr.count),
                command: command,
                title: conversation["title"]?.stringValue
            )
            messageContinuation.yield(.response(id: id, result: .object([
                "conversation": restoredConversation,
                "attachment": .object([
                    "runtimeId": .string(runtimeId),
                    "state": .string(mockAttachState),
                    "bufferedEvents": .array(bufferedArr),
                    "reusedRuntime": .bool(false),
                    "restoredFromHistory": .bool(true)
                ])
            ])))

        case DaemonMethods.conversationDetach:
            if let conversationId = params?["conversationId"]?.stringValue {
                if let runtimeId = conversationValue(for: conversationId)?["runtimeId"]?.stringValue {
                    detachedSessionIds.append(runtimeId)
                } else {
                    detachedSessionIds.append(conversationId)
                }
            }
            messageContinuation.yield(.response(id: id, result: .object([:])))

        case DaemonMethods.conversationList:
            let conversations = conversationListValues().map { JSONValue.object($0) }
            messageContinuation.yield(.response(id: id, result: .object([
                "conversations": .array(conversations)
            ])))

        case DaemonMethods.sessionList:
            messageContinuation.yield(.response(id: id, result: .object([
                "sessions": .array(mockSessionList.map { .object($0) })
            ])))

        case DaemonMethods.sessionKill:
            if let sessionId = params?["sessionId"]?.stringValue {
                killedSessionIds.append(sessionId)
            }
            messageContinuation.yield(.response(id: id, result: .object([:])))

        case DaemonMethods.logs:
            messageContinuation.yield(.response(id: id, result: .object([
                "entries": .array(mockDaemonLogs.map { .object($0) })
            ])))

        // ACP passthrough (daemon forwards transparently)
        case ACPMethods.sessionPrompt:
            let sessionId = params?["sessionId"]?.stringValue ?? mockSessionId ?? "unknown"
            lastPromptSessionId = sessionId
            lastPromptBlocks = params?["prompt"]?.arrayValue
            if mockPromptShouldHang {
                return
            }
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
            let steps = scenario.steps
            await streamScenario(
                requestId: id,
                sessionId: sessionId,
                steps: steps,
                sendResponse: !mockDropPromptResponse
            )

        case ACPMethods.sessionLoad:
            let sessionId = params?["sessionId"]?.stringValue ?? mockSessionId ?? "unknown"
            let cwd = params?["cwd"]?.stringValue ?? ""
            lastLoadSessionId = sessionId
            lastLoadCwd = cwd
            if mockLoadShouldHang {
                return
            }
            if let nextLoadError {
                self.nextLoadError = nil
                messageContinuation.yield(
                    .error(
                        id: id,
                        code: nextLoadError.code,
                        message: nextLoadError.message,
                        data: nextLoadError.data
                    )
                )
                return
            }
            let failSessionIDs = mockLoadFailSessionIDs
            let failSessionCwdPairs = mockLoadFailSessionCwdPairs
            let steps = mockLoadSteps
            let failKey = "\(sessionId)|\(cwd)"
            if failSessionIDs.contains(sessionId) || failSessionCwdPairs.contains(failKey) {
                messageContinuation.yield(
                    .error(id: id, code: -32603, message: "Internal error", data: .object([
                        "details": .string("Session not found")
                    ]))
                )
                return
            }
            await streamLoadHistory(requestId: id, sessionId: sessionId, steps: steps)

        default:
            messageContinuation.yield(
                .error(id: id, code: -32601, message: "Method not found: \(method)", data: nil)
            )
        }
    }

    // MARK: - Scenario Streaming

    private func streamScenario(
        requestId: JSONRPCMessage.JSONRPCID,
        sessionId: String,
        steps: [MockStep],
        sendResponse: Bool = true
    ) async {
        for step in steps {
            guard !isClosed else { return }
            await executeStep(step, sessionId: sessionId)
        }

        guard sendResponse else { return }
        let result: JSONValue = .object([
            "stopReason": .string("end_turn")
        ])
        messageContinuation.yield(.response(id: requestId, result: result))
    }

    /// Stream history events during session/load, then return response.
    private func streamLoadHistory(
        requestId: JSONRPCMessage.JSONRPCID,
        sessionId: String,
        steps: [MockStep]
    ) async {
        for step in steps {
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
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "runtimeId": .string(sessionId),
            "update": update
        ]
        if let conversationId = conversationID(forRuntimeID: sessionId) {
            params["conversationId"] = .string(conversationId)
        }
        messageContinuation.yield(.notification(method: ACPMethods.sessionUpdate, params: .object(params)))
    }

    private func conversationID(forRuntimeID runtimeId: String) -> String? {
        conversationListValues().first {
            $0["runtimeId"]?.stringValue == runtimeId || $0["conversationId"]?.stringValue == runtimeId
        }?["conversationId"]?.stringValue
    }

    private func conversationListValues() -> [[String: JSONValue]] {
        if !mockConversationList.isEmpty {
            return mockConversationList
        }
        return mockSessionList.map { session in
            let sessionId = session["sessionId"]?.stringValue ?? "unknown"
            let sessionState = session["state"]?.stringValue ?? "idle"
            let conversationState = switch sessionState {
            case "starting", "prompting", "draining": "running"
            case "idle", "completed": "ready"
            case "external": "restorable"
            case "dead": "unavailable"
            default: "ready"
            }
            var conversation: [String: JSONValue] = [
                "conversationId": .string(sessionId),
                "state": .string(conversationState),
                "cwd": session["cwd"] ?? .string(""),
                "lastEventSeq": session["lastEventSeq"] ?? .int(0),
                "origin": .string(sessionState == "external" ? "discovered" : "managed")
            ]
            if sessionState != "external" {
                conversation["runtimeId"] = .string(sessionId)
            }
            if let command = session["command"] {
                conversation["command"] = command
            }
            if let title = session["title"] {
                conversation["title"] = title
            }
            if let updatedAt = session["updatedAt"] {
                conversation["updatedAt"] = updatedAt
            }
            return conversation
        }
    }

    private func conversationValue(for conversationId: String) -> [String: JSONValue]? {
        conversationListValues().first {
            $0["conversationId"]?.stringValue == conversationId
        }
    }

    private func makeConversationValue(
        conversationId: String,
        runtimeId: String?,
        state: String,
        cwd: String,
        command: String?,
        title: String?,
        lastEventSeq: UInt64,
        origin: String
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "conversationId": .string(conversationId),
            "state": .string(state),
            "cwd": .string(cwd),
            "lastEventSeq": .int(Int(lastEventSeq)),
            "origin": .string(origin)
        ]
        if let runtimeId, !runtimeId.isEmpty {
            value["runtimeId"] = .string(runtimeId)
        }
        if let command, !command.isEmpty {
            value["command"] = .string(command)
        }
        if let title, !title.isEmpty {
            value["title"] = .string(title)
        }
        return .object(value)
    }

    private func upsertMockConversation(conversationId: String, value: JSONValue) {
        guard case .object(let object) = value else { return }
        if let index = mockConversationList.firstIndex(where: { $0["conversationId"]?.stringValue == conversationId }) {
            mockConversationList[index] = object
        } else {
            mockConversationList.append(object)
        }
    }

    private func upsertMockSession(
        sessionId: String,
        cwd: String,
        state: String,
        lastEventSeq: UInt64,
        command: String?,
        title: String?
    ) {
        var value: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "cwd": .string(cwd),
            "state": .string(state),
            "lastEventSeq": .int(Int(lastEventSeq))
        ]
        if let command, !command.isEmpty {
            value["command"] = .string(command)
        }
        if let title, !title.isEmpty {
            value["title"] = .string(title)
        }
        if let index = mockSessionList.firstIndex(where: { $0["sessionId"]?.stringValue == sessionId }) {
            mockSessionList[index] = value
        } else {
            mockSessionList.append(value)
        }
    }

    private func decoratedBufferedEvents(
        _ events: [[String: JSONValue]],
        runtimeId: String,
        conversationId: String
    ) -> [JSONValue] {
        events.map { event in
            guard var wrappedEvent = event["event"]?.objectValue,
                  wrappedEvent["method"]?.stringValue == ACPMethods.sessionUpdate,
                  var params = wrappedEvent["params"]?.objectValue else {
                return .object(event)
            }
            params["runtimeId"] = .string(runtimeId)
            params["conversationId"] = .string(conversationId)
            wrappedEvent["params"] = .object(params)

            var updated = event
            updated["event"] = .object(wrappedEvent)
            return .object(updated)
        }
    }

    private func bufferedEventsFromLoadSteps(
        sessionId: String,
        runtimeId: String,
        conversationId: String
    ) -> [JSONValue] {
        var events: [JSONValue] = []
        var seq = 0
        for step in mockLoadSteps {
            let update: JSONValue?
            switch step {
            case .delay:
                update = nil
            case .textDelta(let text):
                update = .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            case .userMessageChunk(let text):
                update = .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            case .thoughtDelta(let text):
                update = .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text)
                    ])
                ])
            case .toolCallStart(let id, let name):
                update = .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string(id),
                    "title": .string(name),
                    "kind": .string("tool_use"),
                    "status": .string("running"),
                    "rawInput": .null
                ])
            case .toolCallUpdate(let id, let output):
                var updateObj: [String: JSONValue] = [
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string(id),
                    "status": .string("running")
                ]
                if let output {
                    updateObj["rawOutput"] = .string(output)
                }
                update = .object(updateObj)
            case .toolCallComplete(let id, let output, let failed):
                update = .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string(id),
                    "status": .string(failed ? "failed" : "completed"),
                    "rawOutput": .string(output)
                ])
            case .promptComplete(let reason):
                update = .object([
                    "sessionUpdate": .string("prompt_complete"),
                    "stopReason": .string(reason.rawValue)
                ])
            }
            guard let update else { continue }
            seq += 1
            events.append(.object([
                "seq": .int(seq),
                "event": .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string(ACPMethods.sessionUpdate),
                    "params": .object([
                        "sessionId": .string(sessionId),
                        "runtimeId": .string(runtimeId),
                        "conversationId": .string(conversationId),
                        "update": update,
                        "__seq": .int(seq)
                    ])
                ])
            ]))
        }
        return events
    }

    // MARK: - Scenario Control

    /// Change the scenario for subsequent prompts.
    func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    /// Testing hook: inject a session/update text delta notification.
    func emitSessionTextDeltaForTest(sessionId: String, runtimeId: String? = nil, conversationId: String? = nil, text: String, seq: Int? = nil) {
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
        if let runtimeId {
            params["runtimeId"] = .string(runtimeId)
        }
        if let conversationId {
            params["conversationId"] = .string(conversationId)
        }
        if let seq {
            params["__seq"] = .int(seq)
        }
        messageContinuation.yield(
            .notification(method: ACPMethods.sessionUpdate, params: .object(params))
        )
    }

    // MARK: - Test Helpers

    func setMockAttachState(_ state: String) {
        self.mockAttachState = state
    }

    func setMockAttachBufferedEvents(_ events: [[String: JSONValue]]) {
        self.mockAttachBufferedEvents = events
    }

    func setMockAttachShouldFail(_ fail: Bool) {
        self.mockAttachShouldFail = fail
    }

    func setMockAttachError(code: Int, message: String, data: JSONValue?) {
        mockAttachError = (code: code, message: message, data: data)
    }

    func clearMockAttachError() {
        mockAttachError = nil
    }

    func setNextAttachError(code: Int, message: String, data: JSONValue?) {
        nextAttachError = (code: code, message: message, data: data)
    }

    func setMockSessionList(_ list: [[String: JSONValue]]) {
        self.mockSessionList = list
    }

    func setMockConversationList(_ list: [[String: JSONValue]]) {
        self.mockConversationList = list
    }

    func setMockLoadSteps(_ steps: [MockStep]) {
        self.mockLoadSteps = steps
    }

    func setMockLoadFailSessionIDs(_ ids: Set<String>) {
        self.mockLoadFailSessionIDs = ids
    }

    func setMockLoadFailSessionCwdPairs(_ pairs: Set<String>) {
        self.mockLoadFailSessionCwdPairs = pairs
    }

    func setNextLoadError(code: Int, message: String, data: JSONValue?) {
        nextLoadError = (code: code, message: message, data: data)
    }

    func setMockLoadShouldHang(_ shouldHang: Bool) {
        mockLoadShouldHang = shouldHang
    }

    func setMockAgentAvailabilityByID(_ availability: [String: Bool]) {
        self.mockAgentAvailabilityByID = availability
    }

    func setMockAgentProbeUnsupported(_ unsupported: Bool) {
        self.mockAgentProbeUnsupported = unsupported
    }

    func getLastLoadSessionId() -> String? {
        lastLoadSessionId
    }

    func getLastLoadCwd() -> String? {
        lastLoadCwd
    }

    func getLastCreateCommand() -> String? {
        lastCreateCommand
    }

    func getLastCreateCwd() -> String? {
        lastCreateCwd
    }

    func getCreateCommands() -> [String] {
        createCommands
    }

    func getLastAttachSessionId() -> String? {
        lastAttachSessionId
    }

    func getLastAttachLastEventSeq() -> UInt64? {
        lastAttachLastEventSeq
    }

    func getLastPromptBlocks() -> [JSONValue]? {
        lastPromptBlocks
    }

    func getLastPromptSessionId() -> String? {
        lastPromptSessionId
    }

    func getReceivedMethods() -> [String] {
        receivedMethods
    }

    func getDetachedSessionIds() -> [String] {
        detachedSessionIds
    }

    func getKilledSessionIds() -> [String] {
        killedSessionIds
    }

    func setNextPromptError(code: Int, message: String, data: JSONValue?) {
        nextPromptError = (code: code, message: message, data: data)
    }

    func setMockPromptShouldHang(_ shouldHang: Bool) {
        mockPromptShouldHang = shouldHang
    }

    func setMockDropPromptResponse(_ drop: Bool) {
        mockDropPromptResponse = drop
    }
}
