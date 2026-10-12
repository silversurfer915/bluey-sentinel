import XCTest
@testable import GooglyMac
final class AgentTests: XCTestCase {
    @MainActor func testMultiStepImagesAndMetadataSurvive() async throws {
        var turns = 0
        var sawImage = false
        let runner = AgentRunner()
        let result = try await runner.run(messages: [["role": "user", "content": "inspect"]], vision: true, request: { messages in
            turns += 1
            if turns == 1 {
                return AgentResponse(rawMessage: ["role": "assistant", "tool_calls": [["id": "one", "extra_content": ["google": ["thought_signature": "signature"]], "function": ["name": "look_at_screen", "arguments": "{}"]]]], text: nil, calls: [AgentCall(id: "one", name: "look_at_screen", arguments: "{}")])
            }
            sawImage = messages.contains { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true }
            XCTAssertNotNil((messages[1]["tool_calls"] as? [[String: Any]])?.first?["extra_content"])
            return AgentResponse(rawMessage: [:], text: "Visible result", calls: [])
        }, execute: { _ in AgentToolResult(text: "observed", image: "jpeg") }, progress: { _ in })
        XCTAssertEqual(result, "Visible result")
        XCTAssertTrue(sawImage)
    }
    @MainActor func testBudgetReturnsHonestIncompleteResult() async throws {
        let runner = AgentRunner(maxTurns: 2)
        let result = try await runner.run(messages: [], vision: false, request: { _ in
            AgentResponse(rawMessage: ["role": "assistant"], text: nil, calls: [AgentCall(id: UUID().uuidString, name: "look_at_screen", arguments: "{}")])
        }, execute: { _ in AgentToolResult(text: UUID().uuidString, image: nil) }, progress: { _ in })
        XCTAssertTrue(result.contains("unfinished"))
    }
    @MainActor func testCancellationPreventsNextAction() async {
        let runner = AgentRunner()
        var actions = 0
        let task = Task {
            try await runner.run(messages: [], vision: false, request: { _ in
                try await Task.sleep(for: .seconds(3))
                return AgentResponse(rawMessage: [:], text: nil, calls: [AgentCall(id: "x", name: "click", arguments: "{}")])
            }, execute: { _ in actions += 1; return AgentToolResult(text: "done", image: nil) }, progress: { _ in })
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(actions, 0)
    }
    @MainActor func testBatchedActionsCannotUseStaleTargets() async throws {
        var turn = 0, actions: [String] = []
        _ = try await AgentRunner().run(messages: [], vision: false, request: { _ in
            turn += 1
            return turn == 1 ? AgentResponse(rawMessage: [:], text: nil, calls: [AgentCall(id: "a", name: "click", arguments: "{}"), AgentCall(id: "b", name: "click", arguments: "{}")]) : AgentResponse(rawMessage: [:], text: "done", calls: [])
        }, execute: { call in if call.name == "click" { actions.append(call.id) }; return AgentToolResult(text: "updated", image: nil) }, progress: { _ in })
        XCTAssertEqual(actions, ["a"])
    }
}
