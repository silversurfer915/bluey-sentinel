import XCTest
@testable import GooglyMac

final class WorkflowSkillRunnerTests: XCTestCase {
    let runner = WorkflowSkillRunner()

    private func skill(_ status: WorkflowSkillStatus, title: String = "Computer use · 2 steps") -> WorkflowSkillProposal {
        WorkflowSkillProposal(revision: 1, title: title,
                              description: "Open a browser page and click a visible control.",
                              preconditions: ["Re-observe the current screen before acting"],
                              steps: ["computer_navigate — browser", "computer_click — visible-control"],
                              evidenceCount: 3,
                              firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                              lastSeenAt: Date(timeIntervalSince1970: 1_700_086_400),
                              status: status)
    }

    func testOnlyPublishedSkillsReachPlannerContext() {
        let request = "open the browser and click the button"
        XCTAssertNil(runner.plannerContext(for: request, skills: [skill(.proposed)]))
        XCTAssertNil(runner.plannerContext(for: request, skills: [skill(.rejected)]))
        XCTAssertNil(runner.plannerContext(for: request, skills: [skill(.paused)]))

        let context = runner.plannerContext(for: request, skills: [skill(.published)])
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("suggestions only") ?? false)
        XCTAssertTrue(context?.contains("computer_navigate") ?? false)
    }

    func testCasualChatGetsNoSkills() {
        XCTAssertNil(runner.plannerContext(for: "how are you today", skills: [skill(.published)]))
        XCTAssertNil(runner.plannerContext(for: "", skills: [skill(.published)]))
    }

    func testContextIsBoundedToLimit() {
        let request = "open the browser and click the button"
        let skills = (0..<6).map { _ in skill(.published) }
        let context = runner.plannerContext(for: request, skills: skills, limit: 3)
        let bullets = context?.split(separator: "\n").filter { $0.hasPrefix("- ") }.count ?? 0
        XCTAssertEqual(bullets, 3)
    }

    @MainActor
    func testRunnerNeverChangesAccessPolicyOrStopState() {
        let oldMode = Settings.shared.autonomyMode
        let wasStopped = ExecutionGate.shared.isStopped
        defer { Settings.shared.autonomyMode = oldMode }

        Settings.shared.autonomyMode = .off
        _ = runner.plannerContext(for: "open the browser and click the button", skills: [skill(.published)])

        XCTAssertEqual(Settings.shared.autonomyMode, .off, "Planning context must not change access policy")
        XCTAssertEqual(ExecutionGate.shared.isStopped, wasStopped)
    }
}
