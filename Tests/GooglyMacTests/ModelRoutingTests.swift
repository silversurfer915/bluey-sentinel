import XCTest
@testable import GooglyMac

final class ModelRoutingTests: XCTestCase {

    func testUserOverridesToFlagship() {
        let prompts = [
            "use big brain for this: analyze this complex swift crash trace",
            "Solve this math problem, use flagship",
            "pro model: write an implementation for this algorithm"
        ]

        for p in prompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.tier, .flagship, "Prompt '\(p)' should route to flagship tier")
            XCTAssertTrue(decision.overridden)
        }
    }

    func testUserOverridesToFast() {
        let prompts = [
            "use fast model for this: what time is it?",
            "quick answer: define diffraction",
            "use lite: tell me a short joke"
        ]

        for p in prompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.tier, .fast, "Prompt '\(p)' should route to fast tier")
            XCTAssertTrue(decision.overridden)
        }
    }

    func testComputerActionsAndScreenUnderstandingClassifyAsFlagship() {
        let screenPrompts = [
            "Click on the Safari icon in the dock",
            "Type my password and press return",
            "Look at my screen and tell me what error Xcode is showing",
            "Read this window and find the formula",
            "Plan my study schedule for next week in steps",
            "Scroll down to find the download link"
        ]

        for p in screenPrompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.tier, .flagship, "Prompt '\(p)' should classify as flagship tier")
            XCTAssertFalse(decision.overridden)
        }
    }

    func testCasualChatAndQuickQueriesClassifyAsFast() {
        let casualPrompts = [
            "Hi Bluey, how are you today?",
            "Tell me a dry British joke",
            "What is 25 * 4?",
            "Thanks, that was helpful",
            "Good morning"
        ]

        for p in casualPrompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.tier, .fast, "Prompt '\(p)' should classify as fast tier")
            XCTAssertFalse(decision.overridden)
        }
    }

    func testRoutingModeLocking() {
        let complexPrompt = "Click the button and inspect screen errors"
        let lockedFast = ModelClassifier.classify(prompt: complexPrompt, mode: .alwaysFast)
        XCTAssertEqual(lockedFast.tier, .fast)

        let casualPrompt = "Hello there"
        let lockedFlagship = ModelClassifier.classify(prompt: casualPrompt, mode: .alwaysFlagship)
        XCTAssertEqual(lockedFlagship.tier, .flagship)
    }

    func testConversationalChatbotIntentClassification() {
        let conversationalPrompts = [
            "Hello how are you",
            "what are you doing",
            "whats the time",
            "what's the time",
            "whats the weather",
            "what's the weather",
            "how's the weather today",
            "tell me a joke",
            "who are you",
            "why is the sky blue",
            "good morning mate"
        ]

        for p in conversationalPrompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.intent, .conversation, "Prompt '\(p)' should be classified as .conversation intent")
        }
    }

    func testComputerUseIntentClassification() {
        let computerUsePrompts = [
            "Click the submit button",
            "double click the icon",
            "Look at my screen and help me",
            "What's on my screen?",
            "Read this window",
            "Type into the search bar",
            "Press return",
            "Scroll down to the footer",
            "Open Safari",
            "Start focus on physics"
        ]

        for p in computerUsePrompts {
            let decision = ModelClassifier.classify(prompt: p)
            XCTAssertEqual(decision.intent, .computerUse, "Prompt '\(p)' should be classified as .computerUse intent")
        }
    }

    @MainActor
    func testConversationalInstructionsFormatting() {
        let conversationalPrompt = RealtimeHost.instructions(for: "Hello how are you", isConversational: true)
        XCTAssertTrue(conversationalPrompt.contains("conversational chatbot companion"))
        XCTAssertTrue(conversationalPrompt.contains("=== Live Real-World Context ==="))
        XCTAssertTrue(conversationalPrompt.contains("Current Local Time & Date"))
        XCTAssertFalse(conversationalPrompt.contains("For multi-step work use update_plan"))

        let computerPrompt = RealtimeHost.instructions(for: "Click the button", isConversational: false)
        XCTAssertTrue(computerPrompt.contains("For multi-step work use update_plan"))
        XCTAssertFalse(computerPrompt.contains("conversational chatbot companion"))
    }
}
