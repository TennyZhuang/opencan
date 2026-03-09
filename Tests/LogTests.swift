import XCTest
@testable import OpenCAN

final class LogTests: XCTestCase {
    func testArchivedLogFileURLUsesNumericSuffixes() {
        let baseURL = URL(fileURLWithPath: "/tmp/opencan.log")

        XCTAssertEqual(
            Log.archivedLogFileURL(index: 1, baseURL: baseURL).path,
            "/tmp/opencan.log.1"
        )
        XCTAssertEqual(
            Log.archivedLogFileURL(index: 3, baseURL: baseURL).path,
            "/tmp/opencan.log.3"
        )
    }

    func testRotateLogFilesKeepsNewestArchives() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let baseURL = dir.appendingPathComponent("opencan.log")
        try Data("current".utf8).write(to: baseURL)
        try Data("older-1".utf8).write(to: Log.archivedLogFileURL(index: 1, baseURL: baseURL))
        try Data("older-2".utf8).write(to: Log.archivedLogFileURL(index: 2, baseURL: baseURL))

        Log.rotateLogFiles(baseURL: baseURL, maxArchivedFiles: 3, fileManager: fileManager)

        XCTAssertEqual(
            try String(contentsOf: Log.archivedLogFileURL(index: 1, baseURL: baseURL)),
            "current"
        )
        XCTAssertEqual(
            try String(contentsOf: Log.archivedLogFileURL(index: 2, baseURL: baseURL)),
            "older-1"
        )
        XCTAssertEqual(
            try String(contentsOf: Log.archivedLogFileURL(index: 3, baseURL: baseURL)),
            "older-2"
        )
    }
}
