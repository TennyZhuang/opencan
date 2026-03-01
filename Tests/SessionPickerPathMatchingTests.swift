import XCTest
@testable import OpenCAN

final class SessionPickerPathMatchingTests: XCTestCase {
    func testMatchesSamePathWithTrailingSlashDifference() {
        XCTAssertTrue(
            workspacePathMatchesSessionCwd(
                workspacePath: "/home/tz/articles/",
                sessionCwd: "/home/tz/articles",
                username: "tz"
            )
        )
    }

    func testMatchesTildeToHomeExpansion() {
        XCTAssertTrue(
            workspacePathMatchesSessionCwd(
                workspacePath: "~/articles",
                sessionCwd: "/home/tz/articles",
                username: "tz"
            )
        )
    }

    func testMatchesHomeToTildeExpansion() {
        XCTAssertTrue(
            workspacePathMatchesSessionCwd(
                workspacePath: "/home/tz/articles",
                sessionCwd: "~/articles",
                username: "tz"
            )
        )
    }

    func testDoesNotMatchDifferentDirectories() {
        XCTAssertFalse(
            workspacePathMatchesSessionCwd(
                workspacePath: "/home/tz/articles",
                sessionCwd: "/home/tz/other",
                username: "tz"
            )
        )
    }

    func testMergeWorkspaceSessionsSuppressesExternalHistorySourceDuplicate() {
        let recovered = Session(
            sessionId: "managed-session",
            sessionCwd: "/home/tz/repo",
            historySessionId: "external-source"
        )
        recovered.title = "Recovered"
        recovered.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonSessions = [
            DaemonSessionInfo(
                sessionId: "external-source",
                cwd: "/home/tz/repo",
                state: "external",
                lastEventSeq: 20,
                command: nil,
                title: "Recovered",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            DaemonSessionInfo(
                sessionId: "external-other",
                cwd: "/home/tz/repo",
                state: "external",
                lastEventSeq: 10,
                command: nil,
                title: "Other",
                updatedAt: Date(timeIntervalSince1970: 150)
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonSessions: daemonSessions,
            localSessions: [recovered]
        )

        XCTAssertEqual(
            Set(merged.map(\.sessionId)),
            Set(["managed-session", "external-other"])
        )
    }

    func testMergeWorkspaceSessionsKeepsExternalWhenNoRecoveredMappingExists() {
        let local = Session(
            sessionId: "managed-session",
            sessionCwd: "/home/tz/repo"
        )
        local.title = "Managed"
        local.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonSessions = [
            DaemonSessionInfo(
                sessionId: "external-source",
                cwd: "/home/tz/repo",
                state: "external",
                lastEventSeq: 20,
                command: nil,
                title: "Recovered",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonSessions: daemonSessions,
            localSessions: [local]
        )

        XCTAssertEqual(
            Set(merged.map(\.sessionId)),
            Set(["managed-session", "external-source"])
        )
    }
}
