import Foundation
import os

/// Client for daemon/ prefixed JSON-RPC methods.
/// Wraps ACPClient for typed daemon method calls.
actor DaemonClient {
    private let client: ACPClient

    init(client: ACPClient) {
        self.client = client
    }

    /// Initialize daemon connection and get daemon info.
    func hello() async throws -> DaemonInfo {
        let params: JSONValue = .object([
            "clientVersion": .string("0.1.0")
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.hello,
            params: params
        )
        let sessions = parseDaemonSessions(result["sessions"])
        return DaemonInfo(
            daemonVersion: result["daemonVersion"]?.stringValue ?? "unknown",
            sessions: sessions
        )
    }

    /// Create a new session via the daemon.
    /// The daemon internally spawns the ACP process, runs initialize + session/new.
    func createSession(cwd: String, command: String) async throws -> String {
        let params: JSONValue = .object([
            "cwd": .string(cwd),
            "command": .string(command)
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.sessionCreate,
            params: params
        )
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw ACPError.unexpectedResponse
        }
        return sessionId
    }

    /// Probe whether agent launcher commands are available on this node.
    func probeAgents(_ agents: [(id: String, command: String)]) async throws -> [DaemonAgentAvailability] {
        let payloadAgents = agents.map { agent in
            JSONValue.object([
                "id": .string(agent.id),
                "command": .string(agent.command)
            ])
        }
        let params: JSONValue = .object([
            "agents": .array(payloadAgents)
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.agentProbe,
            params: params
        )
        return parseAgentAvailability(result["agents"])
    }

    /// Attach to an existing session, receiving buffered events since lastEventSeq.
    func attachSession(sessionId: String, lastEventSeq: UInt64) async throws -> DaemonAttachResult {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "lastEventSeq": .int(Int(lastEventSeq))
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.sessionAttach,
            params: params
        )
        let state = result["state"]?.stringValue ?? "unknown"
        let bufferedEvents = parseBufferedEvents(result["bufferedEvents"])
        return DaemonAttachResult(state: state, bufferedEvents: bufferedEvents)
    }

    /// Detach from a session without killing it.
    func detachSession(sessionId: String) async throws {
        let _ = try await client.sendRequest(
            method: DaemonMethods.sessionDetach,
            params: .object(["sessionId": .string(sessionId)])
        )
    }

    /// List all sessions managed by the daemon.
    /// When `cwd` is provided, daemon external-session discovery is scoped to that path.
    func listSessions(cwd: String? = nil) async throws -> [DaemonSessionInfo] {
        var params: [String: JSONValue] = [:]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }
        let result = try await client.sendRequest(
            method: DaemonMethods.sessionList,
            params: .object(params)
        )
        return parseDaemonSessions(result["sessions"])
    }

    /// Kill a session and its ACP process.
    func killSession(sessionId: String) async throws {
        let _ = try await client.sendRequest(
            method: DaemonMethods.sessionKill,
            params: .object(["sessionId": .string(sessionId)])
        )
    }

    // MARK: - Parsing helpers

    private func parseDaemonSessions(_ value: JSONValue?) -> [DaemonSessionInfo] {
        guard let arr = value?.arrayValue else { return [] }
        return arr.compactMap { item in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            let updatedAt = parseDaemonDate(item["updatedAt"]?.stringValue)
            return DaemonSessionInfo(
                sessionId: id,
                cwd: item["cwd"]?.stringValue ?? "",
                state: item["state"]?.stringValue ?? "unknown",
                lastEventSeq: UInt64(item["lastEventSeq"]?.intValue ?? 0),
                command: item["command"]?.stringValue,
                title: item["title"]?.stringValue,
                updatedAt: updatedAt
            )
        }
    }

    private func parseDaemonDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = Self.iso8601WithFractional.date(from: raw) {
            return date
        }
        return Self.iso8601.date(from: raw)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func parseAgentAvailability(_ value: JSONValue?) -> [DaemonAgentAvailability] {
        guard let arr = value?.arrayValue else { return [] }
        return arr.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            let command = item["command"]?.stringValue ?? ""
            let available = item["available"]?.boolValue ?? false
            return DaemonAgentAvailability(
                id: id,
                command: command,
                available: available
            )
        }
    }

    private func parseBufferedEvents(_ value: JSONValue?) -> [DaemonBufferedEvent] {
        guard let arr = value?.arrayValue else { return [] }
        return arr.compactMap { item in
            guard let seq = item["seq"]?.intValue else { return nil }
            // Reconstruct the notification from the buffered raw event
            // The daemon stores the full JSON-RPC notification as the event
            let event = item["event"]
            guard let eventObj = event?.objectValue else { return nil }

            // Parse the buffered event back into a JSONRPCMessage
            let method = eventObj["method"]?.stringValue ?? ""
            var params: JSONValue? = nil
            if let p = eventObj["params"] {
                params = p
            }
            let notification = JSONRPCMessage.notification(method: method, params: params)
            return DaemonBufferedEvent(seq: UInt64(seq), event: notification)
        }
    }
}
