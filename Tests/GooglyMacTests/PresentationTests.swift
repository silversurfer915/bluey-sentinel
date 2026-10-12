import XCTest
@testable import GooglyMac
final class PresentationTests: XCTestCase {
    func testActivityPriorityPreventsMusicInterruptions() {
        XCTAssertEqual(NotchPresentation.choose(warning: true, busy: true, listening: true), .warning)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: true, listening: true), .task)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: true), .listening)
        XCTAssertEqual(NotchPresentation.choose(warning: false, busy: false, listening: false), .passive)
    }

    @MainActor
    func testWorkspaceReopenPreservesActivePage() {
        BlueyWorkspace.shared.show(page: "Token Caching")
        XCTAssertEqual(BlueyState.shared.workspacePage, "Token Caching")

        // Reopening / clicking dock icon calls show() without page argument
        BlueyWorkspace.shared.show()
        XCTAssertEqual(BlueyState.shared.workspacePage, "Token Caching", "Reopening workspace must preserve currently selected tab")

        // Explicit Settings call switches to Settings
        BlueyWorkspace.shared.show(settings: true)
        XCTAssertEqual(BlueyState.shared.workspacePage, "Settings")
    }
}
