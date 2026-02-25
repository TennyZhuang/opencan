import Foundation
import Citadel
import Crypto
import NIOSSH
import os

/// Manages SSH connection lifecycle: connect through jump host, create transport.
actor SSHConnectionManager {
    private var jumpClient: SSHClient?
    private var targetClient: SSHClient?
    private var transport: SSHStdioTransport?

    enum State {
        case disconnected
        case connecting
        case connected
        case failed(Error)
    }

    private(set) var state: State = .disconnected

    func connect(config: ServerConfig) async throws -> SSHStdioTransport {
        state = .connecting
        Log.ssh.warning("Host key verification is disabled — connections are vulnerable to MITM")

        do {
            let privateKey = try loadPrivateKey(named: config.privateKeyName)

            // Connect to jump host if configured
            if let jumpHost = config.jumpHost {
                let jumpUser = config.jumpUsername ?? config.username
                var jumpSettings = SSHClientSettings(
                    host: jumpHost,
                    port: Int(config.jumpPort ?? 22),
                    authenticationMethod: { .rsa(username: jumpUser, privateKey: privateKey) },
                    hostKeyValidator: .acceptAnything()
                )
                jumpSettings.algorithms = .all

                Log.ssh.info("Connecting to jump host \(jumpHost)...")
                Log.toFile("[SSH] Connecting to jump host \(jumpHost)...")
                let jump = try await SSHClient.connect(to: jumpSettings)
                self.jumpClient = jump
                Log.ssh.info("Connected to jump host")
                Log.toFile("[SSH] Connected to jump host")

                let targetUser = config.username
                var targetSettings = SSHClientSettings(
                    host: config.host,
                    port: Int(config.port),
                    authenticationMethod: { .rsa(username: targetUser, privateKey: privateKey) },
                    hostKeyValidator: .acceptAnything()
                )
                targetSettings.algorithms = .all

                Log.ssh.info("Jumping to target \(config.host)...")
                Log.toFile("[SSH] Jumping to target \(config.host)...")
                let target = try await jump.jump(to: targetSettings)
                self.targetClient = target
                Log.ssh.info("Connected to target")
                Log.toFile("[SSH] Connected to target")
            } else {
                let user = config.username
                var settings = SSHClientSettings(
                    host: config.host,
                    port: Int(config.port),
                    authenticationMethod: { .rsa(username: user, privateKey: privateKey) },
                    hostKeyValidator: .acceptAnything()
                )
                settings.algorithms = .all
                let target = try await SSHClient.connect(to: settings)
                self.targetClient = target
            }

            let t = SSHStdioTransport()
            self.transport = t
            state = .connected
            return t
        } catch {
            state = .failed(error)
            throw error
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    func startPTY(transport: SSHStdioTransport, command: String) async throws {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }
        try await transport.run(on: client, command: command)
    }

    func disconnect() async {
        try? await targetClient?.close()
        try? await jumpClient?.close()
        targetClient = nil
        jumpClient = nil
        transport = nil
        state = .disconnected
    }

    private func loadPrivateKey(named name: String) throws -> Insecure.RSA.PrivateKey {
        if let url = Bundle.main.url(forResource: name, withExtension: nil)
            ?? Bundle.main.url(forResource: name, withExtension: "pem") {
            let keyString = try String(contentsOf: url, encoding: .utf8)
            return try Insecure.RSA.PrivateKey(sshRsa: keyString)
        }
        // On macOS, fall back to ~/.ssh/
        #if os(macOS)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let keyPath = homeDir.appendingPathComponent(".ssh/\(name)")
        let keyString = try String(contentsOf: keyPath, encoding: .utf8)
        return try Insecure.RSA.PrivateKey(sshRsa: keyString)
        #else
        throw SSHError.keyNotFound(name)
        #endif
    }
}

enum SSHError: Error, LocalizedError {
    case notConnected
    case keyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH client not connected"
        case .keyNotFound(let name): "SSH key '\(name)' not found"
        }
    }
}