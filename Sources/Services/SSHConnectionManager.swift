import Foundation
import Citadel
import CommonCrypto
import Crypto
import NIOCore
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

    /// Check if opencan-daemon on the remote server is up-to-date.
    /// Compares SHA-256 of the bundled binary against a hash file on the server.
    /// Uploads via SFTP if missing or outdated.
    /// The progress callback reports upload fraction (0.0 to 1.0).
    func ensureDaemonInstalled(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }

        // Load the binary from the app bundle
        guard let bundleURL = Bundle.main.url(
            forResource: "opencan-daemon-linux-amd64",
            withExtension: nil
        ) else {
            throw SSHError.daemonBinaryNotFound
        }
        let binaryData = try Data(contentsOf: bundleURL)
        let localHash = sha256Hex(binaryData)

        // Read the remote hash file (empty string if missing)
        let remoteHash = try await client.executeCommand(
            "cat ~/.opencan/bin/opencan-daemon.sha256 2>/dev/null || echo ''"
        )
        let remoteHashStr = String(buffer: remoteHash).trimmingCharacters(in: .whitespacesAndNewlines)

        if remoteHashStr == localHash {
            Log.toFile("[SSH] Daemon up-to-date (\(localHash.prefix(12))...)")
            return
        }

        if remoteHashStr.isEmpty {
            Log.toFile("[SSH] Daemon not found, uploading via SFTP...")
        } else {
            Log.toFile("[SSH] Daemon outdated (remote \(remoteHashStr.prefix(12))... != local \(localHash.prefix(12))...), re-uploading...")
        }
        progress?(0)

        // Create directory and upload
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }

        // mkdir -p ~/.opencan/bin
        let homePath = try await sftp.getRealPath(atPath: ".")
        for suffix in ["/.opencan", "/.opencan/bin"] {
            do {
                try await sftp.createDirectory(atPath: homePath + suffix)
            } catch {
                // Directory may already exist — ignore
            }
        }

        let remoteFullPath = homePath + "/.opencan/bin/opencan-daemon"
        let remoteHashPath = homePath + "/.opencan/bin/opencan-daemon.sha256"

        // Kill any running daemon before overwriting the binary.
        // On Linux you can't truncate a binary that's being executed.
        // Shell-escape paths to prevent injection via malicious SFTP home paths.
        let escapedPath = shellEscape(remoteFullPath)
        let escapedHashPath = shellEscape(remoteHashPath)
        let _ = try? await client.executeCommand(
            "kill $(cat ~/.opencan/daemon.pid 2>/dev/null) 2>/dev/null; rm -f \(escapedPath) \(escapedHashPath)"
        )

        // Upload the binary in chunks for progress reporting
        var attrs = SFTPFileAttributes()
        attrs.permissions = 0o755
        let file = try await sftp.openFile(
            filePath: remoteFullPath,
            flags: [.write, .create, .truncate],
            attributes: attrs
        )

        let chunkSize = 32 * 1024  // 32KB per SFTP write
        let totalSize = binaryData.count
        var offset = 0
        while offset < totalSize {
            let end = min(offset + chunkSize, totalSize)
            let chunk = binaryData[offset..<end]
            let buffer = ByteBuffer(data: chunk)
            try await file.write(buffer, at: UInt64(offset))
            offset = end
            progress?(Double(offset) / Double(totalSize))
        }

        try await file.close()

        // Write the hash file so next connect can skip the upload
        let hashFile = try await sftp.openFile(
            filePath: remoteHashPath,
            flags: [.write, .create, .truncate]
        )
        try await hashFile.write(ByteBuffer(string: localHash), at: 0)
        try await hashFile.close()

        // Belt-and-suspenders chmod
        let _ = try await client.executeCommand("chmod +x \(escapedPath)")

        Log.toFile("[SSH] Daemon uploaded successfully (\(binaryData.count) bytes, \(localHash.prefix(12))...)")
    }

    /// Shell-escape a string by wrapping in single quotes and escaping embedded single quotes.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
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
    case daemonBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH client not connected"
        case .keyNotFound(let name): "SSH key '\(name)' not found"
        case .invalidKeyData: "Invalid SSH key data"
        case .daemonBinaryNotFound: "opencan-daemon binary not found in app bundle"
        }
    }
}
