import XCTest
@testable import GooglyMac
final class StudyStorageTests: XCTestCase {
    @MainActor func testIsolatedProfilePersistsWithoutSharedStorage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let learner = StudyLearner(storageURL: url)
        learner.startFocusSession(goal: "Fixture topic")
        learner.recordFocusProgress(app: nil, domain: nil, durationMinutes: 2)
        let reloaded = StudyLearner(storageURL: url)
        XCTAssertEqual(reloaded.profile.totalFocusMinutes, 2)
        XCTAssertEqual(reloaded.profile.subjects["Fixture topic"]?.minutesSpent, 2)
    }
}
