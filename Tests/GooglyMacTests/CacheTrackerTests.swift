import XCTest
@testable import GooglyMac

final class CacheTrackerTests: XCTestCase {
    var tracker: CacheTracker!
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cache_tracker_\(UUID().uuidString).sqlite")
        tracker = CacheTracker(store: CacheStore(fileURL: tempURL))
    }

    override func tearDown() {
        tracker = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + suffix))
        }
        super.tearDown()
    }

    private func usage(_ evidence: CacheEvidence, cached: Int?, total: Int?) -> NormalizedTokenUsage {
        NormalizedTokenUsage(totalInputTokens: total, cachedInputTokens: cached,
                             uncachedInputTokens: total.map { $0 - (cached ?? 0) },
                             outputTokens: 50, evidence: evidence, warningCode: nil)
    }

    func testRecordAndSnapshot() {
        tracker.record(usage: usage(.confirmed, cached: 800, total: 1_000),
                       provider: .deepseek, model: "deepseek-chat", tier: .flagship,
                       prefixVersion: "bluey-prompt-v2", latencyMs: 120)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 1)
        XCTAssertEqual(snapshot.confirmedHitRate ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.reusedInputTokens, 800)
        XCTAssertEqual(snapshot.recentLogs.first?.provider, .deepseek)
        XCTAssertEqual(snapshot.recentLogs.first?.prefixVersion, "bluey-prompt-v2")
    }

    func testRecordFromResponseConfirmedHit() {
        let data = Data("""
        {"usage": {"prompt_tokens": 1500, "completion_tokens": 80,
                   "prompt_cache_hit_tokens": 1200, "prompt_cache_miss_tokens": 300}}
        """.utf8)
        let log = tracker.recordFromResponse(data: data, provider: .deepseek, model: "deepseek-chat",
                                             tier: .flagship, prefixVersion: "bluey-prompt-v2", latencyMs: 340)
        XCTAssertEqual(log.usage.cachedInputTokens, 1200)
        XCTAssertEqual(log.usage.uncachedInputTokens, 300)
        XCTAssertEqual(log.usage.evidence, .confirmed)
        XCTAssertEqual(tracker.snapshot().confirmedHitRate ?? -1, 1.0, accuracy: 0.001)
    }

    func testRecordFromResponseStoresUnknownUsageHonestly() {
        let data = Data(#"{"usage": {"prompt_tokens": 2000, "completion_tokens": 120}}"#.utf8)
        let log = tracker.recordFromResponse(data: data, provider: .gemini, model: "gemini-3.1-flash-lite",
                                             tier: .fast, prefixVersion: "bluey-prompt-v2", latencyMs: 210)
        XCTAssertEqual(log.usage.evidence, .usageWithoutCacheField)
        XCTAssertNil(log.usage.cachedInputTokens)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.unknownTelemetryRequests, 1)
        XCTAssertNil(snapshot.confirmedHitRate, "Unknown usage must not count as a miss")
    }

    func testResetClearsSnapshot() {
        tracker.record(usage: usage(.confirmed, cached: 10, total: 20),
                       provider: .gemini, model: "m", tier: .fast,
                       prefixVersion: "bluey-prompt-v2", latencyMs: 10)
        tracker.reset()
        XCTAssertEqual(tracker.snapshot().totalRequests, 0)
    }
}
