import XCTest
@testable import GooglyMac

final class DockPresentationTests: XCTestCase {
    func testPlannedProgressDoesNotResetAtMinuteBoundary() {
        XCTAssertEqual(DockProgressPresentation.angle(elapsed: 60, planned: 120, countUp: false), 180)
        XCTAssertEqual(DockProgressPresentation.angle(elapsed: 120, planned: 120, countUp: false), 360)
        XCTAssertEqual(DockProgressPresentation.angle(elapsed: 180, planned: 120, countUp: false), 360)
    }
    func testCountUpActivityDoesNotInventCompletionPercent() {
        XCTAssertEqual(DockProgressPresentation.angle(elapsed: 60, planned: 120, countUp: true),
                       DockProgressPresentation.angle(elapsed: 600, planned: 120, countUp: true))
    }
    func testAbandonmentDoesNotCelebrateCompletion() {
        XCTAssertFalse(DockProgressPresentation.celebrates(wasActive: true, isActive: false, termination: "abandon"))
        XCTAssertTrue(DockProgressPresentation.celebrates(wasActive: true, isActive: false, termination: "finish"))
        XCTAssertFalse(DockProgressPresentation.celebrates(wasActive: false, isActive: false, termination: "finish"))
    }
}
