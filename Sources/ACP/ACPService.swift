import Foundation

/// Typed ACP method wrappers.
struct ACPService {
    let client: ACPClient

    /// Initialize the ACP connection.
    func initialize() async throws -> JSONValue {
        let params: JSONValue = .object([
            "protocolVersion": .string("2025-11-16"),
            "capabilities": .object([
                "prompts": .object([
                    "textContent": .bool(true)
                ])
            ]),
            "clientInfo": .object([
                "name": .string("OpenCAN"),
                "version": .string("0.1.0")
            ])
        ])
        let result = try await client.sendRequest(
            method: ACPMethods.initialize,
            params: params
        )
        // Send initialized notification
        try await client.sendNotification(
            method: ACPMethods.initialized,
            params: .object([:])
        )
        return result
    }

    /// Create a new session.
    func createSession(cwd: String) async throws -> String {
        let params: JSONValue = .object([
            "cwd": .string(cwd)
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

    /// Send a prompt to a session. Returns when the prompt completes.
    /// Session updates arrive as notifications on client.notifications.
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

    /// List active sessions.
    func listSessions() async throws -> [SessionInfo] {
        let result = try await client.sendRequest(
            method: ACPMethods.sessionList,
            params: .object([:])
        )
        guard let sessions = result["sessions"]?.arrayValue else {
            return []
        }
        return sessions.compactMap { val in
            guard let id = val["sessionId"]?.stringValue else { return nil }
            return SessionInfo(sessionId: id)
        }
    }
}