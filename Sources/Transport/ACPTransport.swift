import Foundation

/// Protocol for bidirectional JSON-RPC transport.
protocol ACPTransport: Sendable {
    /// Send a JSON-RPC message.
    func send(_ message: JSONRPCMessage) async throws

    /// Stream of incoming messages.
    var messages: AsyncStream<JSONRPCMessage> { get }

    /// Close the transport.
    func close() async
}
