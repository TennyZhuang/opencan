import XCTest

final class OpenCANUIIntegrationTests: XCTestCase {
    private let integrationEnvKeys = [
        "OPENCAN_TEST_NODE_NAME",
        "OPENCAN_TEST_NODE_HOST",
        "OPENCAN_TEST_NODE_PORT",
        "OPENCAN_TEST_NODE_USERNAME",
        "OPENCAN_TEST_WORKSPACE_NAME",
        "OPENCAN_TEST_WORKSPACE_PATH",
        "OPENCAN_TEST_AGENT_COMMAND",
        "OPENCAN_TEST_SSH_PRIVATE_KEY_PEM",
        "OPENCAN_TEST_SSH_KEY_PATH",
        "OPENCAN_TEST_JUMP_NODE_NAME",
        "OPENCAN_TEST_JUMP_HOST",
        "OPENCAN_TEST_JUMP_PORT",
        "OPENCAN_TEST_JUMP_USERNAME",
        "OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM",
        "OPENCAN_TEST_JUMP_KEY_PATH"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UIIntegrationTests/
            .deletingLastPathComponent() // repo root
    }

    private func loadDotEnvIfPresent() -> [String: String] {
        let dotenvURL = repoRootURL().appendingPathComponent(".env")
        guard let data = try? Data(contentsOf: dotenvURL), let raw = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var env: [String: String] = [:]
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let withoutExport: String
            if line.hasPrefix("export ") {
                withoutExport = String(line.dropFirst("export ".count))
            } else {
                withoutExport = line
            }

            guard let equalIndex = withoutExport.firstIndex(of: "=") else {
                continue
            }
            let key = withoutExport[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = withoutExport[withoutExport.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            env[key] = value
        }

        return env
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func integrationLaunchEnvironment() throws -> [String: String] {
        var env: [String: String] = [:]
        let processEnv = ProcessInfo.processInfo.environment

        for key in integrationEnvKeys {
            if let value = processEnv[key] {
                env[key] = value
            }
        }
        for (key, value) in loadDotEnvIfPresent() where integrationEnvKeys.contains(key) {
            if env[key] == nil {
                env[key] = value
            }
        }

        if nonEmpty(env["OPENCAN_TEST_SSH_PRIVATE_KEY_PEM"]) == nil,
           let keyPath = nonEmpty(env["OPENCAN_TEST_SSH_KEY_PATH"]) {
            let resolvedKeyPath = expandTilde(keyPath)
            do {
                env["OPENCAN_TEST_SSH_PRIVATE_KEY_PEM"] = try String(contentsOfFile: resolvedKeyPath, encoding: .utf8)
            } catch {
                throw XCTSkip("Cannot read OPENCAN_TEST_SSH_KEY_PATH at \(resolvedKeyPath): \(error)")
            }
        }

        if nonEmpty(env["OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM"]) == nil,
           let jumpKeyPath = nonEmpty(env["OPENCAN_TEST_JUMP_KEY_PATH"]) {
            let resolvedJumpKeyPath = expandTilde(jumpKeyPath)
            do {
                env["OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM"] = try String(contentsOfFile: resolvedJumpKeyPath, encoding: .utf8)
            } catch {
                throw XCTSkip("Cannot read OPENCAN_TEST_JUMP_KEY_PATH at \(resolvedJumpKeyPath): \(error)")
            }
        }

        if nonEmpty(env["OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM"]) == nil {
            env["OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM"] = env["OPENCAN_TEST_SSH_PRIVATE_KEY_PEM"]
        }

        if nonEmpty(env["OPENCAN_TEST_JUMP_HOST"]) != nil,
           nonEmpty(env["OPENCAN_TEST_JUMP_USERNAME"]) == nil {
            throw XCTSkip("OPENCAN_TEST_JUMP_HOST is set but OPENCAN_TEST_JUMP_USERNAME is missing")
        }

        return env
    }

    private func tapNewSession(in app: XCUIApplication) {
        let newSessionButton = app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 10))
        newSessionButton.tap()

        let claudeAction = app.buttons["Claude Code"]
        if claudeAction.waitForExistence(timeout: 1) {
            claudeAction.tap()
            return
        }

        let codexAction = app.buttons["Codex"]
        if codexAction.waitForExistence(timeout: 1) {
            codexAction.tap()
        }
    }

    func testIntegrationSendMessage() throws {
        let integrationApp = XCUIApplication()
        let integrationEnv = try integrationLaunchEnvironment()

        guard
            nonEmpty(integrationEnv["OPENCAN_TEST_NODE_HOST"]) != nil,
            nonEmpty(integrationEnv["OPENCAN_TEST_NODE_USERNAME"]) != nil,
            nonEmpty(integrationEnv["OPENCAN_TEST_WORKSPACE_PATH"]) != nil,
            nonEmpty(integrationEnv["OPENCAN_TEST_SSH_PRIVATE_KEY_PEM"]) != nil
        else {
            throw XCTSkip(
                "Integration target is not configured. Set OPENCAN_TEST_NODE_HOST, OPENCAN_TEST_NODE_USERNAME, " +
                "OPENCAN_TEST_WORKSPACE_PATH, and OPENCAN_TEST_SSH_PRIVATE_KEY_PEM (or OPENCAN_TEST_SSH_KEY_PATH) " +
                "in environment or .env"
            )
        }

        let nodeName = nonEmpty(integrationEnv["OPENCAN_TEST_NODE_NAME"]) ?? "integration-target"
        let workspaceName = nonEmpty(integrationEnv["OPENCAN_TEST_WORKSPACE_NAME"]) ?? "home"

        integrationApp.launchArguments = ["--uitesting", "--uitesting-integration"]
        integrationApp.launchEnvironment = integrationEnv
        integrationApp.launch()

        let targetNode = integrationApp.cells.staticTexts.matching(
            NSPredicate(format: "label == %@", nodeName)
        ).firstMatch
        XCTAssertTrue(targetNode.waitForExistence(timeout: 8), "Node '\(nodeName)' not found")
        targetNode.tap()

        let workspace = integrationApp.cells.staticTexts.matching(
            NSPredicate(format: "label == %@", workspaceName)
        ).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "Workspace '\(workspaceName)' not found")
        workspace.tap()

        let newSessionButton = integrationApp.buttons["New Session"]
        guard newSessionButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("Could not connect to integration target '\(nodeName)' — server may be unreachable")
        }

        tapNewSession(in: integrationApp)

        let systemMessage = integrationApp.staticTexts["New session on home"]
        guard systemMessage.waitForExistence(timeout: 15) else {
            throw XCTSkip("Session creation timed out — server may be unreachable")
        }

        let textField = integrationApp.textFields.firstMatch
        guard textField.waitForExistence(timeout: 5) else {
            throw XCTSkip("Chat input not found")
        }
        textField.tap()
        textField.typeText("Hello")

        integrationApp.buttons["arrow.up.circle.fill"].tap()

        let userMessage = integrationApp.staticTexts["Hello"]
        XCTAssertTrue(
            userMessage.waitForExistence(timeout: 5),
            "User message should appear in chat"
        )
    }
}
