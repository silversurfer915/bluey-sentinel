import XCTest
@testable import GooglyMac

final class ConservativeMemoryExtractorTests: XCTestCase {
    let extractor = ConservativeMemoryExtractor()

    // MARK: - Positive extraction matrix

    func testExplicitProfileFacts() {
        let cases: [(input: String, key: String)] = [
            ("I live in Coimbatore", "profile:residence"),
            ("My name is Harish", "profile:name"),
            ("My name spelling is HARWESH", "profile:name"),
            ("I study physics", "profile:study_subject"),
            ("I'm in class 12", "profile:grade"),
            ("My school is Central School", "profile:school"),
            ("I work as a designer", "profile:profession"),
            ("My exam is on Friday", "profile:exam"),
        ]
        for (input, key) in cases {
            let candidates = extractor.extract(userText: input)
            XCTAssertEqual(candidates.count, 1, "Expected one candidate for: \(input)")
            let candidate = candidates[0]
            XCTAssertEqual(candidate.type, .profile, input)
            XCTAssertEqual(candidate.source, .explicitProfile, input)
            XCTAssertEqual(candidate.confidence, 0.95, accuracy: 0.0001, input)
            XCTAssertEqual(candidate.replacementKey, key, input)
            XCTAssertEqual(candidate.content, input, input)
            XCTAssertEqual(candidate.triggerContext, input, input)
        }
    }

    func testExplicitPreferences() {
        let cases: [(input: String, key: String?)] = [
            ("I prefer dark mode", "preference:appearance:global"),
            ("I prefer dark mode in Safari", "preference:appearance:safari"),
            ("Keep answers concise", "preference:length:global"),
            ("Use Safari", "preference:app:safari"),
            ("Always use markdown", "preference:format:global"),
        ]
        for (input, key) in cases {
            let candidates = extractor.extract(userText: input)
            XCTAssertEqual(candidates.count, 1, "Expected one candidate for: \(input)")
            let candidate = candidates[0]
            XCTAssertEqual(candidate.type, .preference, input)
            XCTAssertEqual(candidate.source, .explicitPreference, input)
            XCTAssertEqual(candidate.confidence, 0.95, accuracy: 0.0001, input)
            XCTAssertEqual(candidate.replacementKey, key, input)
            XCTAssertEqual(candidate.content, input, input)
        }
    }

    func testDirectCorrectionsAndDurableInstructions() {
        for input in ["Never close Terminal", "Next time ask before submitting", "Don't click the red button again"] {
            let candidates = extractor.extract(userText: input)
            XCTAssertEqual(candidates.count, 1, "Expected one candidate for: \(input)")
            let candidate = candidates[0]
            XCTAssertEqual(candidate.type, .lesson, input)
            XCTAssertEqual(candidate.source, .correction, input)
            XCTAssertEqual(candidate.confidence, 0.98, accuracy: 0.0001, input)
            XCTAssertNil(candidate.replacementKey, input)
            XCTAssertEqual(candidate.content, input, input)
        }
    }

    func testRememberDirectiveStripsPrefixAndClassifiesContent() {
        let candidates = extractor.extract(userText: "Please remember that I live in Coimbatore")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].type, .profile)
        XCTAssertEqual(candidates[0].source, .explicitProfile)
        XCTAssertEqual(candidates[0].replacementKey, "profile:residence")
        XCTAssertEqual(candidates[0].content, "I live in Coimbatore")
        XCTAssertEqual(candidates[0].triggerContext, "Please remember that I live in Coimbatore")
    }

    func testRememberDirectiveFallbackUsesProfile() {
        let candidates = extractor.extract(userText: "Remember this: my locker code is at the front desk")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].type, .profile)
        XCTAssertEqual(candidates[0].source, .explicitProfile)
        XCTAssertNil(candidates[0].replacementKey)
        XCTAssertEqual(candidates[0].content, "my locker code is at the front desk")
    }

    func testCompoundStatementsProduceSeparateFacts() {
        let input = "I live in Coimbatore and my name is Harish and I'm in class 12"
        let candidates = extractor.extract(userText: input)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(Set(candidates.map(\.replacementKey)),
                       ["profile:residence", "profile:name", "profile:grade"])
        XCTAssertTrue(candidates.allSatisfy { $0.source == .explicitProfile })
    }

    func testVerifiedTaskOutcomes() {
        let completed = extractor.extract(userText: "please organise my downloads",
                                          verifiedOutcome: .completed(summary: "Organised 12 files"))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].type, .taskOutcome)
        XCTAssertEqual(completed[0].source, .taskOutcome)
        XCTAssertEqual(completed[0].confidence, 0.90, accuracy: 0.0001)
        XCTAssertNil(completed[0].replacementKey)
        XCTAssertEqual(completed[0].content, "Completed: Organised 12 files")

        let unfinished = extractor.extract(userText: "please organise my downloads",
                                           verifiedOutcome: .unfinished(summary: "Only moved 4 files"))
        XCTAssertEqual(unfinished.count, 1)
        XCTAssertEqual(unfinished[0].type, .taskOutcome)
        XCTAssertEqual(unfinished[0].content, "Unfinished: Only moved 4 files")
    }

    // MARK: - Negative extraction matrix

    func testNoCandidatesForQuestionsHypotheticalsQuotesAndSmallTalk() {
        let inputs = [
            "Do you remember my exam?",
            "If I lived in Delhi, would the time change?",
            "The page says \"I prefer Chrome\"",
            "He said I prefer Chrome",
            "Hello Bluey, how are you?",
            "That's interesting, tell me more",
        ]
        for input in inputs {
            XCTAssertTrue(extractor.extract(userText: input).isEmpty, "Should not learn from: \(input)")
        }
    }

    func testUnverifiedCompletionTextIsNotAOutcome() {
        let candidates = extractor.extract(userText: "I completed the task and finished everything")
        XCTAssertTrue(candidates.isEmpty)
    }

    func testAssistantReplyIsNeverEvidence() {
        let store = MemoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor_assistant_\(UUID().uuidString).sqlite"))
        defer { try? FileManager.default.removeItem(at: store.databaseURL) }

        let learned = store.extractMemories(userPrompt: "Hello there",
                                            assistantReply: "I prefer dark mode and I live in Paris")
        XCTAssertTrue(learned.isEmpty, "Assistant prose must not create memories")
        XCTAssertEqual(store.allMemories().count, 0)
    }

    // MARK: - Sensitive-value rejection

    func testSensitiveValuesAreRejectedBeforePersistence() {
        let cases: [(input: String, kind: SensitiveRejection)] = [
            ("Remember my API key is sk-1234567890abcdefghijklmnop", .apiKey),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456", .bearerToken),
            ("My password is hunter2xyz", .password),
            ("My seed phrase is apple banana cherry dog eagle fish grape house igloo jelly kite lemon", .recoveryPhrase),
            ("The one-time code is 123456", .oneTimeCode),
            ("My card number is 4111 1111 1111 1111", .paymentCard),
            ("My CVV is 123", .cvvPin),
            ("My social security number is 123-45-6789", .governmentID),
        ]
        for (input, kind) in cases {
            XCTAssertEqual(extractor.sensitiveRejection(in: input), kind, input)
            XCTAssertTrue(extractor.extract(userText: input).isEmpty, "Must reject: \(input)")
        }
    }

    func testRejectionDiagnosticExposesOnlyAFixedCode() {
        let secret = "sk-1234567890abcdefghijklmnop"
        let input = "remember my api key is \(secret)"
        guard let kind = extractor.sensitiveRejection(in: input) else {
            return XCTFail("Expected a rejection")
        }
        XCTAssertEqual(kind, .apiKey)
        // The diagnostic is a fixed enum raw value, never the secret.
        XCTAssertFalse(kind.rawValue.contains(secret))
        XCTAssertEqual(kind.rawValue, "api_key")
    }

    func testOrdinaryFactsAreNotTreatedAsSensitive() {
        for input in ["I live in Coimbatore", "I'm in class 12", "My name is Harish",
                      "I prefer dark mode", "Never close Terminal"] {
            XCTAssertNil(extractor.sensitiveRejection(in: input), input)
        }
    }
}
