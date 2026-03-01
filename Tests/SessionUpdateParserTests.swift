import XCTest
@testable import OpenCAN

final class SessionUpdateParserTests: XCTestCase {
    func testParsesUserMessageWithStringContent() {
        let notification: JSONRPCMessage = .notification(
            method: ACPMethods.sessionUpdate,
            params: .object([
                "sessionId": .string("sess-1"),
                "update": .object([
                    "sessionUpdate": .string("user_message"),
                    "content": .string("You are a teammate agent."),
                ]),
            ])
        )

        guard let event = SessionUpdateParser.parse(notification) else {
            XCTFail("Expected user message event")
            return
        }

        guard case .userMessage(let text) = event else {
            XCTFail("Expected userMessage, got \(event)")
            return
        }
        XCTAssertEqual(text, "You are a teammate agent.")
    }

    func testParsesMessageChunkWithArrayContent() {
        let notification: JSONRPCMessage = .notification(
            method: ACPMethods.sessionUpdate,
            params: .object([
                "sessionId": .string("sess-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Hello "),
                        ]),
                        .object([
                            "type": .string("text"),
                            "text": .string("world"),
                        ]),
                    ]),
                ]),
            ])
        )

        guard let event = SessionUpdateParser.parse(notification) else {
            XCTFail("Expected assistant delta event")
            return
        }

        guard case .agentMessageDelta(let text) = event else {
            XCTFail("Expected agentMessageDelta, got \(event)")
            return
        }
        XCTAssertEqual(text, "Hello world")
    }
}
