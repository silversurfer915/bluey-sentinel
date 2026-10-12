import XCTest
@testable import GooglyMac
final class PresentationTests: XCTestCase {
    func testActivityPriorityPreventsMusicInterruptions() {
        XCTAssertEqual(NotchPresentation.choose(warning: true, busy: true, listening: true), .warning)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: true, listening: true), .task)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: true), .listening)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: false), .passive)
    }
}
