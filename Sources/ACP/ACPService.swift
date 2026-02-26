import Foundation

/// Typed ACP method wrappers.
struct ACPService {
    let client: ACPClient

    /// Initialize the ACP connection.
    func initialize() async throws -> JSONValue {
        let params: JSONValue = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("opencan"),
                "title": .string("OpenCAN"),
                "version": .string("0.1.0")
            ])
        ])
        return try await client.sendRequest(
            method: ACPMethods.initialize,
            params: params
        )
    }

    /// Authenticate with the agent using the specified auth method.
    func authenticate(methodId: String) async throws -> JSONValue {
        let params: JSONValue = .object([
            "methodId": .string(methodId)
        ])
        return try await client.sendRequest(
            method: "authenticate",
            params: params
        )
    }

    /// Create a new session.
    func createSession(cwd: String) async throws -> String {
        let params: JSONValue = .object([
            "cwd": .string(cwd),
            "mcpServers": .array([])
        ])
        let result = try await client.sendRequest(
            method: ACPMethods.sessionNew,
            params: params
        )
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw ACPError.unexpectedResponse
        }
        return sessionId
    }

    /// Send a prompt to a session.
    func sendPrompt(sessionId: String, text: String) async throws -> StopReason {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "prompt": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ])
        let result = try await client.sendRequest(
            method: ACPMethods.sessionPrompt,
            params: params
        )
        let reasonStr = result["stopReason"]?.stringValue ?? "end_turn"
        return StopReason(rawValue: reasonStr) ?? .unknown
    }

    /// List existing sessions on the server.
    func listSessions() async throws -> [(sessionId: String, cwd: String?, title: String?)] {
        let result = try await client.sendRequest(
            method: ACPMethods.sessionList,
            params: .object([:])
        )
        guard let sessions = result["sessions"]?.arrayValue else {
            return []
        }
        return sessions.compactMap { s in
            guard let id = s["sessionId"]?.stringValue else { return nil }
            return (sessionId: id, cwd: s["cwd"]?.stringValue, title: s["title"]?.stringValue)
        }
    }

    /// Load an existing session by ID.
    /// - Parameters:
    ///   - sessionId: The session to load from disk (ACP reads this session's history).
    ///   - routeToSessionId: If provided, the daemon routes the request to this session's
    ///     ACP process instead of the one matching `sessionId`. Used when loading old
    ///     session history into a newly created ACP process.
    ///   - cwd: Working directory for the session.
    func loadSession(sessionId: String, cwd: String, routeToSessionId: String? = nil) async throws {
        var paramsDict: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "cwd": .string(cwd),
            "mcpServers": .array([])
        ]
        if let routeToSessionId {
            paramsDict["__routeToSession"] = .string(routeToSessionId)
        }
        let result = try await client.sendRequest(
            method: ACPMethods.sessionLoad,
            params: .object(paramsDict)
        )
        Log.toFile("[ACPService] session/load result: \(result)")
    }
}
