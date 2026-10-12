import XCTest
@testable import GooglyMac

final class ExecutionAccessTests: XCTestCase {
    func testFullAccessDoesNotPromptForRequestedActions() {
        XCTAssertFalse(AutonomyMode.fullAccess.requiresConfirmation(name: "click", label: "Send", arguments: [:]))
        XCTAssertFalse(AutonomyMode.fullAccess.requiresConfirmation(name: "press_keys", label: "", arguments: ["keys": "return"]))
        XCTAssertTrue(AutonomyMode.askEvery.requiresConfirmation(name: "scroll", label: "", arguments: [:]))
        XCTAssertTrue(AutonomyMode.confirmConsequences.requiresConfirmation(name: "click", label: "Delete", arguments: [:]))
    }
    func testStopRemainsLatchedUntilExplicitResume() {
        let gate = ExecutionGate()
        XCTAssertFalse(gate.isStopped)
        var actions = 0
        XCTAssertTrue(gate.perform { actions += 1 })
        gate.stop()
        XCTAssertFalse(gate.perform { actions += 1 })
        XCTAssertEqual(actions, 1)
        XCTAssertTrue(gate.isStopped)
        gate.stop()
        XCTAssertTrue(gate.isStopped)
        gate.resume()
        XCTAssertFalse(gate.isStopped)
    }
    func testWorkQueuedBeforeStopCannotRestartAfterResume() {
        let gate = ExecutionGate()
        let ticket = gate.ticket
        gate.stop(); gate.resume()
        XCTAssertFalse(gate.accepts(ticket))
        XCTAssertTrue(gate.accepts(gate.ticket))
    }
    func testFocusClockFreezesWhilePausedAndPreservesElapsed() {
        var clock = FocusClock()
        let start = Date(timeIntervalSince1970: 100)
        clock.start(at: start)
        clock.pause(at: start.addingTimeInterval(60))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(300)), 60)
        clock.resume(at: start.addingTimeInterval(300))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(330)), 90)
        clock.finish(at: start.addingTimeInterval(340))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(500)), 100)
    }
}

extension ExecutionAccessTests {
    @MainActor func testDirectNotesAreBlockedByStopAndOff() async {
        let oldMode = Settings.shared.autonomyMode
        defer { Settings.shared.autonomyMode = oldMode; ExecutionGate.shared.resume() }
        var opened = false
        ExecutionGate.shared.stop()
        let stopped = await BlueyCoordinator.shared.execute(.openNotes, notesOpener: { _ in opened = true })
        XCTAssertEqual(stopped, "Bluey is stopped. Resume explicitly to enable work.")
        XCTAssertFalse(opened)
        ExecutionGate.shared.resume(); Settings.shared.autonomyMode = .off
        _ = await BlueyCoordinator.shared.execute(.openNotes, notesOpener: { _ in opened = true })
        XCTAssertFalse(opened)
    }
    @MainActor func testDirectNotesAskEveryHonorsDecline() async {
        let oldMode = Settings.shared.autonomyMode
        defer { Settings.shared.autonomyMode = oldMode }
        Settings.shared.autonomyMode = .askEvery
        var prompted = false, opened = false
        _ = await BlueyCoordinator.shared.execute(.openNotes, notesOpener: { _ in opened = true }, approval: { _ in prompted = true; return false })
        XCTAssertTrue(prompted); XCTAssertFalse(opened)
    }
    func testFullAccessInstructionsDoNotRequireAdditionalConfirmation() {
        XCTAssertFalse(AutonomyMode.fullAccess.modelInstruction.contains("request confirmation from the user"))
        XCTAssertTrue(AutonomyMode.confirmConsequences.modelInstruction.contains("request confirmation from the user"))
    }
}
