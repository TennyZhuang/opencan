import XCTest
@testable import OpenCAN

private actor TestACPTransport: ACPTransport {
    private let continuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let messages: AsyncStream<JSONRPCMessage>

    init() {
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.messages = stream
        self.continuation = cont
    }

    func send(_ message: JSONRPCMessage) async throws {
        // Intentionally no-op. Tests drive responses explicitly via `yield`.
    }

    func close() async {
        continuation.finish()
    }

    func yield(_ message: JSONRPCMessage) {
        continuation.yield(message)
    }
}

final class ACPClientTests: XCTestCase {
    func testSendRequestAcceptsNullResult() async throws {
        let transport = TestACPTransport()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.stop() } }

        let pending = Task {
            try await client.sendRequest(method: DaemonMethods.hello, params: .object([:]))
        }

        try await Task.sleep(for: .milliseconds(20))
        await transport.yield(.response(id: .int(1000), result: .null))

        let result = try await pending.value
        XCTAssertEqual(result, .null)
    }

    func testSendRequestCancellationDoesNotBlockNextRequest() async throws {
        let transport = TestACPTransport()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.stop() } }

        let first = Task {
            try await client.sendRequest(method: DaemonMethods.hello, params: .object([:]))
        }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let second = Task {
            try await client.sendRequest(method: DaemonMethods.sessionList, params: .object([:]))
        }
        try await Task.sleep(for: .milliseconds(20))
        await transport.yield(.response(id: .int(1001), result: .object(["ok": .bool(true)])))

        let secondResult = try await second.value
        XCTAssertEqual(secondResult["ok"], .bool(true))
    }

    func testNotificationsFinishWhenTransportEnds() async throws {
        let transport = TestACPTransport()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.stop() } }

        let finished = expectation(description: "notifications stream finished")
        Task {
            for await _ in client.notifications {
                // no-op
            }
            finished.fulfill()
        }

        try await Task.sleep(for: .milliseconds(20))
        await transport.close()

        await fulfillment(of: [finished], timeout: 1.0)
    }
}

