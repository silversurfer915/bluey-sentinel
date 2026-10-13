import XCTest
@testable import GooglyMac

final class PromptContextBuilderTests: XCTestCase {
    private func input(isConversational: Bool = false,
                       computerControl: Bool = true,
                       autonomy: String = "AUT",
                       study: String? = nil,
                       learner: String? = nil,
                       memory: String? = nil,
                       live: String? = nil) -> PromptContextInput {
        PromptContextInput(
            personality: "PERSONALITY",
            isConversational: isConversational,
            computerControl: computerControl,
            conversationalGuide: "CHAT_GUIDE",
            toolGuide: "TOOL_GUIDE",
            computerGuide: "COMPUTER_GUIDE",
            autonomyInstruction: autonomy,
            studyInstruction: study,
            learnerContext: learner,
            memoryContext: memory,
            liveContext: live
        )
    }

    func testStableSystemIsByteIdenticalAcrossDynamicChanges() {
        let builder = PromptContextBuilder()
        let first = builder.build(input(autonomy: "AUT_ONE", learner: "LEARN_ONE", memory: "MEMORY_ONE", live: "LIVE_ONE"))
        let second = builder.build(input(autonomy: "AUT_TWO", learner: "LEARN_TWO", memory: "MEMORY_TWO", live: "LIVE_TWO"))

        XCTAssertEqual(first.stableSystem, second.stableSystem,
                       "Dynamic memory/live/autonomy changes must not touch the stable prefix")
        XCTAssertNotEqual(first.dynamicSystem, second.dynamicSystem)
        XCTAssertEqual(first.stableSystem, "PERSONALITY\n\nTOOL_GUIDE\n\nCOMPUTER_GUIDE")
    }

    func testChangingModeChangesStablePrefixIntentionally() {
        let builder = PromptContextBuilder()
        let conversational = builder.build(input(isConversational: true))
        let tool = builder.build(input(isConversational: false))
        XCTAssertNotEqual(conversational.stableSystem, tool.stableSystem)
        XCTAssertEqual(conversational.stableSystem, "PERSONALITY\n\nCHAT_GUIDE")
        XCTAssertEqual(tool.stableSystem, "PERSONALITY\n\nTOOL_GUIDE\n\nCOMPUTER_GUIDE")
    }

    func testComputerGuideIsOmittedWhenComputerControlIsOff() {
        let context = PromptContextBuilder().build(input(computerControl: false))
        XCTAssertFalse(context.stableSystem.contains("COMPUTER_GUIDE"))
    }

    func testNoMemoryOrLivePhraseAppearsInStableSystem() {
        let context = PromptContextBuilder().build(input(study: "SECRET_STUDY_PHRASE", memory: "SECRET_MEMORY_PHRASE",
                                                         live: "SECRET_LIVE_PHRASE"))
        XCTAssertFalse(context.stableSystem.contains("SECRET_MEMORY_PHRASE"))
        XCTAssertFalse(context.stableSystem.contains("SECRET_LIVE_PHRASE"))
        XCTAssertFalse(context.stableSystem.contains("SECRET_STUDY_PHRASE"))
        XCTAssertTrue(context.dynamicSystem?.contains("SECRET_MEMORY_PHRASE") ?? false)
    }

    func testMessageOrderIsStableThenDynamicThenHistoryThenUser() {
        let context = PromptContextBuilder().build(input(memory: "MEM"))
        let history: [[String: Any]] = [
            ["role": "user", "content": "old question"],
            ["role": "assistant", "content": "old answer"],
        ]
        let user: [String: Any] = ["role": "user", "content": "current question"]
        let messages = PromptContextBuilder.assembleMessages(context: context, history: history, userMessage: user)

        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, context.stableSystem)
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, context.dynamicSystem)
        XCTAssertEqual(messages[2]["content"] as? String, "old question")
        XCTAssertEqual(messages[3]["content"] as? String, "old answer")
        XCTAssertEqual(messages[4]["content"] as? String, "current question")
    }

    func testEmptyDynamicSystemIsOmittedFromMessages() {
        let context = PromptContextBuilder().build(input(autonomy: ""))
        XCTAssertNil(context.dynamicSystem)
        let messages = PromptContextBuilder.assembleMessages(context: context, history: [], userMessage: ["role": "user", "content": "hi"])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    func testToolsAreSortedByName() {
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "zeta"]],
            ["type": "function", "function": ["name": "alpha"]],
            ["type": "function", "function": ["name": "mu"]],
        ]
        let names = PromptContextBuilder.sortedTools(tools).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["alpha", "mu", "zeta"])
    }

    func testPrefixVersionIsStable() {
        XCTAssertEqual(PromptContext.prefixVersion, "bluey-prompt-v2")
    }
}
