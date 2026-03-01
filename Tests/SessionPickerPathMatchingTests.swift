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
}
