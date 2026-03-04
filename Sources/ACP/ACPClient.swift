import Foundation
import os

/// JSON-RPC client with request/response correlation and notification dispatch.
actor ACPClient {
    private let transport: any ACPTransport
    private var nextId = 1000  // Start high to avoid collision with server-initiated request IDs
    private var pendingRequests: [JSONRPCMessage.JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
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
        // Store continuation BEFORE sending so the response can't arrive first
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pendingRequests[id] = cont
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.transport.send(message)
                    } catch {
                        if let c = await self.removePending(id) {
                            c.resume(throwing: error)
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
                await self.removeSentRequestId(id)
            }
        }
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
        pendingRequests.removeValue(forKey: id)
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
            if let c = pendingRequests.removeValue(forKey: id) {
                c.resume(returning: result)
            }
        case .error(let id, let code, let msg, let data):
            if let id {
                sentRequestIds.remove(id)
                if let c = pendingRequests.removeValue(forKey: id) {
                    c.resume(throwing: ACPError.rpcError(code: code, message: msg, data: data))
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
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("session not found")
    }

    /// True when upstream reports the requested history/session resource is missing.
    var isResourceNotFound: Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("resource not found")
    }

    /// True when the request was routed to a proxy we're not attached to.
    var isNotAttached: Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("not attached to session")
    }

    /// True when daemon/session.attach failed because another client owns it.
    var isSessionAlreadyAttachedByAnotherClient: Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("session already attached by another client")
    }

    /// True when upstream closed the in-flight query before producing a response.
    /// This is typically terminal for the current routed backend and should not
    /// trigger repeated cwd retries.
    var isQueryClosedBeforeResponse: Bool {
        guard case .rpcError(_, let message, let data) = self else { return false }
        let details = data?["details"]?.stringValue ?? ""
        let combined = "\(message) \(details)".lowercased()
        return combined.contains("query closed before response received")
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
}
