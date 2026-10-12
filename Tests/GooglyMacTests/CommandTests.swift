import XCTest
@testable import GooglyMac
final class CommandTests: XCTestCase {
    func testFocusCommandsAndCompoundRequests() {
        XCTAssertEqual(BlueyCommand.parse("Focus on wave optics"), .startFocus("wave optics"))
        XCTAssertEqual(BlueyCommand.parse("Bluey, lock this window"), .lockTarget)
        XCTAssertEqual(BlueyCommand.parse("pause focus for ten minutes"), .pauseFocus(600))
        XCTAssertEqual(BlueyCommand.parse("resume focus"), .resumeFocus)
        XCTAssertEqual(BlueyCommand.parse("stop watching"), .stopFocus)
        XCTAssertEqual(BlueyCommand.parse("stop"), .cancelTask)
        XCTAssertEqual(BlueyCommand.parse("I'm back"), .dismissWarning)
        XCTAssertNil(BlueyCommand.parse("Explain what focus on wave optics means"))
        XCTAssertNil(BlueyCommand.parse("focus on wave optics and explain this formula"))
    }
    func testPauseBounds() {
        XCTAssertEqual(BlueyCommand.parse("pause focus for 5 minutes"), .pauseFocus(300))
        XCTAssertNil(BlueyCommand.parse("pause focus for 99999 minutes"))
    }
}
