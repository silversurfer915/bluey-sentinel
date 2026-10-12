import XCTest
@testable import GooglyMac
final class SentinelTests: XCTestCase {
    func testObservedTargetMustStillMatchBeforeEnforcement() {
        let original = FocusProbe(app: "Safari", bundleID: "com.apple.Safari", windowTitle: "Cats", url: "https://youtube.com/watch?v=cats", idleSeconds: 0, at: Date())
        var moved = original; moved.url = "https://youtube.com/watch?v=lecture"
        XCTAssertFalse(Sentinel.sameTarget(original, moved))
        moved = original; moved.app = "Google Chrome"
        XCTAssertFalse(Sentinel.sameTarget(original, moved))
        XCTAssertTrue(Sentinel.sameTarget(original, original))
    }
    @MainActor func testNamedAppCannotQuitUnrelatedApp() {
        let s = Settings.shared; let old = s.sentinelAct; s.sentinelAct = true; defer { s.sentinelAct = old }
        let probe = FocusProbe(app: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "Unsaved", url: nil, idleSeconds: 0, at: Date())
        let v = SentinelVerdict(onTask: false, confidence: 0.95, reason: "drift", nudge: "back", block: "Finder", point: nil)
        XCTAssertEqual(Sentinel().exposedPlan(for: v, probe: probe).kind, .none)
    }
    func testUncertaintyIsNotProductiveEvidence() {
        XCTAssertFalse(SentinelVerdict.uncertain.isReliableOnTask)
        XCTAssertFalse(SentinelVerdict.unavailable.isReliableOnTask)
    }
    func testElapsedTimeUsesActualTimeNotTickCount() {
        XCTAssertEqual(Sentinel.focusElapsed(previous: Date(timeIntervalSince1970: 10), now: Date(timeIntervalSince1970: 15), limit: 6), 5)
        XCTAssertEqual(Sentinel.focusElapsed(previous: Date(timeIntervalSince1970: 10), now: Date(timeIntervalSince1970: 100), limit: 6), 6)
    }
}
