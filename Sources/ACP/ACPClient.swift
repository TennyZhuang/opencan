import Foundation

/// JSON-RPC client with request/response correlation and notification dispatch.
actor ACPClient {
    private let transport: any ACPTransport
    private var nextId = 1
    private var pendingRequests: [JSONRPCMessage.JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private let notificationContinuation: AsyncStream<JSONRPCMessage>.Continuation
    let notifications: AsyncStream<JSONRPCMessage>
    private var readTask: Task<Void, Never>?

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
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        try await transport.send(message)
        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
        }
    }

    /// Send a notification (no response expected).
    func sendNotification(method: String, params: JSONValue?) async throws {
        let message = JSONRPCMessage.notification(method: method, params: params)
        try await transport.send(message)
    }

    private func handleMessage(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            if let c = pendingRequests.removeValue(forKey: id) {
                c.resume(returning: result)
            }
        case .error(let id, let code, let msg, _):
            if let id, let c = pendingRequests.removeValue(forKey: id) {
                c.resume(throwing: ACPError.rpcError(code: code, message: msg))
            }
        case .notification(_, _):
            notificationContinuation.yield(message)
        case .request(_, let method, _):
            print("[ACPClient] Server request: \(method)")
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