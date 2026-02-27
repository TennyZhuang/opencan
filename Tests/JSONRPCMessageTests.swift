import XCTest
@testable import OpenCAN

final class JSONRPCMessageTests: XCTestCase {
    func testDeserializeResponseWithNullResult() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":null}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let message = try JSONRPCMessage.deserialize(from: data)

        switch message {
        case .response(let id, let result):
            XCTAssertEqual(id, .int(1))
            XCTAssertEqual(result, .null)
        default:
            XCTFail("Expected response message, got \(message)")
        }
    }
}

