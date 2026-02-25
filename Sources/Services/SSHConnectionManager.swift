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

    struct ConnectionParams {
        let host: String
        let port: Int
        let username: String
        let privateKeyPEM: Data
        let command: String
        // Optional jump host
        let jumpHost: String?
        let jumpPort: Int?
        let jumpUsername: String?
        let jumpKeyPEM: Data?  // nil = use same key as target
    }

    func connect(params: ConnectionParams) async throws -> SSHStdioTransport {
        state = .connecting
        Log.ssh.warning("Host key verification is disabled — connections are vulnerable to MITM")

        do {
            let privateKey = try loadPrivateKey(pem: params.privateKeyPEM)

            if let jumpHost = params.jumpHost {
                let jumpUser = params.jumpUsername ?? params.username
                let jumpKey = if let jumpPEM = params.jumpKeyPEM {
                    try loadPrivateKey(pem: jumpPEM)
                } else {
                    privateKey
                }

                var jumpSettings = SSHClientSettings(
                    host: jumpHost,
                    port: params.jumpPort ?? 22,
                    authenticationMethod: { .rsa(username: jumpUser, privateKey: jumpKey) },
                    hostKeyValidator: .acceptAnything()
                )
                jumpSettings.algorithms = .all

                Log.ssh.info("Connecting to jump host \(jumpHost)...")
                Log.toFile("[SSH] Connecting to jump host \(jumpHost)...")
                let jump = try await SSHClient.connect(to: jumpSettings)
                self.jumpClient = jump
                Log.ssh.info("Connected to jump host")
                Log.toFile("[SSH] Connected to jump host")

                let targetUser = params.username
                var targetSettings = SSHClientSettings(
                    host: params.host,
                    port: params.port,
                    authenticationMethod: { .rsa(username: targetUser, privateKey: privateKey) },
                    hostKeyValidator: .acceptAnything()
                )
                targetSettings.algorithms = .all

                Log.ssh.info("Jumping to target \(params.host)...")
                Log.toFile("[SSH] Jumping to target \(params.host)...")
                let target = try await jump.jump(to: targetSettings)
                self.targetClient = target
                Log.ssh.info("Connected to target")
                Log.toFile("[SSH] Connected to target")
            } else {
                let user = params.username
                var settings = SSHClientSettings(
                    host: params.host,
                    port: params.port,
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

    private func loadPrivateKey(pem data: Data) throws -> Insecure.RSA.PrivateKey {
        guard let keyString = String(data: data, encoding: .utf8) else {
            throw SSHError.invalidKeyData
        }
        return try Insecure.RSA.PrivateKey(sshRsa: keyString)
    }
}

enum SSHError: Error, LocalizedError {
    case notConnected
    case keyNotFound(String)
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH client not connected"
        case .keyNotFound(let name): "SSH key '\(name)' not found"
        case .invalidKeyData: "Invalid SSH key data"
        }
    }
}
