import XCTest
@testable import GooglyMac

final class WorkflowSkillExtractorTests: XCTestCase {
    let extractor = WorkflowSkillExtractor()
    let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func call(_ name: String, _ args: [String: Any] = [:]) -> (name: String, arguments: [String: Any]) {
        (name, args)
    }

    private func observation(_ calls: [(name: String, arguments: [String: Any])],
                             intent: String = "open the page",
                             kind: WorkflowVerificationKind = .observableResult,
                             day: Int) -> WorkflowObservation {
        extractor.observation(intent: intent, calls: calls, verificationKind: kind,
                              outcome: .completed(summary: "done"),
                              completedAt: day0.addingTimeInterval(Double(day) * 86_400))!
    }

    // MARK: - Step 1: eligibility

    func testOnlyVerifiedCompletedWorkflowsProduceObservations() {
        let calls = [call("computer_snapshot"), call("computer_click", ["ref": "1", "snapshotId": 2])]
        for kind in [WorkflowVerificationKind.observableResult, .savedArtifactReopened, .explicitUserConfirmed] {
            XCTAssertNotNil(extractor.observation(intent: "open the page", calls: calls,
                                                  verificationKind: kind, outcome: .completed(summary: "done")))
        }
        XCTAssertNil(extractor.observation(intent: "open the page", calls: calls,
                                           verificationKind: nil, outcome: .completed(summary: "done")))
        XCTAssertNil(extractor.observation(intent: "open the page", calls: calls,
                                           verificationKind: .observableResult, outcome: .unfinished(summary: "x")))
        XCTAssertNil(extractor.observation(intent: "open the page", calls: calls,
                                           verificationKind: .observableResult, outcome: nil))
        XCTAssertNil(extractor.observation(intent: "open the page", calls: [],
                                           verificationKind: .observableResult, outcome: .completed(summary: "done")),
                     "A conversation-only turn has no actions and must not be observed")
    }

    // MARK: - Step 2: privacy redaction

    func testNormalizationDiscardsAllOriginalContent() throws {
        let secret = "sk-1234567890abcdefghijklmnop"
        let calls = [
            call("computer_navigate", ["url": "https://example.com/private?token=abc"]),
            call("computer_type", ["ref": "7", "text": "my password is hunter2"]),
            call("computer_write_file", ["path": "/Users/me/secret/notes.txt", "content": "PRIVATE BODY"]),
            call("computer_snapshot", ["windowTitle": "Bank account 1234"]),
            call("computer_run_command", ["command": "cat ~/.ssh/id_rsa"]),
            call("computer_click", ["ref": "9", "snapshotId": 3, "secret": secret]),
        ]
        let observation = try XCTUnwrap(extractor.observation(intent: "handle my banking", calls: calls,
                                                              verificationKind: .observableResult,
                                                              outcome: .completed(summary: "ok")))
        let json = String(data: try JSONEncoder().encode(observation), encoding: .utf8) ?? ""

        let forbidden = ["https://example.com", "token=abc", "password", "hunter2", "/Users/me",
                         "notes.txt", "PRIVATE BODY", "Bank", "1234", "id_rsa", secret]
        for value in forbidden {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(value), "Leaked original content: \(value)")
        }

        XCTAssertEqual(observation.actionSequence.map(\.toolName), calls.map(\.name))
        let allowed: Set<String> = ["screen", "visible-control", "text-field", "keys", "scroll", "drag",
                                    "app", "browser", "page", "web", "list", "read", "write", "shell",
                                    "human", "secret", "start", "control", "steps", "other"]
        for action in observation.actionSequence {
            XCTAssertTrue(action.parameterCategories.values.allSatisfy { allowed.contains($0) },
                          "Unexpected category value in \(action.parameterCategories)")
        }
    }

    func testNormalizedIntentNeverEchoesTheRequest() {
        for raw in ["organise my downloads at https://example.com", "book a table at Luigi's", "summarise the physics paper"] {
            let intent = WorkflowSkillExtractor.normalizedIntent(raw)
            XCTAssertFalse(intent.localizedCaseInsensitiveContains("example.com"))
            XCTAssertFalse(intent.contains(" "))
            XCTAssertTrue(["web-research", "file-management", "focus", "computer-use", "general"].contains(intent))
        }
    }

    // MARK: - Step 3: candidate threshold

    func testNoProposalBelowThresholdOrWithinOneDay() {
        let calls = [call("computer_snapshot"), call("computer_click")]
        XCTAssertTrue(extractor.proposals(from: [observation(calls, day: 0), observation(calls, day: 1)]).isEmpty,
                      "Two verified successes are not enough")
        XCTAssertTrue(extractor.proposals(from: [observation(calls, day: 0), observation(calls, day: 0),
                                                observation(calls, day: 0)]).isEmpty,
                      "Three successes within one day are not enough")
    }

    func testProposalAppearsAtThreeSuccessesAcrossTwoDays() {
        let calls = [call("computer_snapshot"), call("computer_click")]
        let proposals = extractor.proposals(from: [observation(calls, day: 0),
                                                   observation(calls, day: 1),
                                                   observation(calls, day: 1)])
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.evidenceCount, 3)
        XCTAssertEqual(proposals.first?.status, .proposed)
        XCTAssertEqual(proposals.first?.revision, 1)
        XCTAssertFalse(proposals.first?.steps.isEmpty ?? true)
        XCTAssertTrue(proposals.first?.description.localizedCaseInsensitiveContains("re-observes") ?? false)
    }

    func testDifferentIntentsOrOrderDoNotMerge() {
        let a = [call("computer_snapshot"), call("computer_click")]
        let reversed = [call("computer_click"), call("computer_snapshot")]
        let observations = [
            observation(a, intent: "open the page", day: 0),
            observation(a, intent: "open the page", day: 1),
            observation(a, intent: "open the page", day: 1),
            observation(reversed, intent: "open the page", day: 0),
            observation(reversed, intent: "open the page", day: 1),
            observation(reversed, intent: "open the page", day: 1),
            observation(a, intent: "research the topic", day: 0),
            observation(a, intent: "research the topic", day: 1),
            observation(a, intent: "research the topic", day: 1),
        ]
        XCTAssertEqual(extractor.proposals(from: observations).count, 3)
    }

    func testProposalIDsAreDeterministic() {
        let calls = [call("computer_snapshot"), call("computer_click")]
        let first = extractor.proposals(from: [observation(calls, day: 0), observation(calls, day: 1), observation(calls, day: 1)])
        let second = extractor.proposals(from: [observation(calls, day: 0), observation(calls, day: 1), observation(calls, day: 1)])
        XCTAssertEqual(first.first?.id, second.first?.id)
    }
}
