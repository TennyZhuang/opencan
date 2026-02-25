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

    private static let fileQueue = DispatchQueue(label: "com.tianyizhuang.OpenCAN.log")
    private static var fileHandle: FileHandle?

    static func toFile(_ message: String) {
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileQueue.async {
            if fileHandle == nil {
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
                }
                fileHandle = try? FileHandle(forWritingTo: logFileURL)
                fileHandle?.seekToEndOfFile()
            }
            fileHandle?.write(data)
            try? fileHandle?.synchronize()
        }
    }
}
