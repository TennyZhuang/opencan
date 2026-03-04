import XCTest
@testable import OpenCAN

private final class NonCooperativeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

final class TimeoutHelperTests: XCTestCase {
    func testWithThrowingTimeoutReturnsOperationResult() async throws {
        let value = try await withThrowingTimeout(seconds: 1) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testWithThrowingTimeoutTimesOutWhenOperationIgnoresCancellation() async {
        let gate = NonCooperativeGate()
        defer { gate.release() }

        let start = Date()
        do {
            _ = try await withThrowingTimeout(seconds: 0.2) {
                await gate.wait()
                return 1
            }
            XCTFail("Expected timeout")
        } catch let error as AppStateError {
            guard case .timeout = error else {
                XCTFail("Expected AppStateError.timeout, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected AppStateError.timeout, got \(error)")
        }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed,
            1.0,
            "Timeout helper should return promptly without waiting for non-cooperative cancellation"
        )
    }

    func testWithThrowingTimeoutPropagatesCallerCancellation() async {
        let task = Task {
            try await withThrowingTimeout(seconds: 5) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
