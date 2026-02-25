import Foundation
import Citadel
import NIO
import NIOSSH
import os

/// ACP transport over SSH PTY using Citadel.
/// Uses withPTY for bidirectional stdin/stdout access.
final class SSHStdioTransport: ACPTransport, @unchecked Sendable {
    private let framer = JSONRPCFramer()
    private let continuation: AsyncStream<JSONRPCMessage>.Continuation
    let messages: AsyncStream<JSONRPCMessage>
    private var stdinWriter: ((String) async throws -> Void)?
    private var isClosed = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init() {
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.messages = stream
        self.continuation = cont
    }

    /// Wait until the PTY is connected and ready to send.
    func waitUntilReady() async {
        if stdinWriter != nil { return }
        await withCheckedContinuation { cont in
            self.readyContinuation = cont
        }
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

    func close() async {
        isClosed = true
        continuation.finish()
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

        try await client.withPTY(ptyRequest) { inbound, outbound in
            self.stdinWriter = { [outbound] text in
                var buf = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                buf.writeString(text)
                try await outbound.write(buf)
            }

            // Signal that the transport is ready
            self.readyContinuation?.resume()
            self.readyContinuation = nil

            // Send the command to launch claude-agent-acp
            var cmdBuf = ByteBufferAllocator().buffer(capacity: command.utf8.count + 1)
            cmdBuf.writeString(command + "\n")
            try await outbound.write(cmdBuf)

            // Read PTY output and parse JSON-RPC messages
            for try await event in inbound {
                switch event {
                case .stdout(let buffer):
                    let data = Data(buffer: buffer)
                    if let raw = String(data: data, encoding: .utf8) {
                        Log.toFile("[stdout] \(raw.prefix(500))")
                    }
                    let parsed = await self.framer.feed(data)
                    for msg in parsed {
                        Log.toFile("[Transport] Parsed JSON-RPC message")
                        self.continuation.yield(msg)
                    }
                case .stderr(let buffer):
                    let text = String(buffer: buffer)
                    Log.toFile("[stderr] \(text)")
                }
            }

            self.continuation.finish()
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
