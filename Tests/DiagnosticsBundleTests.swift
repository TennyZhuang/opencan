import XCTest
@testable import OpenCAN

final class DiagnosticsBundleTests: XCTestCase {
    func testCaptureLocalLogFileMarksMissingFiles() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.log")

        let capture = DiagnosticsBundleWriter.captureLocalLogFile(label: "ios-current", url: url, maxBytes: 64)

        XCTAssertEqual(capture.label, "ios-current")
        XCTAssertEqual(capture.path, url.path)
        XCTAssertFalse(capture.exists)
        XCTAssertNil(capture.totalBytes)
        XCTAssertNil(capture.contents)
        XCTAssertNil(capture.error)
    }

    func testCaptureLocalLogFileTruncatesToTail() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let url = dir.appendingPathComponent("opencan.log")
        try Data("abcdefghij".utf8).write(to: url)

        let capture = DiagnosticsBundleWriter.captureLocalLogFile(label: "ios-current", url: url, maxBytes: 4)

        XCTAssertTrue(capture.exists)
        XCTAssertEqual(capture.totalBytes, 10)
        XCTAssertEqual(capture.includedBytes, 4)
        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.contents, "ghij")
        XCTAssertNil(capture.error)
    }

    func testWriteBundleProducesJSONFile() throws {
        let exportedAt = Date(timeIntervalSince1970: 1234)
        let payload = DiagnosticsBundlePayload(
            schemaVersion: DiagnosticsBundleWriter.schemaVersion,
            exportedAt: exportedAt,
            bundle: DiagnosticsBundleInfo(
                fileName: DiagnosticsBundleWriter.bundleFileName(exportedAt: exportedAt),
                maxBytesPerLogFile: DiagnosticsBundleWriter.maxBytesPerLogFile
            ),
            app: DiagnosticsAppInfo(bundleIdentifier: "com.example.app", version: "1.0", build: "42"),
            device: DiagnosticsDeviceInfo(model: "iPhone", systemName: "iOS", systemVersion: "18.0"),
            filters: DiagnosticsBundleFilters(daemonTraceId: "trace-123"),
            state: DiagnosticsBundleState(
                connectionStatus: "connected",
                connectionError: nil,
                currentTraceId: "trace-123",
                currentSessionId: "session-1",
                isPrompting: false,
                messageCount: 2,
                activeNode: nil,
                activeWorkspace: nil,
                activeSession: nil,
                availableNodeAgents: ["claude"],
                hasReliableAgentAvailability: true,
                daemonSessions: []
            ),
            iosLogMetadata: LogStorageMetadata(
                schemaVersion: 1,
                service: "ios-app",
                currentFilePath: "/tmp/opencan.log",
                currentFileSizeBytes: 10,
                archivedFiles: [],
                maxFileBytes: 100,
                maxArchivedFiles: 3,
                bufferEntryCapacity: 2000
            ),
            daemonLogMetadata: nil,
            iosLogs: [],
            daemonLogs: [],
            iosLogFiles: [.missing(label: "ios-current", path: "/tmp/opencan.log")],
            daemonLogFiles: [.missing(label: "daemon-current", path: "~/.opencan/daemon.log")],
            notes: ["test"]
        )

        let url = try DiagnosticsBundleWriter.writeBundle(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, DiagnosticsBundleWriter.schemaVersion)
        XCTAssertEqual(json["notes"] as? [String], ["test"])
    }
}
