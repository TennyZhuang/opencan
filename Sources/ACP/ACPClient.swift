import Foundation
import os

/// JSON-RPC client with request/response correlation and notification dispatch.
actor ACPClient {
    private let transport: any ACPTransport
    private var nextId = 1000  // Start high to avoid collision with server-initiated request IDs
    private var pendingRequests: [JSONRPCMessage.JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingRequestMethods: [JSONRPCMessage.JSONRPCID: String] = [:]
    private let notificationContinuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let notifications: AsyncStream<JSONRPCMessage>
    private var readTask: Task<Void, Never>?
    /// Track IDs of requests we sent, so we can ignore PTY echoes.
    private var sentRequestIds: Set<JSONRPCMessage.JSONRPCID> = []

    init(transport: any ACPTransport) {
        self.transport = transport
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.notifications = stream
        self.notificationContinuation = cont
    }

    func start() {
        readTask = Task { [weak self] in
            guard let self else { return }
            for await message in transport.messages {
                await self.handleMessage(message)
            }
            await self.cancelAll()
            await self.finishNotifications()
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        notificationContinuation.finish()
        cancelAll()
    }

    /// Send a request and await the response.
    func sendRequest(method: String, params: JSONValue?, traceId: String? = nil) async throws -> JSONValue {
        let id = JSONRPCMessage.JSONRPCID.int(nextId)
        nextId += 1
        sentRequestIds.insert(id)
        let finalParams = injectTraceId(traceId, into: params)
        let message = JSONRPCMessage.request(id: id, method: method, params: finalParams)
        let shouldLogLifecycle = shouldLogRequestLifecycle(method)
        if shouldLogLifecycle {
            Log.log(
                component: "ACPClient",
                "queueing request",
                traceId: traceId,
                extra: ["method": method, "requestId": "\(id)"]
            )
        }
        // Store continuation BEFORE sending so the response can't arrive first
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pendingRequests[id] = cont
                pendingRequestMethods[id] = method
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        if shouldLogLifecycle {
                            Log.log(
                                component: "ACPClient",
                                "sending request to transport",
                                traceId: traceId,
                                extra: ["method": method, "requestId": "\(id)"]
                            )
                        }
                        try await self.transport.send(message)
                        if shouldLogLifecycle {
                            Log.log(
                                component: "ACPClient",
                                "request sent to transport",
                                traceId: traceId,
                                extra: ["method": method, "requestId": "\(id)"]
                            )
                        }
                    } catch {
                        if let c = await self.removePending(id) {
                            c.resume(throwing: error)
                        }
                        if shouldLogLifecycle {
                            Log.log(
                                level: "warning",
                                component: "ACPClient",
                                "request send failed",
                                traceId: traceId,
                                extra: [
                                    "method": method,
                                    "requestId": "\(id)",
                                    "error": "\(error)"
                                ]
                            )
                        }
                        await self.removeSentRequestId(id)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                guard let self else { return }
                if let c = await self.removePending(id) {
                    c.resume(throwing: CancellationError())
                }
                if shouldLogLifecycle {
                    Log.log(
                        level: "warning",
                        component: "ACPClient",
                        "request cancelled",
                        traceId: traceId,
                        extra: ["method": method, "requestId": "\(id)"]
                    )
                }
                await self.removeSentRequestId(id)
            }
        }
    }

    private func shouldLogRequestLifecycle(_ method: String) -> Bool {
        method == ACPMethods.sessionLoad || method == ACPMethods.sessionPrompt
    }

    private func injectTraceId(_ traceId: String?, into params: JSONValue?) -> JSONValue? {
        guard let traceId else { return params }

        if case .object(var dict) = params {
            var meta: [String: JSONValue] = [:]
            if case .object(let existingMeta)? = dict["_meta"] {
                meta = existingMeta
            }
            meta["traceId"] = .string(traceId)
            dict["_meta"] = .object(meta)
            return .object(dict)
        }

        if params == nil {
            return .object([
                "_meta": .object([
                    "traceId": .string(traceId)
                ])
            ])
        }

        // Keep non-object params untouched to avoid changing wire format.
        Log.log(
            level: "warning",
            component: "ACPClient",
            "Skipping traceId injection for non-object params",
            traceId: traceId
        )
        return params
    }

    private func removePending(_ id: JSONRPCMessage.JSONRPCID) -> CheckedContinuation<JSONValue, Error>? {
        pendingRequestMethods.removeValue(forKey: id)
        return pendingRequests.removeValue(forKey: id)
    }

    private func removeSentRequestId(_ id: JSONRPCMessage.JSONRPCID) {
        sentRequestIds.remove(id)
    }

    /// Send a notification (no response expected).
    func sendNotification(method: String, params: JSONValue?) async throws {
        let message = JSONRPCMessage.notification(method: method, params: params)
        try await transport.send(message)
    }

    private func handleMessage(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            sentRequestIds.remove(id)
            let method = pendingRequestMethods.removeValue(forKey: id)
            if let c = pendingRequests.removeValue(forKey: id) {
                c.resume(returning: result)
            }
            if let method, shouldLogRequestLifecycle(method) {
                Log.log(
                    component: "ACPClient",
                    "received terminal response",
                    extra: ["method": method, "requestId": "\(id)"]
                )
            }
        case .error(let id, let code, let msg, let data):
            if let id {
                sentRequestIds.remove(id)
                let method = pendingRequestMethods.removeValue(forKey: id)
                if let c = pendingRequests.removeValue(forKey: id) {
                    c.resume(throwing: ACPError.rpcError(code: code, message: msg, data: data))
                }
                if let method, shouldLogRequestLifecycle(method) {
                    Log.log(
                        level: "warning",
                        component: "ACPClient",
                        "received terminal error",
                        extra: [
                            "method": method,
                            "requestId": "\(id)",
                            "rpcCode": "\(code)",
                            "rpcMessage": msg
                        ]
                    )
                }
            }
        case .notification(_, _):
            notificationContinuation.yield(message)
        case .request(let id, let method, let params):
            // PTY echoes our own requests back — ignore them
            if sentRequestIds.contains(id) {
                Log.acp.debug("Ignoring PTY echo of our request: \(method) id=\(String(describing: id))")
                Log.toFile("[ACPClient] Ignoring PTY echo: \(method)")
                return
            }
            Log.acp.info("Server request: \(method) id=\(String(describing: id))")
            Log.toFile("[ACPClient] Server request: \(method)")
            Task { await self.handleServerRequest(id: id, method: method, params: params) }
        }
    }

    private func handleServerRequest(id: JSONRPCMessage.JSONRPCID, method: String, params: JSONValue?) async {
        switch method {
        case "session/request_permission":
            // Find the first "allow" option (allow_once or allow_always)
            var selectedOptionId = "allow"
            if let options = params?["options"]?.arrayValue {
                for opt in options {
                    if let kind = opt["kind"]?.stringValue,
                       (kind == "allow_once" || kind == "allow_always"),
                       let optId = opt["optionId"]?.stringValue {
                        selectedOptionId = optId
                        break
                    }
                }
            }
            let result: JSONValue = .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(selectedOptionId)
                ])
            ])
            let reply = JSONRPCMessage.response(id: id, result: result)
            do {
                try await transport.send(reply)
            } catch {
                Log.acp.error("Failed to send permission reply: \(error)")
                Log.toFile("[ACPClient] Failed to send permission reply: \(error)")
            }
            Log.toFile("[ACPClient] Auto-approved permission: \(selectedOptionId)")
        default:
            let errMsg = JSONRPCMessage.error(
                id: id, code: -32601,
                message: "Method not found: \(method)", data: nil
            )
            do {
                try await transport.send(errMsg)
            } catch {
                Log.acp.error("Failed to send error reply: \(error)")
                Log.toFile("[ACPClient] Failed to send error reply: \(error)")
            }
        }
    }

    private func cancelAll() {
        for (_, c) in pendingRequests {
            c.resume(throwing: CancellationError())
        }
        pendingRequests.removeAll()
        pendingRequestMethods.removeAll()
    }

    private func finishNotifications() {
        notificationContinuation.finish()
    }
}

enum ACPError: Error, LocalizedError {
    case rpcError(code: Int, message: String, data: JSONValue?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .rpcError(_, let message, let data):
            if let details = data?["details"]?.stringValue, !details.isEmpty {
                return "ACP error: \(message) (\(details))"
            }
            return "ACP error: \(message)"
        case .unexpectedResponse:
            return "Unexpected ACP response"
        }
    }

    /// Server-provided detail field carried in JSON-RPC error.data.details.
    var details: String? {
        guard case .rpcError(_, _, let data) = self else { return nil }
        return data?["details"]?.stringValue
    }

    /// JSON-RPC error code when this is an rpcError.
    var rpcCode: Int? {
        guard case .rpcError(let code, _, _) = self else { return nil }
        return code
    }

    /// True for terminal lookup misses where retrying different cwd is pointless.
    var isSessionNotFound: Bool {
        matchesMessageOrDetails(phrase: "session not found")
    }

    /// True when daemon-side conversation lookup failed.
    var isConversationNotFound: Bool {
        matchesMessageOrDetails(phrase: "conversation not found")
    }

    /// True when upstream reports the requested history/session resource is missing.
    var isResourceNotFound: Bool {
        matchesMessageOrDetails(phrase: "resource not found")
    }

    /// `session/load` specific resource-missing signal.
    /// Keep this narrower than generic `isResourceNotFound` to avoid unrelated
    /// resource errors triggering takeover retries.
    var isSessionLoadResourceNotFound: Bool {
        guard case .rpcError(let code, _, _) = self else { return false }
        guard code == -32002 || code == -32603 else { return false }
        return isResourceNotFound
    }

    /// True when the request was routed to a proxy we're not attached to.
    var isNotAttached: Bool {
        matchesMessageOrDetails(phrase: "not attached to session")
    }

    /// True when daemon attach/open failed because another client owns it.
    var isSessionAlreadyAttachedByAnotherClient: Bool {
        matchesMessageOrDetails(phrase: "attached by another client")
    }

    /// True when upstream closed the in-flight query before producing a response.
    /// This is typically terminal for the current routed backend and should not
    /// trigger repeated cwd retries.
    var isQueryClosedBeforeResponse: Bool {
        matchesMessageOrDetails(phrase: "query closed before response received")
    }

    /// True when upstream model routing has no available backend provider.
    var isModelUnavailable: Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("model_not_found")
            || combined.contains("no available distributor")
            || combined.contains("无可用渠道")
    }

    /// Best-effort extraction of backend request id from nested provider errors.
    var backendRequestID: String? {
        guard case .rpcError(_, let message, let data) = self else { return nil }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)"
        return ACPError.extractRequestID(from: combined)
    }

    private static func extractRequestID(from text: String) -> String? {
        let patterns = [
            #"request id:\s*([A-Za-z0-9_-]+)"#,
            #"request_id[:=]\s*([A-Za-z0-9_-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[range])
        }
        return nil
    }

    private func matchesMessageOrDetails(phrase: String) -> Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        return ACPError.containsStandalonePhrase(phrase, in: message)
            || ACPError.containsStandalonePhrase(phrase, in: details)
    }

    private static func containsStandalonePhrase(_ phrase: String, in text: String) -> Bool {
        let normalizedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPhrase.isEmpty, !normalizedText.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: normalizedPhrase)
        let pattern = "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        return regex.firstMatch(in: normalizedText, options: [], range: range) != nil
    }
}
