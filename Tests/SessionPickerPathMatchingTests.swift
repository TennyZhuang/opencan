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

    func testMergeWorkspaceSessionsKeepsManagedAndExternalSessions() {
        let managed = Session(
            sessionId: "managed-session",
            sessionCwd: "/home/tz/repo"
        )
        managed.title = "Managed"
        managed.lastUsedAt = Date(timeIntervalSince1970: 200)

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
            localSessions: [managed]
        )

        XCTAssertEqual(
            Set(merged.map(\.sessionId)),
            Set(["managed-session", "external-source", "external-other"])
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

    func testMergeWorkspaceSessionsHidesExternalWhenRecoveredManagedSessionIsLive() {
        let managed = Session(
            sessionId: "managed-session",
            canonicalSessionId: "external-source",
            sessionCwd: "/home/tz/repo"
        )
        managed.title = "Recovered"
        managed.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonSessions = [
            DaemonSessionInfo(
                sessionId: "external-source",
                cwd: "/home/tz/repo",
                state: "external",
                lastEventSeq: 20,
                command: nil,
                title: "External",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            DaemonSessionInfo(
                sessionId: "managed-session",
                cwd: "/home/tz/repo",
                state: "idle",
                lastEventSeq: 25,
                command: nil,
                title: nil,
                updatedAt: Date(timeIntervalSince1970: 210)
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonSessions: daemonSessions,
            localSessions: [managed]
        )

        XCTAssertEqual(Set(merged.map(\.sessionId)), Set(["managed-session"]))
    }

    func testMergeWorkspaceSessionsIncludesKnownLocalSessionEvenWhenDaemonCwdDiffers() {
        let local = Session(
            sessionId: "legacy-session",
            sessionCwd: "/home/tz/repo"
        )
        local.title = "Legacy"
        local.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonSessions = [
            DaemonSessionInfo(
                sessionId: "legacy-session",
                cwd: "/tmp/other-project",
                state: "external",
                lastEventSeq: 30,
                command: nil,
                title: "Recovered elsewhere",
                updatedAt: Date(timeIntervalSince1970: 210)
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonSessions: daemonSessions,
            localSessions: [local]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sessionId, "legacy-session")
        XCTAssertEqual(merged.first?.daemonState, "external")
    }
}
