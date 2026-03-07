import Foundation
import Citadel
import NIO
import NIOSSH
import os

/// ACP transport over SSH PTY using Citadel.
/// Uses withPTY for bidirectional stdin/stdout access.
actor SSHStdioTransport: ACPTransport {
    private let framer = JSONRPCFramer()
    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let messages: AsyncStream<JSONRPCMessage>
    private var stdinWriter: ((String) async throws -> Void)?
    private var isClosed = false
    private var readyStream: AsyncStream<Void>?
    private var readySignal: AsyncStream<Void>.Continuation?
    private var jsonReadyStream: AsyncStream<Void>?
    private var jsonReadySignal: AsyncStream<Void>.Continuation?

    init() {
        let (msgStream, msgCont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.messages = msgStream
        self.messageContinuation = msgCont
        let (rStream, rCont) = AsyncStream<Void>.makeStream()
        self.readyStream = rStream
        self.readySignal = rCont
        let (jStream, jCont) = AsyncStream<Void>.makeStream()
        self.jsonReadyStream = jStream
        self.jsonReadySignal = jCont
    }

    /// Wait until the PTY is connected and ready to send.
    func waitUntilReady() async {
        if stdinWriter != nil { return }
        guard let stream = readyStream else { return }
        // Consume the first (and only) element — blocks until signalled
        for await _ in stream { break }
        readyStream = nil
    }

    /// Wait until the first JSON-RPC message has been received from the PTY.
    /// Used to ensure the daemon attach bridge is operational before sending requests.
    func waitForFirstJSON() async {
        guard let stream = jsonReadyStream else { return }
        for await _ in stream { break }
        jsonReadyStream = nil
    }

    func send(_ message: JSONRPCMessage) async throws {
        guard !isClosed, let writer = stdinWriter else {
            throw TransportError.notConnected
        }
        let data = try message.serialized()
        guard let line = String(data: data, encoding: .utf8) else {
            throw TransportError.encodingFailed
        }
        try await writer(line + "\n")
    }

    func close() {
        isClosed = true
        messageContinuation.finish()
        // Unblock any waitUntilReady() callers
        readySignal?.finish()
        readySignal = nil
        readyStream = nil
        // Unblock any waitForFirstJSON() callers
        jsonReadySignal?.finish()
        jsonReadySignal = nil
        jsonReadyStream = nil
    }

    // MARK: - Internal helpers called from the withPTY closure

    private func setWriter(_ writer: @escaping (String) async throws -> Void) {
        self.stdinWriter = writer
        readySignal?.yield()
        readySignal?.finish()
        readySignal = nil
    }

    private func feedData(_ data: Data) async {
        if let raw = String(data: data, encoding: .utf8),
           let snippet = Self.stdoutLogSnippet(from: raw) {
            Log.toFile("[stdout] \(snippet)")
        }
        let parsed = await framer.feed(data)
        for msg in parsed {
            Log.toFile("[Transport] Parsed JSON-RPC message")
            messageContinuation.yield(msg)
            // Signal that the first JSON message has arrived (daemon bridge is ready)
            jsonReadySignal?.yield()
            jsonReadySignal?.finish()
            jsonReadySignal = nil
        }
    }

    private static func stdoutLogSnippet(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("{") else { return nil }
        return truncatedLogSnippet(trimmed)
    }

    private static func stderrLogSnippet(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return truncatedLogSnippet(trimmed)
    }

    private static func truncatedLogSnippet(_ raw: String, limit: Int = 160) -> String {
        guard raw.count > limit else { return raw }
        let end = raw.index(raw.startIndex, offsetBy: limit)
        return String(raw[..<end]) + "...(truncated)"
    }

    /// Run the PTY session. Blocks until the PTY closes.
    @available(macOS 15.0, iOS 18.0, *)
    func run(on client: SSHClient, command: String) async throws {
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "dumb",
            terminalCharacterWidth: 200,
            terminalRowHeight: 50,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([
                .ECHO: 0,
                .ECHOE: 0,
                .ECHOK: 0,
                .ECHONL: 0,
                .ICANON: 0,
            ])
        )

        try await client.withPTY(ptyRequest) { [self] inbound, outbound in
            await self.setWriter { [outbound] text in
                var buf = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                buf.writeString(text)
                try await outbound.write(buf)
            }

            // Send the command that launches the remote ACP bridge/agent.
            var cmdBuf = ByteBufferAllocator().buffer(capacity: command.utf8.count + 1)
            cmdBuf.writeString(command + "\n")
            try await outbound.write(cmdBuf)

            // Read PTY output and parse JSON-RPC messages.
            // Ensure the message stream is finished even if the loop throws.
            defer { self.messageContinuation.finish() }
            for try await event in inbound {
                switch event {
                case .stdout(let buffer):
                    let data = Data(buffer: buffer)
                    await self.feedData(data)
                case .stderr(let buffer):
                    if let snippet = Self.stderrLogSnippet(from: String(buffer: buffer)) {
                        Log.toFile("[stderr] \(snippet)")
                    }
                }
            }
        }
    }
}

enum TransportError: Error, LocalizedError {
    case notConnected
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: "Transport not connected"
        case .encodingFailed: "Failed to encode message"
        }
    }
}
