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

    func testParsesToolCallUpdateWithStructuredRawOutput() {
        let notification: JSONRPCMessage = .notification(
            method: ACPMethods.sessionUpdate,
            params: .object([
                "sessionId": .string("sess-1"),
                "update": .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("tool-1"),
                    "status": .string("completed"),
                    "rawOutput": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("first line\n"),
                        ]),
                        .object([
                            "type": .string("text"),
                            "text": .string("second line"),
                        ]),
                    ]),
                ]),
            ])
        )

        guard let event = SessionUpdateParser.parse(notification) else {
            XCTFail("Expected tool completion event")
            return
        }

        guard case .toolCallComplete(let id, _, _, let output, let failed) = event else {
            XCTFail("Expected toolCallComplete, got \(event)")
            return
        }
        XCTAssertEqual(id, "tool-1")
        XCTAssertEqual(output, "first line\nsecond line")
        XCTAssertFalse(failed)
    }

    func testParsesToolCallUpdateWithPlainStringRawOutput() {
        let notification: JSONRPCMessage = .notification(
            method: ACPMethods.sessionUpdate,
            params: .object([
                "sessionId": .string("sess-1"),
                "update": .object([
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string("tool-2"),
                    "status": .string("completed"),
                    "rawOutput": .string("plain text output"),
                ]),
            ])
        )

        guard let event = SessionUpdateParser.parse(notification) else {
            XCTFail("Expected tool completion event")
            return
        }

        guard case .toolCallComplete(let id, _, _, let output, let failed) = event else {
            XCTFail("Expected toolCallComplete, got \(event)")
            return
        }
        XCTAssertEqual(id, "tool-2")
        XCTAssertEqual(output, "plain text output")
        XCTAssertFalse(failed)
    }

    func testIgnoresCurrentModeUpdate() {
        let notification: JSONRPCMessage = .notification(
            method: ACPMethods.sessionUpdate,
            params: .object([
                "sessionId": .string("sess-1"),
                "update": .object([
                    "sessionUpdate": .string("current_mode_update"),
                    "currentModeId": .string("plan"),
                ]),
            ])
        )

        XCTAssertNil(SessionUpdateParser.parse(notification))
    }
}
