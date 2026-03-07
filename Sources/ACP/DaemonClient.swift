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
    func hello(traceId: String? = nil) async throws -> DaemonInfo {
        let params: JSONValue = .object([
            "clientVersion": .string("0.1.0")
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.hello,
            params: params,
            traceId: traceId
        )
        let sessions = parseDaemonSessions(result["sessions"])
        return DaemonInfo(
            daemonVersion: result["daemonVersion"]?.stringValue ?? "unknown",
            sessions: sessions
        )
    }

    /// Create and attach a new daemon-owned conversation.
    func createConversation(
        cwd: String,
        command: String,
        ownerId: String,
        traceId: String? = nil
    ) async throws -> DaemonConversationOpenResult {
        let params: JSONValue = .object([
            "cwd": .string(cwd),
            "command": .string(command),
            "ownerId": .string(ownerId)
        ])
        let result = try await client.sendRequest(
            method: DaemonMethods.conversationCreate,
            params: params,
            traceId: traceId
        )
        return try parseConversationOpenResult(result)
    }

    /// Open an existing conversation, reusing a runtime or restoring from history.
    func openConversation(
        conversationId: String,
        ownerId: String,
        lastRuntimeId: String? = nil,
        lastEventSeq: UInt64 = 0,
        preferredCommand: String? = nil,
        cwdHint: String? = nil,
        traceId: String? = nil
    ) async throws -> DaemonConversationOpenResult {
        var payload: [String: JSONValue] = [
            "conversationId": .string(conversationId),
            "ownerId": .string(ownerId),
            "lastEventSeq": .int(Int(lastEventSeq))
        ]
        if let lastRuntimeId, !lastRuntimeId.isEmpty {
            payload["lastRuntimeId"] = .string(lastRuntimeId)
        }
        if let preferredCommand, !preferredCommand.isEmpty {
            payload["preferredCommand"] = .string(preferredCommand)
        }
        if let cwdHint, !cwdHint.isEmpty {
            payload["cwdHint"] = .string(cwdHint)
        }
        let result = try await client.sendRequest(
            method: DaemonMethods.conversationOpen,
            params: .object(payload),
            traceId: traceId
        )
        return try parseConversationOpenResult(result)
    }

    /// Detach from a daemon-owned conversation without killing its runtime.
    func detachConversation(conversationId: String, traceId: String? = nil) async throws {
        let _ = try await client.sendRequest(
            method: DaemonMethods.conversationDetach,
            params: .object(["conversationId": .string(conversationId)]),
            traceId: traceId
        )
    }

    /// List daemon-owned conversations and restorable discovered conversations.
    func listConversations(cwd: String? = nil, traceId: String? = nil) async throws -> [DaemonConversationInfo] {
        var params: [String: JSONValue] = [:]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }
        let result = try await client.sendRequest(
            method: DaemonMethods.conversationList,
            params: .object(params),
            traceId: traceId
        )
        return parseDaemonConversations(result["conversations"])
    }

    /// Probe whether agent launcher commands are available on this node.
    func probeAgents(_ agents: [(id: String, command: String)], traceId: String? = nil) async throws -> [DaemonAgentAvailability] {
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
            params: params,
            traceId: traceId
        )
        return parseAgentAvailability(result["agents"])
    }

    /// List all sessions managed by the daemon.
    /// When `cwd` is provided, daemon external-session discovery is scoped to that path.
    func listSessions(cwd: String? = nil, traceId: String? = nil) async throws -> [DaemonSessionInfo] {
        var params: [String: JSONValue] = [:]
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }
        let result = try await client.sendRequest(
            method: DaemonMethods.sessionList,
            params: .object(params),
            traceId: traceId
        )
        return parseDaemonSessions(result["sessions"])
    }

    /// Kill a session and its ACP process.
    func killSession(sessionId: String, traceId: String? = nil) async throws {
        let _ = try await client.sendRequest(
            method: DaemonMethods.sessionKill,
            params: .object(["sessionId": .string(sessionId)]),
            traceId: traceId
        )
    }

    /// Fetch recent daemon logs from in-memory ring buffer.
    func fetchLogs(count: Int = 200, traceId: String? = nil, requestTraceId: String? = nil) async throws -> [DaemonLogEntry] {
        var params: [String: JSONValue] = [
            "count": .int(count)
        ]
        if let traceId, !traceId.isEmpty {
            params["traceId"] = .string(traceId)
        }
        let result = try await client.sendRequest(
            method: DaemonMethods.logs,
            params: .object(params),
            traceId: requestTraceId
        )
        return parseDaemonLogs(result["entries"])
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

    private func parseConversationOpenResult(_ value: JSONValue) throws -> DaemonConversationOpenResult {
        guard let conversation = parseDaemonConversation(value["conversation"]) else {
            throw ACPError.unexpectedResponse
        }
        guard let attachmentValue = value["attachment"] else {
            throw ACPError.unexpectedResponse
        }
        guard let runtimeId = attachmentValue["runtimeId"]?.stringValue else {
            throw ACPError.unexpectedResponse
        }
        let attachment = DaemonConversationAttachment(
            runtimeId: runtimeId,
            state: attachmentValue["state"]?.stringValue ?? "unknown",
            bufferedEvents: parseBufferedEvents(attachmentValue["bufferedEvents"]),
            reusedRuntime: attachmentValue["reusedRuntime"]?.boolValue ?? false,
            restoredFromHistory: attachmentValue["restoredFromHistory"]?.boolValue ?? false
        )
        return DaemonConversationOpenResult(conversation: conversation, attachment: attachment)
    }

    private func parseDaemonConversations(_ value: JSONValue?) -> [DaemonConversationInfo] {
        guard let arr = value?.arrayValue else { return [] }
        return arr.compactMap { parseDaemonConversation($0) }
    }

    private func parseDaemonConversation(_ value: JSONValue?) -> DaemonConversationInfo? {
        guard let value, let conversationId = value["conversationId"]?.stringValue else {
            return nil
        }
        return DaemonConversationInfo(
            conversationId: conversationId,
            runtimeId: value["runtimeId"]?.stringValue,
            state: value["state"]?.stringValue ?? "unknown",
            cwd: value["cwd"]?.stringValue ?? "",
            command: value["command"]?.stringValue,
            title: value["title"]?.stringValue,
            updatedAt: parseDaemonDate(value["updatedAt"]?.stringValue),
            ownerId: value["ownerId"]?.stringValue,
            origin: value["origin"]?.stringValue,
            lastEventSeq: UInt64(value["lastEventSeq"]?.intValue ?? 0)
        )
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

    private func parseDaemonLogs(_ value: JSONValue?) -> [DaemonLogEntry] {
        guard let arr = value?.arrayValue else { return [] }
        return arr.compactMap { item in
            let timestamp = item["timestamp"]?.stringValue ?? ""
            let level = item["level"]?.stringValue ?? ""
            let message = item["message"]?.stringValue ?? ""
            var attrs: [String: String] = [:]
            if let attrObj = item["attrs"]?.objectValue {
                for (key, value) in attrObj {
                    if let stringValue = value.stringValue {
                        attrs[key] = stringValue
                    } else if let intValue = value.intValue {
                        attrs[key] = String(intValue)
                    } else if let boolValue = value.boolValue {
                        attrs[key] = boolValue ? "true" : "false"
                    }
                }
            }
            return DaemonLogEntry(
                timestamp: timestamp,
                level: level,
                message: message,
                attrs: attrs
            )
        }
    }
}
