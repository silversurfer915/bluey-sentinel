import XCTest
@testable import GooglyMac

final class SanctraTests: XCTestCase {
    func testAccountEnvelopeWithMetadataAndSyncQuery() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SanctraFixtureProtocol.self]
        let client = SanctraClient(baseURL: URL(string: "https://fixture.invalid/v1/personal")!, session: URLSession(configuration: config), tokenProvider: { "fixture-only" })
        let account = try await client.fetchAccount()
        XCTAssertEqual(account.uid, "fixture-owner")
        let sync = try await client.fetchSync(revision: 7)
        XCTAssertEqual(sync.revision, 7)
    }


    @MainActor
    func testSyncAdoptsRemoteWithoutEchoAndPreservesQueuedTailOnRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json")
        let ops = [OutboxOperation(sessionId: "first", action: "create", timestamp: 1000, accountUid: "fixture-owner", subjectId: "phy", subjectName: "Physics"), OutboxOperation(sessionId: "second", action: "pause", accountUid: "fixture-owner", expectedRevision: 1)]
        try JSONEncoder().encode(ops).write(to: url)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SanctraFixtureProtocol.self]
        let client = SanctraClient(baseURL: URL(string: "https://fixture.invalid/v1/personal")!, session: URLSession(configuration: config), tokenProvider: { "fixture-only" })
        var adopted: [String?] = []
        let sync = SanctraSync(client: client, outboxURL: url, applyState: { adopted.append($0?.id) })
        try await sync.connect()
        XCTAssertFalse(sync.isConnected)
        let saved = try JSONDecoder().decode([OutboxOperation].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.map(\.sessionId), ["first", "second"])
        XCTAssertEqual(saved.first?.timestamp, 1000)
        XCTAssertTrue(adopted.isEmpty)
        // A fresh client with no queue adopts the remote session without creating anything.
        try FileManager.default.removeItem(at: url)
        let fresh = SanctraSync(client: client, outboxURL: url, applyState: { adopted.append($0?.id) })
        try await fresh.connect()
        XCTAssertTrue(fresh.isConnected)
        XCTAssertEqual(fresh.pendingOutboxCount, 0)
        XCTAssertEqual(adopted.last!, "remote-session")
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

private final class SanctraFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        let body: String
        if request.url?.path.hasSuffix("/account") == true {
            body = #"{"revision":"7","account":{"uid":"fixture-owner","displayName":"Fixture","timezone":"UTC"},"streaks":{"streakDays":3}}"#
        } else if request.url?.path.hasSuffix("/context") == true {
            body = #"{"revision":"7","subjects":[]}"#
        } else if request.url?.path.hasSuffix("/sync") == true {
            if let revision = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value { XCTAssertTrue(Int(revision) != nil) }
            body = #"{"revision":7,"serverTime":1000,"activeSession":{"id":"remote-session","status":"active","isPaused":true,"accumulatedSeconds":123}}"#
        } else {
            client?.urlProtocol(self, didFailWithError: SanctraError.notFound); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
