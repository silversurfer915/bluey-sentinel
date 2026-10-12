import XCTest
@testable import GooglyMac

final class SanctraTests: XCTestCase {
    func testKeychainStorageForSanctraToken() {
        let sampleToken = "sanctra_personal_test_token_1234567890"
        let saved = Keychain.set(.sanctraPersonalToken, sampleToken)
        XCTAssertTrue(saved)
        XCTAssertEqual(Keychain.get(.sanctraPersonalToken), sampleToken)
        Keychain.set(.sanctraPersonalToken, nil)
    }

    func testOutboxSerialization() throws {
        let op = OutboxOperation(
            sessionId: "sess-test",
            action: "pause",
            accountUid: "owner-1",
            expectedRevision: 2
        )
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(OutboxOperation.self, from: data)
        XCTAssertEqual(decoded.sessionId, "sess-test")
        XCTAssertEqual(decoded.action, "pause")
        XCTAssertEqual(decoded.accountUid, "owner-1")
        XCTAssertEqual(decoded.expectedRevision, 2)
    }

    func testContextDecoding() throws {
        let json = """
        {
            "revision": "42",
            "account": {
                "uid": "owner-abc",
                "displayName": "Test Owner",
                "timezone": "Asia/Kolkata"
            },
            "streaks": {
                "streakDays": 5,
                "streakDate": "2026-10-12",
                "streakUtcOffset": 330
            },
            "subjects": [
                {"id": "phy", "name": "Physics", "color": "#3B82F6"}
            ],
            "topics": [
                {"id": "optics", "title": "Wave Optics", "subjectId": "phy", "completed": false}
            ],
            "goals": {
                "dailyGoalHours": 4.5,
                "weeklyTargetHours": 25.0
            }
        }
        """
        let context = try JSONDecoder().decode(SanctraStudyContext.self, from: Data(json.utf8))
        XCTAssertEqual(context.account?.uid, "owner-abc")
        XCTAssertEqual(context.streaks?.streakDays, 5)
        XCTAssertEqual(context.subjects?.first?.name, "Physics")
        XCTAssertEqual(context.topics?.first?.title, "Wave Optics")
        XCTAssertEqual(context.goals?.dailyGoalHours, 4.5)
    }

    func testSyncStateDecoding() throws {
        let json = """
        {
            "revision": 3,
            "serverTime": 1728734900000,
            "activeSession": {
                "id": "sess-live",
                "subjectName": "Chemistry",
                "topicTitle": "Thermodynamics",
                "plannedDurationSeconds": 3600,
                "status": "active",
                "isPaused": false,
                "accumulatedSeconds": 120,
                "revision": 3
            }
        }
        """
        struct RawSync: Codable {
            let revision: Int?
            let serverTime: Double?
            let activeSession: SanctraActiveSession?
        }
        let raw = try JSONDecoder().decode(RawSync.self, from: Data(json.utf8))
        XCTAssertEqual(raw.revision, 3)
        XCTAssertEqual(raw.activeSession?.id, "sess-live")
        XCTAssertEqual(raw.activeSession?.subjectName, "Chemistry")
        XCTAssertEqual(raw.activeSession?.accumulatedSeconds, 120)
    }
}
