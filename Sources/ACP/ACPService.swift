import Foundation

/// Typed ACP method wrappers.
struct ACPService {
    let client: ACPClient

    /// Initialize the ACP connection.
    func initialize(traceId: String? = nil) async throws -> JSONValue {
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
            params: params,
            traceId: traceId
        )
    }

    /// Authenticate with the agent using the specified auth method.
    func authenticate(methodId: String, traceId: String? = nil) async throws -> JSONValue {
        let params: JSONValue = .object([
            "methodId": .string(methodId)
        ])
        return try await client.sendRequest(
            method: "authenticate",
            params: params,
            traceId: traceId
        )
    }

    /// Create a new session.
    func createSession(cwd: String, traceId: String? = nil) async throws -> String {
        let params: JSONValue = .object([
            "cwd": .string(cwd),
            "mcpServers": .array([])
        ])
        let result = try await client.sendRequest(
            method: ACPMethods.sessionNew,
            params: params,
            traceId: traceId
        )
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw ACPError.unexpectedResponse
        }
        return sessionId
    }

    /// Send a prompt to a session.
    func sendPrompt(
        sessionId: String,
        text: String,
        traceId: String? = nil
    ) async throws -> StopReason {
        try await sendPrompt(
            sessionId: sessionId,
            prompt: [.text(text)],
            traceId: traceId
        )
    }

    /// Send a structured prompt to a session.
    /// - Parameters:
    ///   - sessionId: Logical ACP session to prompt.
    ///   - prompt: Prompt blocks.
    func sendPrompt(
        sessionId: String,
        prompt: [PromptBlock],
        traceId: String? = nil
    ) async throws -> StopReason {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "prompt": .array(prompt.map { $0.jsonValue })
        ])
        let result = try await client.sendRequest(
            method: ACPMethods.sessionPrompt,
            params: params,
            traceId: traceId
        )
        let reasonStr = result["stopReason"]?.stringValue ?? "end_turn"
        return StopReason(rawValue: reasonStr) ?? .unknown
    }

    /// List existing sessions on the server.
    func listSessions(traceId: String? = nil) async throws -> [(sessionId: String, cwd: String?, title: String?)] {
        let result = try await client.sendRequest(
            method: ACPMethods.sessionList,
            params: .object([:]),
            traceId: traceId
        )
        guard let sessions = result["sessions"]?.arrayValue else {
            return []
        }
        return sessions.compactMap { s in
            guard let id = s["sessionId"]?.stringValue else { return nil }
            return (sessionId: id, cwd: s["cwd"]?.stringValue, title: s["title"]?.stringValue)
        }
    }

}
