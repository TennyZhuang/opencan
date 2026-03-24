import XCTest
@testable import OpenCAN

final class ChatViewTests: XCTestCase {
    func testBackToBottomButtonStaysHiddenAtBottom() {
        XCTAssertFalse(shouldShowBackToBottomButton(distanceFromBottom: 0))
    }

    func testBackToBottomButtonStaysHiddenAtThreshold() {
        XCTAssertFalse(shouldShowBackToBottomButton(distanceFromBottom: 200))
    }

    func testBackToBottomButtonAppearsJustPastThreshold() {
        XCTAssertTrue(shouldShowBackToBottomButton(distanceFromBottom: 201))
    }

    func testBackToBottomButtonAppearsBeyondThreshold() {
        XCTAssertTrue(shouldShowBackToBottomButton(distanceFromBottom: 260))
    }
}
