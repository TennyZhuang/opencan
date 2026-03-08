import XCTest
@testable import OpenCAN

final class SessionPickerPathMatchingTests: XCTestCase {
    func testMatchesSamePathWithTrailingSlashDifference() {
        XCTAssertTrue(
            workspacePathMatchesConversationCwd(
                workspacePath: "/home/tz/articles/",
                conversationCwd: "/home/tz/articles",
                username: "tz"
            )
        )
    }

    func testMatchesTildeToHomeExpansion() {
        XCTAssertTrue(
            workspacePathMatchesConversationCwd(
                workspacePath: "~/articles",
                conversationCwd: "/home/tz/articles",
                username: "tz"
            )
        )
    }

    func testMatchesHomeToTildeExpansion() {
        XCTAssertTrue(
            workspacePathMatchesConversationCwd(
                workspacePath: "/home/tz/articles",
                conversationCwd: "~/articles",
                username: "tz"
            )
        )
    }

    func testDoesNotMatchDifferentDirectories() {
        XCTAssertFalse(
            workspacePathMatchesConversationCwd(
                workspacePath: "/home/tz/articles",
                conversationCwd: "/home/tz/other",
                username: "tz"
            )
        )
    }

    func testMergeWorkspaceSessionsKeepsManagedAndRestorableConversations() {
        let managed = Session(
            runtimeId: "managed-session",
            conversationId: "managed-session",
            conversationCwd: "/home/tz/repo"
        )
        managed.title = "Managed"
        managed.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonConversations = [
            DaemonConversationInfo(
                conversationId: "external-source",
                runtimeId: nil,
                state: "restorable",
                cwd: "/home/tz/repo",
                command: nil,
                title: "Recovered",
                updatedAt: Date(timeIntervalSince1970: 100),
                ownerId: nil,
                origin: "discovered",
                lastEventSeq: 20
            ),
            DaemonConversationInfo(
                conversationId: "external-other",
                runtimeId: nil,
                state: "restorable",
                cwd: "/home/tz/repo",
                command: nil,
                title: "Other",
                updatedAt: Date(timeIntervalSince1970: 150),
                ownerId: nil,
                origin: "discovered",
                lastEventSeq: 10
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonConversations: daemonConversations,
            localSessions: [managed]
        )

        XCTAssertEqual(
            Set(merged.map(\.conversationId)),
            Set(["managed-session", "external-source", "external-other"])
        )
    }

    func testMergeWorkspaceSessionsKeepsRestorableWhenNoRecoveredMappingExists() {
        let local = Session(
            runtimeId: "managed-session",
            conversationId: "managed-session",
            conversationCwd: "/home/tz/repo"
        )
        local.title = "Managed"
        local.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonConversations = [
            DaemonConversationInfo(
                conversationId: "external-source",
                runtimeId: nil,
                state: "restorable",
                cwd: "/home/tz/repo",
                command: nil,
                title: "Recovered",
                updatedAt: Date(timeIntervalSince1970: 100),
                ownerId: nil,
                origin: "discovered",
                lastEventSeq: 20
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonConversations: daemonConversations,
            localSessions: [local]
        )

        XCTAssertEqual(
            Set(merged.map(\.conversationId)),
            Set(["managed-session", "external-source"])
        )
    }

    func testMergeWorkspaceSessionsCollapsesRecoveredConversationToStableConversationID() {
        let managed = Session(
            runtimeId: "managed-session",
            conversationId: "external-source",
            conversationCwd: "/home/tz/repo"
        )
        managed.title = "Recovered"
        managed.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonConversations = [
            DaemonConversationInfo(
                conversationId: "external-source",
                runtimeId: "managed-session",
                state: "attached",
                cwd: "/home/tz/repo",
                command: nil,
                title: "External",
                updatedAt: Date(timeIntervalSince1970: 210),
                ownerId: "ios-owner",
                origin: "managed",
                lastEventSeq: 25
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonConversations: daemonConversations,
            localSessions: [managed]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.conversationId, "external-source")
        XCTAssertEqual(merged.first?.runtimeId, "managed-session")
    }

    func testMergeWorkspaceSessionsIncludesKnownLocalConversationEvenWhenDaemonCwdDiffers() {
        let local = Session(
            runtimeId: "legacy-runtime",
            conversationId: "legacy-conversation",
            conversationCwd: "/home/tz/repo"
        )
        local.title = "Legacy"
        local.lastUsedAt = Date(timeIntervalSince1970: 200)

        let daemonConversations = [
            DaemonConversationInfo(
                conversationId: "legacy-conversation",
                runtimeId: nil,
                state: "restorable",
                cwd: "/tmp/other-project",
                command: nil,
                title: "Recovered elsewhere",
                updatedAt: Date(timeIntervalSince1970: 210),
                ownerId: nil,
                origin: "discovered",
                lastEventSeq: 30
            ),
        ]

        let merged = mergeWorkspaceSessions(
            workspacePath: "/home/tz/repo",
            username: "tz",
            daemonConversations: daemonConversations,
            localSessions: [local]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.conversationId, "legacy-conversation")
        XCTAssertEqual(merged.first?.daemonState, "restorable")
    }
}
