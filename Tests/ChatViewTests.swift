import XCTest
@testable import OpenCAN

final class ChatViewTests: XCTestCase {
    func testBackToBottomButtonStaysHiddenAtThreshold() {
        XCTAssertFalse(shouldShowBackToBottomButton(distanceFromBottom: 200))
    }

    func testBackToBottomButtonAppearsBeyondThreshold() {
        XCTAssertTrue(shouldShowBackToBottomButton(distanceFromBottom: 260))
    }
}
