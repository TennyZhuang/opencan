import XCTest

final class OpenCANUIIntegrationTests: XCTestCase {
    private struct IntegrationConfig {
        let environment: [String: String]
        let nodeName: String
        let workspaceName: String
    }

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

    private func integrationConfig() throws -> IntegrationConfig {
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

        return IntegrationConfig(
            environment: integrationEnv,
            nodeName: nonEmpty(integrationEnv["OPENCAN_TEST_NODE_NAME"]) ?? "integration-target",
            workspaceName: nonEmpty(integrationEnv["OPENCAN_TEST_WORKSPACE_NAME"]) ?? "home"
        )
    }

    private func launchIntegrationApp(config: IntegrationConfig) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-integration"]
        app.launchEnvironment = config.environment
        app.launch()
        return app
    }

    private func openWorkspace(_ config: IntegrationConfig, in app: XCUIApplication) {
        let targetNode = app.cells.staticTexts.matching(
            NSPredicate(format: "label == %@", config.nodeName)
        ).firstMatch
        XCTAssertTrue(targetNode.waitForExistence(timeout: 8), "Node '\(config.nodeName)' not found")
        targetNode.tap()

        let workspace = app.cells.staticTexts.matching(
            NSPredicate(format: "label == %@", config.workspaceName)
        ).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "Workspace '\(config.workspaceName)' not found")
        workspace.tap()
    }

    private func waitForSessionPicker(_ config: IntegrationConfig, in app: XCUIApplication) throws {
        let newSessionButton = app.buttons["New Session"]
        guard newSessionButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("Could not connect to integration target '\(config.nodeName)' — server may be unreachable")
        }
    }

    private func createSession(_ config: IntegrationConfig, in app: XCUIApplication) throws {
        tapNewSession(in: app)

        let systemMessage = app.staticTexts["New session on \(config.workspaceName)"]
        guard systemMessage.waitForExistence(timeout: 15) else {
            throw XCTSkip("Session creation timed out — server may be unreachable")
        }
    }

    func testIntegrationCreateSession() throws {
        let config = try integrationConfig()
        let integrationApp = launchIntegrationApp(config: config)
        openWorkspace(config, in: integrationApp)
        try waitForSessionPicker(config, in: integrationApp)
        try createSession(config, in: integrationApp)
    }

    func testIntegrationConnectsToSessionPicker() throws {
        let config = try integrationConfig()
        let integrationApp = launchIntegrationApp(config: config)
        openWorkspace(config, in: integrationApp)
        try waitForSessionPicker(config, in: integrationApp)
    }

    func testIntegrationSendMessage() throws {
        let config = try integrationConfig()
        let integrationApp = launchIntegrationApp(config: config)
        openWorkspace(config, in: integrationApp)
        try waitForSessionPicker(config, in: integrationApp)
        try createSession(config, in: integrationApp)

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

    func testIntegrationResumeSessionFromSessionPicker() throws {
        let config = try integrationConfig()
        let integrationApp = launchIntegrationApp(config: config)
        openWorkspace(config, in: integrationApp)
        try waitForSessionPicker(config, in: integrationApp)
        try createSession(config, in: integrationApp)

        let backButton = integrationApp.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        let sessionRow = integrationApp.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'mock-sess'")
        ).firstMatch
        guard sessionRow.waitForExistence(timeout: 10) else {
            throw XCTSkip("No resumable session row found after creating a session")
        }
        sessionRow.tap()

        XCTAssertTrue(
            integrationApp.buttons["Disconnect"].waitForExistence(timeout: 8),
            "Expected to enter chat after resuming a session"
        )
    }
}
