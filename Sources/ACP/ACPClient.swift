import Foundation
import os

/// JSON-RPC client with request/response correlation and notification dispatch.
actor ACPClient {
    private let transport: any ACPTransport
    private var nextId = 1000  // Start high to avoid collision with server-initiated request IDs
    private var pendingRequests: [JSONRPCMessage.JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private let notificationContinuation: AsyncStream<JSONRPCMessage>.Continuation
    let notifications: AsyncStream<JSONRPCMessage>
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
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        notificationContinuation.finish()
        cancelAll()
    }

    /// Send a request and await the response.
    func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = JSONRPCMessage.JSONRPCID.int(nextId)
        nextId += 1
        sentRequestIds.insert(id)
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        // Store continuation BEFORE sending so the response can't arrive first
        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            Task { [weak self] in
                do {
                    try await self?.transport.send(message)
                } catch {
                    if let self, let c = await self.removePending(id) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func removePending(_ id: JSONRPCMessage.JSONRPCID) -> CheckedContinuation<JSONValue, Error>? {
        pendingRequests.removeValue(forKey: id)
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
        case .error(let id, let code, let msg, _):
            if let id {
                sentRequestIds.remove(id)
                if let c = pendingRequests.removeValue(forKey: id) {
                    c.resume(throwing: ACPError.rpcError(code: code, message: msg))
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
            try? await transport.send(reply)
            Log.toFile("[ACPClient] Auto-approved permission: \(selectedOptionId)")
        default:
            let errMsg = JSONRPCMessage.error(
                id: id, code: -32601,
                message: "Method not found: \(method)", data: nil
            )
            try? await transport.send(errMsg)
        }
    }

    private func cancelAll() {
        for (_, c) in pendingRequests {
            c.resume(throwing: CancellationError())
        }
        pendingRequests.removeAll()
    }
}

enum ACPError: Error, LocalizedError {
    case rpcError(code: Int, message: String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .rpcError(_, let message): "ACP error: \(message)"
        case .unexpectedResponse: "Unexpected ACP response"
        }
    }
}