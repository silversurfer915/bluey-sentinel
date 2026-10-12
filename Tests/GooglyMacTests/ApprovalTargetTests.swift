import XCTest
@testable import GooglyMac
final class ApprovalTargetTests: XCTestCase {
    func testWordApprovalSurvivesChangedIDs() {
        let rect = CGRect(x: 10, y: 10, width: 50, height: 20)
        let old = Target(id: "W1", text: "Send", rect: rect)
        let fresh = Target(id: "W9", text: "Send", rect: rect)
        let shot = ScreenSnapshot(jpeg: Data(), lines: [(Target(id: "L1", text: "Send message", rect: rect), [fresh])], size: CGSize(width: 100, height: 100))
        XCTAssertEqual(shot.matchingApprovedTarget(old)?.id, "W9")
    }
    func testMovedOrRelabeledControlCannotReuseApproval() {
        let old = Target(id: "W1", text: "Send", rect: CGRect(x: 10, y: 10, width: 50, height: 20))
        let moved = Target(id: "W9", text: "Send", rect: CGRect(x: 100, y: 10, width: 50, height: 20))
        let renamed = Target(id: "W8", text: "Delete", rect: old.rect)
        let shot = ScreenSnapshot(jpeg: Data(), lines: [(moved, [moved, renamed])], size: CGSize(width: 200, height: 100))
        XCTAssertNil(shot.matchingApprovedTarget(old))
    }
}
