import XCTest
@testable import GooglyMac

final class MemoryRetrievalTests: XCTestCase {
    // MARK: - Tokenizer

    func testTokenizerFoldsCaseDiacriticsAndRemovesStopWords() {
        let tokens = MemoryTokenizer.tokenize("Café iOS M4 12 the and")
        XCTAssertTrue(tokens.contains("cafe"), "Diacritics fold and case lowers")
        XCTAssertTrue(tokens.contains("ios"))
        XCTAssertTrue(tokens.contains("m4"))
        XCTAssertTrue(tokens.contains("12"))
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("and"))
    }

    func testTokenizerRetainsIdentifiersByDigitRule() {
        XCTAssertEqual(MemoryTokenizer.tokenize("a1"), ["a1"], "Two chars with a digit are kept")
        XCTAssertEqual(MemoryTokenizer.tokenize("ab"), [], "Two plain chars are dropped")
        XCTAssertEqual(MemoryTokenizer.tokenize("abc"), ["abc"], "Three plain chars are kept")
    }

    // MARK: - Deterministic order

    func testDeterministicTieBreakByScoreThenUpdatedThenID() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let b = MemoryItem(id: "b", type: .preference, content: "wave optics", createdAt: now, updatedAt: now,
                           source: .explicitPreference, confidence: 0.95, replacementKey: "preference:length:global")
        let a = MemoryItem(id: "a", type: .preference, content: "wave optics", createdAt: now, updatedAt: now,
                           source: .explicitPreference, confidence: 0.95, replacementKey: "preference:length:global")
        let recalls = MemoryRetriever().retrieve(query: "wave optics", items: [b, a], now: now)
        XCTAssertEqual(recalls.map(\.item.id), ["a", "b"], "Equal score and time break by id ascending")
    }

    // MARK: - Relevance

    func testMatchingCorrectionOutranksGlobalPreference() {
        let now = Date()
        let lesson = MemoryItem(type: .lesson, content: "When asked about optics, never confuse wave optics with ray optics",
                                triggerContext: "wave optics lecture", createdAt: now, updatedAt: now,
                                source: .correction, confidence: 0.98)
        let preference = MemoryItem(type: .preference, content: "Keep answers concise",
                                    createdAt: now, updatedAt: now,
                                    source: .explicitPreference, confidence: 0.95,
                                    replacementKey: "preference:length:global")
        let recalls = MemoryRetriever().retrieve(query: "Can you help me solve this wave optics problem?",
                                                 items: [preference, lesson], now: now)
        XCTAssertEqual(recalls.first?.item.id, lesson.id)
        XCTAssertTrue(recalls.contains { $0.item.id == preference.id }, "A global preference stays eligible")
        XCTAssertTrue(recalls.first?.reason.localizedCaseInsensitiveContains("wave") ?? false)
    }

    func testUnrelatedLessonIsExcludedDespiteTypeWeight() {
        let lesson = MemoryItem(type: .lesson, content: "Never close Terminal during a build",
                                source: .correction, confidence: 0.98)
        let recalls = MemoryRetriever().retrieve(query: "What is the weather today?", items: [lesson])
        XCTAssertTrue(recalls.isEmpty, "An unmatched lesson must not enter the prompt")
    }

    func testGlobalPreferenceIsEligibleWithoutATokenMatch() {
        let preference = MemoryItem(type: .preference, content: "Keep answers concise",
                                    source: .explicitPreference, confidence: 0.95,
                                    replacementKey: "preference:length:global")
        let recalls = MemoryRetriever().retrieve(query: "unrelated words entirely", items: [preference])
        XCTAssertEqual(recalls.count, 1)
        XCTAssertEqual(recalls.first?.reason, "Global preference")
    }

    func testOldTaskOutcomeIsExcludedUnlessMatchedOrPinned() {
        let now = Date()
        let old = now.addingTimeInterval(-31 * 86_400)
        let unmatched = MemoryItem(type: .taskOutcome, content: "Organised downloads", updatedAt: old,
                                   source: .taskOutcome, confidence: 0.90)
        let matched = MemoryItem(type: .taskOutcome, content: "Organised wave optics notes", updatedAt: old,
                                 source: .taskOutcome, confidence: 0.90)
        let pinned = MemoryItem(type: .taskOutcome, content: "Organised downloads", updatedAt: old,
                                source: .taskOutcome, confidence: 0.90, isPinned: true)
        let retriever = MemoryRetriever()
        XCTAssertTrue(retriever.retrieve(query: "wave optics", items: [unmatched], now: now).isEmpty)
        XCTAssertEqual(retriever.retrieve(query: "wave optics", items: [matched], now: now).count, 1)
        XCTAssertEqual(retriever.retrieve(query: "something unrelated", items: [pinned], now: now).count, 1)
    }

    func testPinnedItemsAreConsideredButBudgetBounded() {
        let now = Date()
        let items = (0..<15).map { index in
            MemoryItem(id: String(format: "p%02d", index), type: .profile, content: "Pinned fact \(index)",
                       updatedAt: now, isPinned: true)
        }
        let recalls = MemoryRetriever().retrieve(query: "", items: items, budget: MemoryPromptBudget(), now: now)
        XCTAssertEqual(recalls.count, 12, "Never more than twelve memories")
    }

    // MARK: - Budget

    func testTokenBudgetSkipsOversizedItemButKeepsSmallerOnes() {
        let now = Date()
        let huge = MemoryItem(id: "huge", type: .profile, content: String(repeating: "x", count: 8_000),
                              updatedAt: now, isPinned: true)
        let small = MemoryItem(id: "small", type: .profile, content: "small fact", updatedAt: now, isPinned: true)
        let recalls = MemoryRetriever().retrieve(query: "", items: [huge, small], budget: MemoryPromptBudget(), now: now)
        XCTAssertFalse(recalls.contains { $0.item.id == "huge" }, "An oversized memory is skipped, not truncated")
        XCTAssertTrue(recalls.contains { $0.item.id == "small" })
        XCTAssertLessThanOrEqual(recalls.reduce(0) { $0 + $1.estimatedTokens }, 1_200)
    }

    func testEstimatedTokensNeverExceedBudgetAcrossManyItems() {
        let now = Date()
        let items = (0..<12).map { index in
            MemoryItem(id: String(format: "m%02d", index), type: .profile,
                       content: String(repeating: "a", count: 800), updatedAt: now, isPinned: true)
        }
        let recalls = MemoryRetriever().retrieve(query: "", items: items, now: now)
        XCTAssertLessThanOrEqual(recalls.reduce(0) { $0 + $1.estimatedTokens }, 1_200)
        XCTAssertLessThanOrEqual(recalls.count, 12)
    }

    // MARK: - Store bookkeeping

    private func makeStore() -> (MemoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recall_\(UUID().uuidString).sqlite")
        return (MemoryStore(fileURL: url), url)
    }

    func testSearchIsReadOnlyButRecallRecordsMetadata() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.save(MemoryItem(type: .profile, content: "User studies wave optics",
                              source: .explicitProfile, confidence: 0.95,
                              replacementKey: "profile:study_subject"))

        _ = store.search(query: "wave")
        XCTAssertEqual(store.allMemories().first?.recallCount, 0, "Search must not increment recall")

        let recalls = store.recall(for: "wave optics")
        XCTAssertEqual(recalls.count, 1)
        let after = store.allMemories().first
        XCTAssertEqual(after?.recallCount, 1)
        XCTAssertNotNil(after?.lastRecalledAt)
        XCTAssertNotNil(after?.lastRecallReason)
    }

    func testFormatPromptContextIsNeutralAndContainsMatchedMemory() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.save(MemoryItem(type: .lesson,
                              content: "When asked about optics, never confuse wave optics with ray optics",
                              triggerContext: "wave optics lecture",
                              source: .correction, confidence: 0.98))

        let text = store.formatPromptContext(for: "wave optics")
        XCTAssertTrue(text.contains("wave optics with ray optics"))
        XCTAssertFalse(text.lowercased().contains("verified"),
                       "Legacy and learned items must not be presented as verified")
    }
}
