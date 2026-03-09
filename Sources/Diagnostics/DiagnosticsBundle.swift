import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsCapturedLogFile: Codable, Equatable, Sendable {
    let label: String
    let path: String
    let exists: Bool
    let totalBytes: Int64?
    let includedBytes: Int
    let truncated: Bool
    let contents: String?
    let error: String?

    static func missing(label: String, path: String) -> DiagnosticsCapturedLogFile {
        DiagnosticsCapturedLogFile(
            label: label,
            path: path,
            exists: false,
            totalBytes: nil,
            includedBytes: 0,
            truncated: false,
            contents: nil,
            error: nil
        )
    }

    static func failure(label: String, path: String, error: String) -> DiagnosticsCapturedLogFile {
        DiagnosticsCapturedLogFile(
            label: label,
            path: path,
            exists: false,
            totalBytes: nil,
            includedBytes: 0,
            truncated: false,
            contents: nil,
            error: error
        )
    }
}

struct DiagnosticsBundlePayload: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let bundle: DiagnosticsBundleInfo
    let app: DiagnosticsAppInfo
    let device: DiagnosticsDeviceInfo
    let filters: DiagnosticsBundleFilters
    let state: DiagnosticsBundleState
    let iosLogMetadata: LogStorageMetadata
    let daemonLogMetadata: LogStorageMetadata?
    let iosLogs: [LogEntry]
    let daemonLogs: [DaemonLogEntry]
    let iosLogFiles: [DiagnosticsCapturedLogFile]
    let daemonLogFiles: [DiagnosticsCapturedLogFile]
    let notes: [String]
}

struct DiagnosticsBundleInfo: Codable, Sendable {
    let fileName: String
    let maxBytesPerLogFile: Int
}

struct DiagnosticsAppInfo: Codable, Sendable {
    let bundleIdentifier: String
    let version: String
    let build: String
}

struct DiagnosticsDeviceInfo: Codable, Sendable {
    let model: String
    let systemName: String
    let systemVersion: String
}

struct DiagnosticsBundleFilters: Codable, Sendable {
    let daemonTraceId: String?
}

struct DiagnosticsBundleState: Codable, Sendable {
    let connectionStatus: String
    let connectionError: String?
    let currentTraceId: String?
    let currentSessionId: String?
    let isPrompting: Bool
    let messageCount: Int
    let activeNode: DiagnosticsNodeSnapshot?
    let activeWorkspace: DiagnosticsWorkspaceSnapshot?
    let activeSession: DiagnosticsSessionSnapshot?
    let availableNodeAgents: [String]
    let hasReliableAgentAvailability: Bool
    let daemonSessions: [DaemonSessionInfo]
}

struct DiagnosticsNodeSnapshot: Codable, Sendable {
    let name: String
    let host: String
    let port: Int
    let username: String
    let jumpHost: String?
}

struct DiagnosticsWorkspaceSnapshot: Codable, Sendable {
    let name: String
    let path: String
}

struct DiagnosticsSessionSnapshot: Codable, Sendable {
    let runtimeId: String
    let conversationId: String
    let conversationCwd: String?
    let title: String?
    let agentID: String?
    let agentCommand: String?
    let createdAt: Date
    let lastUsedAt: Date
}

enum DiagnosticsBundleWriter {
    static let schemaVersion = 1
    static let maxBytesPerLogFile = 512 * 1024

    static func bundleFileName(exportedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "opencan-diagnostics-\(formatter.string(from: exportedAt)).json"
    }

    static func writeBundle(_ payload: DiagnosticsBundlePayload) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(payload.bundle.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func captureLocalLogFiles(
        labeledURLs: [(label: String, url: URL)],
        maxBytes: Int = maxBytesPerLogFile
    ) -> [DiagnosticsCapturedLogFile] {
        labeledURLs.map { captureLocalLogFile(label: $0.label, url: $0.url, maxBytes: maxBytes) }
    }

    static func captureLocalLogFile(
        label: String,
        url: URL,
        maxBytes: Int = maxBytesPerLogFile
    ) -> DiagnosticsCapturedLogFile {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing(label: label, path: url.path)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let boundedBytes = max(maxBytes, 1)
            if totalBytes > Int64(boundedBytes) {
                try handle.seek(toOffset: UInt64(totalBytes - Int64(boundedBytes)))
            }

            let data = try handle.readToEnd() ?? Data()
            return DiagnosticsCapturedLogFile(
                label: label,
                path: url.path,
                exists: true,
                totalBytes: totalBytes,
                includedBytes: data.count,
                truncated: totalBytes > Int64(data.count),
                contents: String(decoding: data, as: UTF8.self),
                error: nil
            )
        } catch {
            return .failure(label: label, path: url.path, error: error.localizedDescription)
        }
    }

    static func appInfo() -> DiagnosticsAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticsAppInfo(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown"
        )
    }

    static func deviceInfo() -> DiagnosticsDeviceInfo {
        #if canImport(UIKit)
        DiagnosticsDeviceInfo(
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )
        #else
        DiagnosticsDeviceInfo(
            model: "unknown",
            systemName: ProcessInfo.processInfo.operatingSystemVersionString,
            systemVersion: "unknown"
        )
        #endif
    }
}
