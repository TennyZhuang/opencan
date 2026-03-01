import SwiftUI
import SwiftData

@main
struct OpenCANApp: App {
    static let isUITesting = CommandLine.arguments.contains("--uitesting")
    static let isUIIntegrationTesting = CommandLine.arguments.contains("--uitesting-integration")
    static let uiTestMockScenario: MockScenario = {
        if CommandLine.arguments.contains("--uitesting-long-stream") {
            return .longStream
        }
        if CommandLine.arguments.contains("--uitesting-with-tool-call") {
            return .withToolCall
        }
        return .simple
    }()

    @State private var appState = AppState()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: SSHKeyPair.self, Node.self, Workspace.self, Session.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    Task(priority: .utility) {
                        migrateSSHKeysToKeychainIfNeeded()
                    }
                    seedUITestDataIfNeeded()
                    seedUIIntegrationDataIfNeeded()
                }
        }
        .modelContainer(modelContainer)
    }

    /// UI tests rely on a pre-seeded node/workspace so they can run deterministically.
    /// Seed only placeholder values and only in UI testing mode.
    private func seedUITestDataIfNeeded() {
        guard OpenCANApp.isUITesting else { return }
        guard !UserDefaults.standard.bool(forKey: "uiTestDataSeeded") else { return }

        let context = ModelContext(modelContainer)

        let node = Node(name: "cp32", host: "example.com", port: 22, username: "demo-user")
        context.insert(node)

        let workspace = Workspace(name: "home", path: "/home/demo-user")
        workspace.node = node
        context.insert(workspace)

        try? context.save()
        UserDefaults.standard.set(true, forKey: "uiTestDataSeeded")
    }

    /// Integration UI tests use environment-driven seed data so no sensitive
    /// infrastructure values are hardcoded in source.
    private func seedUIIntegrationDataIfNeeded() {
        guard OpenCANApp.isUIIntegrationTesting else { return }

        let env = ProcessInfo.processInfo.environment
        guard
            let nodeHost = envValue("OPENCAN_TEST_NODE_HOST", in: env),
            let nodeUsername = envValue("OPENCAN_TEST_NODE_USERNAME", in: env),
            let workspacePath = envValue("OPENCAN_TEST_WORKSPACE_PATH", in: env),
            let nodeKeyPEMRaw = envValue("OPENCAN_TEST_SSH_PRIVATE_KEY_PEM", in: env)
        else {
            Log.toFile("[Seed] Integration seed skipped: required environment variables are missing")
            return
        }

        let nodeName = envValue("OPENCAN_TEST_NODE_NAME", in: env) ?? "integration-target"
        let workspaceName = envValue("OPENCAN_TEST_WORKSPACE_NAME", in: env) ?? "home"
        let nodePort = Int(envValue("OPENCAN_TEST_NODE_PORT", in: env) ?? "") ?? 22
        let nodeKeyPEM = nodeKeyPEMRaw.replacingOccurrences(of: "\\n", with: "\n")

        let context = ModelContext(modelContainer)
        var createdKeys: [SSHKeyPair] = []

        do {
            // Keep integration runs deterministic by resetting persisted connection data.
            let existingSessions = try context.fetch(FetchDescriptor<Session>())
            for session in existingSessions {
                context.delete(session)
            }

            let existingWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
            for workspace in existingWorkspaces {
                context.delete(workspace)
            }

            let existingNodes = try context.fetch(FetchDescriptor<Node>())
            for node in existingNodes {
                context.delete(node)
            }

            let existingKeys = try context.fetch(FetchDescriptor<SSHKeyPair>())
            for key in existingKeys {
                key.deletePrivateKeyFromKeychain()
                context.delete(key)
            }

            let nodeKey = try SSHKeyPair(name: "\(nodeName)-key", privateKeyPEM: Data(nodeKeyPEM.utf8))
            createdKeys.append(nodeKey)
            context.insert(nodeKey)

            let node = Node(name: nodeName, host: nodeHost, port: nodePort, username: nodeUsername)
            node.sshKey = nodeKey
            context.insert(node)

            if let jumpHost = envValue("OPENCAN_TEST_JUMP_HOST", in: env) {
                guard let jumpUsername = envValue("OPENCAN_TEST_JUMP_USERNAME", in: env) else {
                    Log.toFile("[Seed] Integration seed skipped: OPENCAN_TEST_JUMP_USERNAME is missing")
                    return
                }
                let jumpPort = Int(envValue("OPENCAN_TEST_JUMP_PORT", in: env) ?? "") ?? 22
                let jumpKeyPEMRaw = envValue("OPENCAN_TEST_JUMP_PRIVATE_KEY_PEM", in: env) ?? nodeKeyPEMRaw
                let jumpKeyPEM = jumpKeyPEMRaw.replacingOccurrences(of: "\\n", with: "\n")

                let jumpKey = try SSHKeyPair(name: "\(nodeName)-jump-key", privateKeyPEM: Data(jumpKeyPEM.utf8))
                createdKeys.append(jumpKey)
                context.insert(jumpKey)

                let jumpNode = Node(
                    name: envValue("OPENCAN_TEST_JUMP_NODE_NAME", in: env) ?? "jump",
                    host: jumpHost,
                    port: jumpPort,
                    username: jumpUsername
                )
                jumpNode.sshKey = jumpKey
                context.insert(jumpNode)
                node.jumpServer = jumpNode
            }

            let workspace = Workspace(name: workspaceName, path: workspacePath)
            workspace.node = node
            context.insert(workspace)

            try context.save()
        } catch {
            for key in createdKeys {
                key.deletePrivateKeyFromKeychain()
            }
            Log.toFile("[Seed] Integration seed failed: \(error)")
        }
    }

    private func migrateSSHKeysToKeychainIfNeeded() {
        let context = ModelContext(modelContainer)

        do {
            let keys = try context.fetch(FetchDescriptor<SSHKeyPair>())
            var migratedCount = 0
            for key in keys {
                if try key.migrateLegacyPrivateKeyIfNeeded() {
                    migratedCount += 1
                }
            }
            let validIdentifiers = SSHKeyPair.keychainIdentifiers(in: keys)
            let orphanedCount = try SSHKeyPair.cleanupOrphanedKeychainEntries(validIdentifiers: validIdentifiers)

            if migratedCount > 0 {
                try context.save()
            }
            if migratedCount > 0 || orphanedCount > 0 {
                Log.toFile(
                    "[Security] Migrated \(migratedCount) SSH key(s) to Keychain; removed \(orphanedCount) orphaned Keychain entr\(orphanedCount == 1 ? "y" : "ies")"
                )
            }
        } catch {
            Log.toFile("[Security] SSH key migration failed: \(error)")
        }
    }

    private func envValue(_ key: String, in env: [String: String]) -> String? {
        guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
