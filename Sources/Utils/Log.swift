import Foundation
import os

/// Shared loggers for the app. Writes to both os_log and a file for debugging.
enum Log {
    static let ssh = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "SSH")
    static let acp = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "ACP")
    static let transport = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "Transport")
    static let app = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "App")

    static let buffer = LogRingBuffer(maxSize: 2000)

    /// Also write to a file for easy retrieval from simulator container.
    static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("opencan.log")
    }()

    private static let fileQueue = DispatchQueue(label: "com.tianyizhuang.OpenCAN.log")
    private static var fileHandle: FileHandle?
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

    private static func writeToFile(_ entry: LogEntry) {
        fileQueue.async {
            guard let data = try? encoder.encode(entry) else { return }
            if fileHandle == nil {
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
                }
                fileHandle = try? FileHandle(forWritingTo: logFileURL)
                fileHandle?.seekToEndOfFile()
            }
            fileHandle?.write(data)
            fileHandle?.write(Data([0x0A]))
            try? fileHandle?.synchronize()
        }
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
}
