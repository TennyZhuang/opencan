import Foundation

struct LogArchiveFileInfo: Codable, Equatable, Sendable {
    let name: String
    let path: String
    let sizeBytes: Int64
}

struct LogStorageMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let service: String
    let currentFilePath: String
    let currentFileSizeBytes: Int64
    let archivedFiles: [LogArchiveFileInfo]
    let maxFileBytes: Int64
    let maxArchivedFiles: Int
    let bufferEntryCapacity: Int?
}

struct DaemonLogSnapshot: Sendable {
    let entries: [DaemonLogEntry]
    let metadata: LogStorageMetadata?
}
