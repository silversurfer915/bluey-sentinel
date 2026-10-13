import XCTest
@testable import GooglyMac

final class WorkflowLearningStoreTests: XCTestCase {
    var tempURL: URL!
    let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("workflow_\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + suffix))
        }
        super.tearDown()
    }

    private func observation(day: Int) -> WorkflowObservation {
        WorkflowObservation(
            normalizedIntent: "web-research",
            actionSequence: [NormalizedWorkflowAction(toolName: "computer_snapshot", parameterCategories: ["observation": "screen"]),
                             NormalizedWorkflowAction(toolName: "computer_click", parameterCategories: ["target": "visible-control"])],
            verificationKind: .observableResult,
            completedAt: day0.addingTimeInterval(Double(day) * 86_400))
    }

    private func proposal(_ status: WorkflowSkillStatus = .proposed, revision: Int = 1) -> WorkflowSkillProposal {
        WorkflowSkillProposal(revision: revision, title: "Web research · 2 steps",
                              description: "A verified routine.",
                              preconditions: ["Re-observe the current screen before acting"],
                              steps: ["computer_snapshot — screen", "computer_click — visible-control"],
                              evidenceCount: 3, firstSeenAt: day0,
                              lastSeenAt: day0.addingTimeInterval(86_400), status: status)
    }

    // MARK: - Persistence

    func testObservationsAndProposalsSurviveRelaunch() {
        var store: WorkflowLearningStore? = WorkflowLearningStore(fileURL: tempURL)
        store?.recordObservation(observation(day: 0))
        store?.recordObservation(observation(day: 1))
        store?.recordObservation(observation(day: 1))
        store?.refreshProposals(using: WorkflowSkillExtractor())
        XCTAssertEqual(store?.observations().count, 3)
        XCTAssertEqual(store?.proposals().count, 1)
        store = nil

        let reopened = WorkflowLearningStore(fileURL: tempURL)
        XCTAssertEqual(reopened.observations().count, 3)
        let proposals = reopened.proposals()
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.evidenceCount, 3)
        XCTAssertEqual(proposals.first?.status, .proposed)
    }

    func testRefreshProposalsDoesNotDuplicate() {
        let store = WorkflowLearningStore(fileURL: tempURL)
        store.recordObservation(observation(day: 0))
        store.recordObservation(observation(day: 1))
        store.recordObservation(observation(day: 1))
        store.refreshProposals(using: WorkflowSkillExtractor())
        store.refreshProposals(using: WorkflowSkillExtractor())
        XCTAssertEqual(store.proposals().count, 1)
    }

    // MARK: - Privacy

    func testSerializedRowsContainNoOriginalContent() {
        let store = WorkflowLearningStore(fileURL: tempURL)
        let secret = "sk-1234567890abcdefghijklmnop"
        let observation = WorkflowObservation(
            normalizedIntent: "general",
            actionSequence: [NormalizedWorkflowAction(toolName: "computer_navigate", parameterCategories: ["destination": "browser"]),
                             NormalizedWorkflowAction(toolName: "computer_type", parameterCategories: ["target": "text-field"])],
            verificationKind: .observableResult,
            completedAt: day0)
        store.recordObservation(observation)
        store.saveProposal(proposal())

        let rows = store.rawPayloads().joined(separator: "\n")
        for forbidden in ["https://", "/Users/", "password", secret, "hunter2", "windowTitle", "PRIVATE"] {
            XCTAssertFalse(rows.localizedCaseInsensitiveContains(forbidden), "Leaked: \(forbidden)")
        }
    }

    // MARK: - Owner lifecycle

    func testPublishRejectPauseResumeDelete() {
        let store = WorkflowLearningStore(fileURL: tempURL)
        let item = proposal()
        store.saveProposal(item)

        XCTAssertEqual(store.publish(id: item.id)?.status, .published)
        XCTAssertEqual(store.publishedSkills().count, 1)

        XCTAssertEqual(store.pause(id: item.id)?.status, .paused)
        XCTAssertEqual(store.publishedSkills().count, 0)

        XCTAssertEqual(store.resume(id: item.id)?.status, .published)
        XCTAssertEqual(store.reject(id: item.id)?.status, .rejected)
        XCTAssertEqual(store.publishedSkills().count, 0)

        XCTAssertTrue(store.delete(id: item.id))
        XCTAssertTrue(store.proposals().isEmpty)
    }

    func testEditingPublishedSkillCreatesNewRevisionAndLeavesPublishedIntact() {
        let store = WorkflowLearningStore(fileURL: tempURL)
        let item = proposal()
        store.saveProposal(item)
        store.publish(id: item.id)

        let revised = store.editProposal(id: item.id, title: "Edited title",
                                         description: "Edited description",
                                         preconditions: ["p"], steps: ["s1", "s2"])
        XCTAssertNotEqual(revised?.id, item.id)
        XCTAssertEqual(revised?.revision, 2)
        XCTAssertEqual(revised?.status, .proposed)

        let published = store.proposal(id: item.id)
        XCTAssertEqual(published?.status, .published)
        XCTAssertEqual(published?.title, "Web research · 2 steps")
        XCTAssertEqual(store.publishedSkills().count, 1)
    }

    func testEditingProposedSkillUpdatesInPlace() {
        let store = WorkflowLearningStore(fileURL: tempURL)
        let item = proposal()
        store.saveProposal(item)
        let revised = store.editProposal(id: item.id, title: "Updated", description: "d",
                                         preconditions: ["p"], steps: ["s1"])
        XCTAssertEqual(revised?.id, item.id)
        XCTAssertEqual(revised?.title, "Updated")
        XCTAssertEqual(store.proposals().count, 1)
    }
}
