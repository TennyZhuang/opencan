import Foundation
import os

/// Shared loggers for the app. Writes to both os_log and a file for debugging.
enum Log {
    static let ssh = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "SSH")
    static let acp = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "ACP")
    static let transport = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "Transport")
    static let app = Logger(subsystem: "com.tianyizhuang.OpenCAN", category: "App")

    /// Also write to a file for easy retrieval from simulator container.
    static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("opencan.log")
    }()

    static func toFile(_ message: String) {
        let line = "\(Date()): \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}
