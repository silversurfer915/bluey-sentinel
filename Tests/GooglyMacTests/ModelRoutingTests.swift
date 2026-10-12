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
}
