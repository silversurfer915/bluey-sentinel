import XCTest
import SQLite3
@testable import GooglyMac

final class MemoryStoreTests: XCTestCase {
    var tempURL: URL!
    var store: MemoryStore!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_memory_\(UUID().uuidString).sqlite")
        store = MemoryStore(fileURL: tempURL)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testAddAndRetrieveMemories() {
        let item1 = store.add(type: .profile, content: "Hareesh studies physics and optics")
        let item2 = store.add(type: .preference, content: "Prefers dark mode and Safari")
        let item3 = store.add(type: .lesson, content: "Never click red close button on Terminal", triggerContext: "closing terminal")

        let all = store.allMemories()
        XCTAssertEqual(all.count, 3)

        let lessons = store.memories(of: .lesson)
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons.first?.content, item3.content)

        let prefs = store.memories(of: .preference)
        XCTAssertEqual(prefs.count, 1)
        XCTAssertEqual(prefs.first?.content, item2.content)

        let profiles = store.memories(of: .profile)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.content, item1.content)
    }

    func testSearchMemories() {
        store.add(type: .profile, content: "User is an iOS developer")
        store.add(type: .preference, content: "Prefers concise one-line answers")
        store.add(type: .lesson, content: "Do not restart simulator during build", triggerContext: "iOS build")

        let results = store.search(query: "concise")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, .preference)

        let iosResults = store.search(query: "ios")
        XCTAssertEqual(iosResults.count, 2)
    }

    func testUpdateAndDelete() {
        let item = store.add(type: .preference, content: "Initial preference")
        XCTAssertTrue(store.update(id: item.id, content: "Updated preference"))

        let fetched = store.search(query: "Updated")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.content, "Updated preference")

        XCTAssertTrue(store.delete(id: item.id))
        XCTAssertEqual(store.allMemories().count, 0)
    }

    func testForgetEverythingClearsDatabase() {
        store.add(type: .profile, content: "Fact 1")
        store.add(type: .preference, content: "Pref 1")
        store.add(type: .lesson, content: "Lesson 1")
        // A row carrying recall metadata must not leave that metadata orphaned.
        store.save(MemoryItem(id: "recalled", type: .profile, content: "Fact with recall",
                              source: .manual, confidence: 1.0,
                              recallCount: 4, lastRecalledAt: Date(), lastRecallReason: "Matched"))
        XCTAssertEqual(store.allMemories().count, 4)

        XCTAssertTrue(store.forgetEverything())
        XCTAssertEqual(store.allMemories().count, 0)
        XCTAssertEqual(rawRowCount(), 0, "No recall metadata may survive without a memory row")

        store = nil
        store = MemoryStore(fileURL: tempURL)
        XCTAssertEqual(store.allMemories().count, 0)
    }

    private func rawRowCount() -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(tempURL.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var count = -1
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM memories;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    func testRelevantRetrievalPrioritizesLessonsAndMatches() {
        store.add(type: .profile, content: "User studies quantum optics")
        store.add(type: .preference, content: "Prefers LaTeX formulas")
        store.add(type: .lesson, content: "When asked about optics, never confuse wave optics with ray optics", triggerContext: "wave optics lecture")
        store.add(type: .taskOutcome, content: "Completed finding lecture notes")

        let retrieved = store.retrieveRelevant(query: "Can you help me solve this wave optics problem?")
        XCTAssertFalse(retrieved.isEmpty)

        // Lesson should be ranked first because lessons have highest importance
        XCTAssertEqual(retrieved.first?.type, .lesson)

        let promptContext = store.formatPromptContext(for: "wave optics")
        XCTAssertTrue(promptContext.contains("DURABLE INSTRUCTIONS & CORRECTIONS"))
        XCTAssertTrue(promptContext.contains("wave optics with ray optics"))
        XCTAssertFalse(promptContext.lowercased().contains("verified"))
    }

    func testAutomaticExtractionLearnsCorrectionsAndPreferences() {
        // 1. Correction input -> should extract a lesson
        let correctionPrompt = "Don't click that red button on Xcode again"
        let reply = "Understood, I will avoid clicking the red button."
        let extracted1 = store.extractMemories(userPrompt: correctionPrompt, assistantReply: reply)

        XCTAssertFalse(extracted1.isEmpty)
        XCTAssertTrue(extracted1.contains { $0.type == .lesson })

        // 2. Explicit preference -> should extract preference
        let prefPrompt = "I prefer dark mode in all apps"
        let extracted2 = store.extractMemories(userPrompt: prefPrompt, assistantReply: "Noted.")
        XCTAssertTrue(extracted2.contains { $0.type == .preference })

        // 3. User profile fact -> should extract profile
        let factPrompt = "I am studying wave optics for my university exam"
        let extracted3 = store.extractMemories(userPrompt: factPrompt, assistantReply: "Good luck with your exam!")
        XCTAssertTrue(extracted3.contains { $0.type == .profile })
    }

    func testAddOrUpdateReplacesRelatedMemoryInsteadOfDuplicating() {
        // Initial profile fact
        store.addOrUpdate(type: .profile, content: "My name is Harish")
        XCTAssertEqual(store.allMemories().count, 1)

        // Correction to name spelling
        store.addOrUpdate(type: .profile, content: "My name spelling is HARWESH")
        let memories = store.allMemories()
        XCTAssertEqual(memories.count, 1, "Should replace old name fact instead of creating a second one")
        XCTAssertEqual(memories.first?.content, "My name spelling is HARWESH")

        // Preference update
        store.addOrUpdate(type: .preference, content: "I prefer dark mode")
        XCTAssertEqual(store.memories(of: .preference).count, 1)

        store.addOrUpdate(type: .preference, content: "I prefer light mode")
        let prefs = store.memories(of: .preference)
        XCTAssertEqual(prefs.count, 1, "Should replace dark mode with light mode preference")
        XCTAssertEqual(prefs.first?.content, "I prefer light mode")
    }

    func testCompoundFactExtractionAndUpdating() {
        let prompt = "Please remember that I live in Coimbatore and my name is Harish and I'm in class 12"
        let extracted = store.extractMemories(userPrompt: prompt, assistantReply: "I'll remember all of that!")
        XCTAssertEqual(extracted.count, 3, "Should extract location, name, and class facts")

        let profilesBefore = store.memories(of: .profile)
        XCTAssertEqual(profilesBefore.count, 3)

        // Now user updates their location
        store.extractMemories(userPrompt: "My location is Bangalore", assistantReply: "Updated your location!")
        let profilesAfter = store.memories(of: .profile)
        XCTAssertEqual(profilesAfter.count, 3, "Total profile count should remain 3")
        XCTAssertTrue(profilesAfter.contains { $0.content.contains("Bangalore") })
        XCTAssertFalse(profilesAfter.contains { $0.content.contains("Coimbatore") })
    }

    func testDeduplicateExistingMemoriesUnifiesStaleDuplicates() {
        // Force add 2 separate items with different IDs for the same topic
        store.add(type: .profile, content: "My name is Harish")
        store.add(type: .profile, content: "My name spelling is HARWESH")
        XCTAssertEqual(store.memories(of: .profile).count, 2)

        store.deduplicateExistingMemories()
        let deduplicated = store.memories(of: .profile)
        XCTAssertEqual(deduplicated.count, 1, "deduplicateExistingMemories should collapse multiple name facts into one")
        XCTAssertEqual(deduplicated.first?.content, "My name spelling is HARWESH")
    }
    func testSchoolGradeAndStudySubjectRemainSeparateAfterUpdates() {
        store.addOrUpdate(type: .profile, content: "My school is Central School")
        store.addOrUpdate(type: .profile, content: "I'm in class 12")
        store.addOrUpdate(type: .profile, content: "I am studying physics")
        store.addOrUpdate(type: .profile, content: "I'm in class 11")
        let facts = store.memories(of: .profile)
        XCTAssertEqual(facts.count, 3)
        XCTAssertTrue(facts.contains { $0.content == "My school is Central School" })
        XCTAssertTrue(facts.contains { $0.content == "I am studying physics" })
        XCTAssertTrue(facts.contains { $0.content == "I'm in class 11" })
        XCTAssertFalse(facts.contains { $0.content == "I'm in class 12" })
    }

    func testSameAppPreferencesAndLessonsDoNotEraseDifferentProperties() {
        store.addOrUpdate(type: .preference, content: "I prefer Safari for browsing")
        store.addOrUpdate(type: .preference, content: "Never close Safari tabs")
        store.addOrUpdate(type: .preference, content: "Use dark mode in Safari")
        store.addOrUpdate(type: .preference, content: "Use light mode in Chrome")
        store.addOrUpdate(type: .lesson, content: "Never close Terminal during a build")
        store.addOrUpdate(type: .lesson, content: "Use Terminal to inspect logs")
        XCTAssertEqual(store.memories(of: .preference).count, 4)
        XCTAssertEqual(store.memories(of: .lesson).count, 2)
        store = nil
        store = MemoryStore(fileURL: tempURL)
        XCTAssertEqual(store.memories(of: .preference).count, 4, "Relaunch must not silently discard independent preferences")
        XCTAssertEqual(store.memories(of: .lesson).count, 2)
    }

    func testPersistReplacesByReplacementKeyAndPreservesMetadata() {
        let original = MemoryItem(type: .preference, content: "I prefer dark mode",
                                  source: .explicitPreference, confidence: 0.95,
                                  replacementKey: "preference:appearance:global",
                                  isPinned: true, recallCount: 2,
                                  lastRecalledAt: Date(timeIntervalSince1970: 100),
                                  lastRecallReason: "Matched dark")
        store.save(original)

        let updated = store.persist(MemoryCandidate(type: .preference, content: "I prefer light mode",
                                                    source: .explicitPreference, confidence: 0.95,
                                                    replacementKey: "preference:appearance:global"))
        XCTAssertEqual(updated?.id, original.id, "Replacement must keep the original id")
        XCTAssertEqual(updated?.createdAt.timeIntervalSince1970 ?? 0,
                       original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(updated?.content, "I prefer light mode")
        XCTAssertTrue(updated?.isPinned ?? false, "Pin must survive replacement")
        XCTAssertEqual(updated?.recallCount, 2, "Recall metadata must survive replacement")
        XCTAssertEqual(updated?.lastRecallReason, "Matched dark")
        XCTAssertEqual(store.allMemories().count, 1)
    }

    func testPersistMergesExactNormalizedDuplicatesWithoutKeys() {
        store.persist(MemoryCandidate(type: .profile, content: "I live in Coimbatore",
                                      source: .explicitProfile, confidence: 0.95, replacementKey: nil))
        store.persist(MemoryCandidate(type: .profile, content: "i live in coimbatore",
                                      source: .explicitProfile, confidence: 0.95, replacementKey: nil))
        XCTAssertEqual(store.allMemories().count, 1, "Exact normalized duplicates without keys may merge")
    }

    func testPersistDoesNotMergeUnrelatedFacts() {
        store.persist(MemoryCandidate(type: .profile, content: "I live in Coimbatore",
                                      source: .explicitProfile, confidence: 0.95, replacementKey: "profile:residence"))
        store.persist(MemoryCandidate(type: .profile, content: "I study physics",
                                      source: .explicitProfile, confidence: 0.95, replacementKey: "profile:study_subject"))
        store.persist(MemoryCandidate(type: .lesson, content: "Never close Terminal",
                                      source: .correction, confidence: 0.98, replacementKey: nil))
        XCTAssertEqual(store.allMemories().count, 3)
    }

    func testStartupKeepsMostRecentlyUpdatedFactInsteadOfNewestCreated() {
        let old = MemoryItem(id: "original", type: .profile, content: "My name is Latest", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 30))
        let stale = MemoryItem(id: "stale", type: .profile, content: "My name is Stale", createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 20))
        store.save(old)
        store.save(stale)
        store = nil
        store = MemoryStore(fileURL: tempURL)
        XCTAssertEqual(store.memories(of: .profile).map(\.content), ["My name is Latest"])
    }

}
