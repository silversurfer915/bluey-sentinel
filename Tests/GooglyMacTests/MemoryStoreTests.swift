import XCTest
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
        XCTAssertEqual(store.allMemories().count, 3)

        XCTAssertTrue(store.forgetEverything())
        XCTAssertEqual(store.allMemories().count, 0)
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
        XCTAssertTrue(promptContext.contains("CRITICAL LESSONS & CORRECTIONS"))
        XCTAssertTrue(promptContext.contains("wave optics with ray optics"))
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
}
