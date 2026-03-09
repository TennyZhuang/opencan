import Foundation
import os

/// Shared loggers for the app. Writes to both os_log and a file for debugging.
enum Log {
    static let schemaVersion = 1
    static let ssh = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "SSH")
    static let acp = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "ACP")
    static let transport = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "Transport")
    static let app = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "App")

    static let bufferCapacity = 2000
    static let buffer = LogRingBuffer(maxSize: bufferCapacity)

    /// Also write to a file for easy retrieval from simulator container.
    static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("opencan.log")
    }()
    private static let fileQueue = DispatchQueue(label: "com.tianyizhuang.OpenCAN.log")
    private static let maxLogFileBytes = 10 * 1024 * 1024
    private static let maxArchivedLogFiles = 3
    private static let syncWriteBatchSize = 20
    private static let syncInterval: TimeInterval = 2
    private static var fileHandle: FileHandle?
    private static var pendingSyncWrites = 0
    private static var lastSyncAt = Date.distantPast
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func log(
        level: String = "info",
        component: String,
        _ message: String,
        traceId: String? = nil,
        sessionId: String? = nil,
        extra: [String: String]? = nil
    ) {
        let entry = LogEntry(
            level: level,
            component: component,
            message: message,
            traceId: traceId,
            sessionId: sessionId,
            extra: extra
        )
        writeToUnifiedLogger(entry)
        buffer.append(entry)
        writeToFile(entry)
    }

    /// Backward-compatible helper for existing call sites.
    /// Supports legacy "[Component] message" prefix parsing.
    static func toFile(_ message: String) {
        let parsed = parseLegacyMessage(message)
        log(
            level: "info",
            component: parsed.component,
            parsed.message,
            extra: parsed.extra
        )
    }

    static func timed<T>(
        _ operation: String,
        component: String,
        traceId: String? = nil,
        sessionId: String? = nil,
        block: @Sendable () async throws -> T
    ) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try await block()
            let durationMs = milliseconds(since: start)
            log(
                component: component,
                "\(operation) completed",
                traceId: traceId,
                sessionId: sessionId,
                extra: ["durationMs": "\(durationMs)"]
            )
            return result
        } catch {
            let durationMs = milliseconds(since: start)
            log(
                level: "error",
                component: component,
                "\(operation) failed: \(error.localizedDescription)",
                traceId: traceId,
                sessionId: sessionId,
                extra: ["durationMs": "\(durationMs)"]
            )
            throw error
        }
    }

    static func diagnosticsMetadata() -> LogStorageMetadata {
        let archivedFiles = archivedLogFileURLs().compactMap(fileInfo(for:))
        return LogStorageMetadata(
            schemaVersion: schemaVersion,
            service: "ios-app",
            currentFilePath: logFileURL.path,
            currentFileSizeBytes: currentLogFileSize(),
            archivedFiles: archivedFiles,
            maxFileBytes: Int64(maxLogFileBytes),
            maxArchivedFiles: maxArchivedLogFiles,
            bufferEntryCapacity: bufferCapacity
        )
    }

    private static func writeToFile(_ entry: LogEntry) {
        fileQueue.async {
            guard let data = try? encoder.encode(entry) else { return }
            let lineBreak = Data([0x0A])
            rotateLogIfNeeded(incomingBytes: data.count + lineBreak.count)
            ensureFileHandle()
            fileHandle?.write(data)
            fileHandle?.write(lineBreak)
            pendingSyncWrites += 1
            syncFileIfNeeded()
        }
    }

    private static func ensureFileHandle() {
        if fileHandle != nil { return }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private static func rotateLogIfNeeded(incomingBytes: Int) {
        let currentSize = currentLogFileSize()
        guard currentSize + Int64(incomingBytes) > Int64(maxLogFileBytes) else { return }

        syncFileIfNeeded(force: true)
        fileHandle?.closeFile()
        fileHandle = nil
        pendingSyncWrites = 0

        rotateLogFiles(baseURL: logFileURL, maxArchivedFiles: maxArchivedLogFiles)
    }

    static func rotateLogFiles(
        baseURL: URL,
        maxArchivedFiles: Int,
        fileManager: FileManager = .default
    ) {
        guard maxArchivedFiles > 0 else {
            try? fileManager.removeItem(at: baseURL)
            return
        }

        for index in stride(from: maxArchivedFiles, through: 1, by: -1) {
            let destination = archivedLogFileURL(index: index, baseURL: baseURL)
            let source = index == 1
                ? baseURL
                : archivedLogFileURL(index: index - 1, baseURL: baseURL)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    static func archivedLogFileURL(index: Int, baseURL: URL) -> URL {
        URL(fileURLWithPath: "\(baseURL.path).\(index)")
    }

    private static func archivedLogFileURLs() -> [URL] {
        guard maxArchivedLogFiles > 0 else { return [] }
        return (1...maxArchivedLogFiles).map { archivedLogFileURL(index: $0, baseURL: logFileURL) }
    }

    private static func fileInfo(for url: URL) -> LogArchiveFileInfo? {
        let size = fileSize(at: url)
        guard size > 0 else { return nil }
        return LogArchiveFileInfo(
            name: url.lastPathComponent,
            path: url.path,
            sizeBytes: size
        )
    }

    private static func currentLogFileSize() -> Int64 {
        fileSize(at: logFileURL)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func syncFileIfNeeded(force: Bool = false) {
        let now = Date()
        guard force
                || pendingSyncWrites >= syncWriteBatchSize
                || now.timeIntervalSince(lastSyncAt) >= syncInterval else {
            return
        }
        try? fileHandle?.synchronize()
        pendingSyncWrites = 0
        lastSyncAt = now
    }

    private static func parseLegacyMessage(_ message: String) -> (component: String, message: String, extra: [String: String]?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else {
            return ("General", trimmed, nil)
        }
        guard let endIndex = trimmed.firstIndex(of: "]") else {
            return ("General", trimmed, nil)
        }
        let componentStart = trimmed.index(after: trimmed.startIndex)
        let component = String(trimmed[componentStart..<endIndex]).trimmingCharacters(in: .whitespaces)
        let remainderStart = trimmed.index(after: endIndex)
        let remainder = String(trimmed[remainderStart...]).trimmingCharacters(in: .whitespaces)
        return (
            component.isEmpty ? "General" : component,
            remainder,
            ["legacy": "true"]
        )
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: ContinuousClock.now)
        let components = duration.components
        let ms = Double(components.seconds) * 1000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
        return Int(ms.rounded())
    }

    private static func writeToUnifiedLogger(_ entry: LogEntry) {
        let logger = logger(for: entry.component)
        let rendered = renderedUnifiedMessage(for: entry)
        switch entry.level.lowercased() {
        case "debug":
            logger.debug("\(rendered, privacy: .public)")
        case "warning", "warn":
            logger.warning("\(rendered, privacy: .public)")
        case "error":
            logger.error("\(rendered, privacy: .public)")
        case "fault":
            logger.fault("\(rendered, privacy: .public)")
        default:
            logger.info("\(rendered, privacy: .public)")
        }
    }

    private static func logger(for component: String) -> Logger {
        switch component.lowercased() {
        case let value where value.contains("ssh"):
            return ssh
        case let value where value.contains("acp"):
            return acp
        case let value where value.contains("transport"):
            return transport
        default:
            return app
        }
    }

    private static func renderedUnifiedMessage(for entry: LogEntry) -> String {
        var parts = [entry.message]
        if let traceId = entry.traceId, !traceId.isEmpty {
            parts.append("traceId=\(traceId)")
        }
        if let sessionId = entry.sessionId, !sessionId.isEmpty {
            parts.append("sessionId=\(sessionId)")
        }
        if let extra = entry.extra, !extra.isEmpty {
            let renderedExtras = extra
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            parts.append(renderedExtras)
        }
        return parts.joined(separator: " ")
    }
}
