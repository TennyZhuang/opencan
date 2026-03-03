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

    struct RemoteFileUploadResult: Sendable {
        let remotePath: String
        let fileURI: String
        let sizeBytes: Int
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

        // Select the bundled daemon that matches the remote host platform.
        // Falls back to linux-amd64 only when remote detection is unavailable.
        let remoteTarget = try await detectRemoteDaemonTarget(client: client)
        let (bundleName, bundleURL) = try bundledDaemonBinary(remoteTarget: remoteTarget)
        Log.toFile("[SSH] Using bundled daemon \(bundleName)")
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

    /// Upload an image to a per-session temp directory on the remote server.
    /// Returns the absolute remote path and file:// URI for ACP resource links.
    func uploadChatImage(
        sessionId: String,
        data: Data,
        fileExtension: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RemoteFileUploadResult {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }

        let safeSessionID = sanitizePathComponent(sessionId)
        let safeExtension = sanitizeFileExtension(fileExtension)
        let uniqueName = "img-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).\(safeExtension)"

        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }

        let homePath = try await sftp.getRealPath(atPath: ".")
        let rootPath = homePath + "/.opencan/uploads"
        let sessionPath = rootPath + "/\(safeSessionID)"

        for path in [homePath + "/.opencan", rootPath, sessionPath] {
            do {
                try await sftp.createDirectory(atPath: path)
            } catch {
                // Directory may already exist — ignore
            }
        }

        let remotePath = sessionPath + "/\(uniqueName)"
        var attrs = SFTPFileAttributes()
        attrs.permissions = 0o600
        let file = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate],
            attributes: attrs
        )

        progress?(0)
        let chunkSize = 64 * 1024
        let totalSize = data.count
        var offset = 0
        while offset < totalSize {
            let end = min(offset + chunkSize, totalSize)
            let chunk = data[offset..<end]
            try await file.write(ByteBuffer(data: chunk), at: UInt64(offset))
            offset = end
            progress?(Double(offset) / Double(totalSize))
        }
        try await file.close()

        let escapedPath = shellEscape(remotePath)
        let _ = try? await client.executeCommand("chmod 600 \(escapedPath)")

        let uri = fileURIString(forRemotePath: remotePath)
        Log.toFile("[SSH] Uploaded chat image to \(remotePath)")
        return RemoteFileUploadResult(
            remotePath: remotePath,
            fileURI: uri,
            sizeBytes: data.count
        )
    }

    /// Best-effort cleanup of expired uploaded chat images under ~/.opencan/uploads.
    /// Files older than `ttlHours` are deleted, then empty directories are pruned.
    func cleanupExpiredChatUploads(ttlHours: Int) async throws {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }

        let safeTTLHours = max(ttlHours, 1)
        let ttlMinutes = safeTTLHours * 60
        let command = """
        if [ -d ~/.opencan/uploads ]; then \
          find ~/.opencan/uploads -type f -mmin +\(ttlMinutes) -delete 2>/dev/null; \
          find ~/.opencan/uploads -depth -type d -empty -delete 2>/dev/null; \
        fi
        """
        let _ = try await client.executeCommand(command)
        Log.toFile("[SSH] Cleaned expired chat uploads older than \(safeTTLHours)h")
    }

    /// Check whether a remote directory exists.
    /// Supports `~` and `~/...` paths.
    func remoteDirectoryExists(path: String) async throws -> Bool {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }
        let command = try tildeResolvedCommand(
            path: path,
            body: """
        if [ -d "$resolved_path" ]; then
          echo "__opencan_dir_exists__"
        else
          echo "__opencan_dir_missing__"
        fi
        """
        )
        let output = try await client.executeCommand(command)
        let outputString = String(buffer: output)
        if outputString.contains("__opencan_dir_exists__") {
            return true
        }
        if outputString.contains("__opencan_dir_missing__") {
            return false
        }
        throw SSHError.remoteCommandFailed("Failed to check remote directory '\(path)'")
    }

    /// Create a remote directory with `mkdir -p`.
    /// Supports `~` and `~/...` paths.
    func createRemoteDirectory(path: String) async throws {
        guard let client = targetClient else {
            throw SSHError.notConnected
        }
        let command = try tildeResolvedCommand(
            path: path,
            body: """
        if mkdir -p "$resolved_path"; then
          echo "__opencan_mkdir_ok__"
        else
          echo "__opencan_mkdir_fail__"
        fi
        """
        )
        let output = try await client.executeCommand(command)
        let outputString = String(buffer: output)
        guard outputString.contains("__opencan_mkdir_ok__") else {
            throw SSHError.remoteCommandFailed("Failed to create remote directory '\(path)'")
        }
    }

    /// Shell-escape a string by wrapping in single quotes and escaping embedded single quotes.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Validate and trim a user-provided remote path.
    private func normalizeRemotePath(_ path: String) throws -> String {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw SSHError.invalidRemotePath
        }
        return normalizedPath
    }

    /// Wrap command bodies with shared `~`/`~/...` expansion logic.
    private func tildeResolvedCommand(path: String, body: String) throws -> String {
        let escapedPath = shellEscape(try normalizeRemotePath(path))
        return """
        raw_path=\(escapedPath)
        case "$raw_path" in
          "~") resolved_path="$HOME" ;;
          "~/"*) resolved_path="$HOME/${raw_path#~/}" ;;
          *) resolved_path="$raw_path" ;;
        esac
        \(body)
        """
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let filtered = String(value.filter { allowed.contains($0) })
        return filtered.isEmpty ? "session" : filtered
    }

    private func sanitizeFileExtension(_ ext: String) -> String {
        let normalized = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let filtered = String(normalized.filter { allowed.contains($0) })
        return filtered.isEmpty ? "jpg" : filtered
    }

    private func fileURIString(forRemotePath remotePath: String) -> String {
        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        return "file://\(encodedPath)"
    }

    private func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func bundledDaemonBinary(remoteTarget: String?) throws -> (name: String, url: URL) {
        if let remoteTarget {
            let preferredName = "opencan-daemon-\(remoteTarget)"
            if let preferredURL = Bundle.main.url(forResource: preferredName, withExtension: nil) {
                return (preferredName, preferredURL)
            }
            if remoteTarget != "linux-amd64" {
                Log.toFile("[SSH] Missing bundled daemon for remote target \(remoteTarget)")
                throw SSHError.daemonBinaryNotFound
            }
        }

        let fallbackName = "opencan-daemon-linux-amd64"
        guard let fallbackURL = Bundle.main.url(forResource: fallbackName, withExtension: nil) else {
            throw SSHError.daemonBinaryNotFound
        }
        return (fallbackName, fallbackURL)
    }

    private func detectRemoteDaemonTarget(client: SSHClient) async throws -> String? {
        do {
            let output = try await client.executeCommand("uname -s 2>/dev/null; uname -m 2>/dev/null")
            let lines = String(buffer: output)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else {
                return nil
            }

            guard let os = normalizeRemoteOS(lines[0]), let arch = normalizeRemoteArch(lines[1]) else {
                Log.toFile("[SSH] Unsupported remote platform: os='\(lines[0])' arch='\(lines[1])'")
                return nil
            }
            return "\(os)-\(arch)"
        } catch {
            Log.toFile("[SSH] Failed to detect remote platform, defaulting to linux-amd64: \(error.localizedDescription)")
            return nil
        }
    }

    private func normalizeRemoteOS(_ raw: String) -> String? {
        let value = raw.lowercased()
        if value.contains("linux") {
            return "linux"
        }
        if value.contains("darwin") {
            return "darwin"
        }
        return nil
    }

    private func normalizeRemoteArch(_ raw: String) -> String? {
        let value = raw.lowercased()
        switch value {
        case "x86_64", "amd64":
            return "amd64"
        case "arm64", "aarch64", "arm64e":
            return "arm64"
        default:
            return nil
        }
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
    case invalidRemotePath
    case remoteCommandFailed(String)
    case daemonBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH client not connected"
        case .keyNotFound(let name): "SSH key '\(name)' not found"
        case .invalidKeyData: "Invalid SSH key data"
        case .invalidRemotePath: "Remote path is empty"
        case .remoteCommandFailed(let message): message
        case .daemonBinaryNotFound: "opencan-daemon binary not found in app bundle"
        }
    }
}
