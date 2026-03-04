import XCTest
@testable import OpenCAN

private actor TestACPTransport: ACPTransport {
    private let continuation: AsyncStream<JSONRPCMessage>.Continuation
    nonisolated let messages: AsyncStream<JSONRPCMessage>
    private var sentMessages: [JSONRPCMessage] = []

    init() {
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        self.messages = stream
        self.continuation = cont
    }

    func send(_ message: JSONRPCMessage) async throws {
        sentMessages.append(message)
        // Intentionally no-op. Tests drive responses explicitly via `yield`.
    }

    func close() async {
        continuation.finish()
    }

    func yield(_ message: JSONRPCMessage) {
        continuation.yield(message)
    }

    func lastSentMessage() -> JSONRPCMessage? {
        sentMessages.last
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

    func testSendRequestInjectsTraceId() async throws {
        let transport = TestACPTransport()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.stop() } }

        let pending = Task {
            try await client.sendRequest(
                method: DaemonMethods.sessionAttach,
                params: .object([
                    "sessionId": .string("sess-1")
                ]),
                traceId: "trace-abc"
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        guard let last = await transport.lastSentMessage() else {
            XCTFail("Expected a sent request")
            return
        }

        guard case .request(let id, _, let params) = last else {
            XCTFail("Expected request message")
            return
        }

        XCTAssertEqual(params?["_meta"]?["traceId"], .string("trace-abc"))

        await transport.yield(.response(id: id, result: .object([:])))
        _ = try await pending.value
    }

    func testSendRequestWithArrayParamsKeepsParamsWhenInjectingTraceId() async throws {
        let transport = TestACPTransport()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.stop() } }

        let arrayParams: JSONValue = .array([.string("a"), .string("b")])
        let pending = Task {
            try await client.sendRequest(
                method: "test/method",
                params: arrayParams,
                traceId: "trace-array"
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        guard let last = await transport.lastSentMessage() else {
            XCTFail("Expected a sent request")
            return
        }

        guard case .request(let id, _, let params) = last else {
            XCTFail("Expected request message")
            return
        }

        XCTAssertEqual(params, arrayParams)

        await transport.yield(.response(id: id, result: .object([:])))
        _ = try await pending.value
    }

    func testACPErrorSessionAndResourceNotFoundClassificationUsesWordBoundaries() {
        let sessionNotFound = ACPError.rpcError(
            code: -32603,
            message: "Internal error",
            data: .object(["details": .string("Session not found")])
        )
        XCTAssertTrue(sessionNotFound.isSessionNotFound)

        let resourceNotFound = ACPError.rpcError(
            code: -32002,
            message: "Resource not found",
            data: nil
        )
        XCTAssertTrue(resourceNotFound.isResourceNotFound)
        XCTAssertTrue(resourceNotFound.isSessionLoadResourceNotFound)

        let falsePositive = ACPError.rpcError(
            code: -32002,
            message: "Internal error",
            data: .object(["details": .string("resource not foundry artifact")])
        )
        XCTAssertFalse(falsePositive.isResourceNotFound)
    }

    func testACPErrorSessionLoadResourceNotFoundIsCodeScoped() {
        let nonLoadResourceError = ACPError.rpcError(
            code: -32000,
            message: "Resource not found",
            data: nil
        )
        XCTAssertTrue(nonLoadResourceError.isResourceNotFound)
        XCTAssertFalse(nonLoadResourceError.isSessionLoadResourceNotFound)
    }
}
