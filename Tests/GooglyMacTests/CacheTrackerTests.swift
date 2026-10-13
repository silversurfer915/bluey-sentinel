import XCTest
@testable import GooglyMac

final class CacheTrackerTests: XCTestCase {
    var tracker: CacheTracker!

    override func setUp() {
        super.setUp()
        tracker = CacheTracker()
    }

    func testManualRecordAndCumulativeStats() throws {
        tracker.record(
            model: "gemini-3.1-flash-lite",
            tierName: "⚡ Fast",
            promptTokens: 200,
            cachedTokens: 800,
            completionTokens: 50,
            latencyMs: 120
        )

        let (stats, logs) = tracker.snapshot()
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.totalPromptTokens, 200)
        XCTAssertEqual(stats.totalCachedTokens, 800)
        XCTAssertEqual(stats.totalCompletionTokens, 50)
        // Hit rate = 800 / (200 + 800) = 80%
        XCTAssertEqual(stats.overallHitRate, 0.8, accuracy: 0.001)
        XCTAssertGreaterThan(stats.totalSavingsUSD, 0.0)

        XCTAssertEqual(logs.count, 1)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.cacheHitRate, 0.8, accuracy: 0.001)
    }

    func testRecordFromDeepSeekResponseJSON() throws {
        let jsonString = """
        {
            "id": "chatcmpl-123",
            "choices": [{"message": {"role": "assistant", "content": "Done"}}],
            "usage": {
                "prompt_tokens": 1500,
                "completion_tokens": 80,
                "total_tokens": 1580,
                "prompt_tokens_details": {
                    "cached_tokens": 1200
                }
            }
        }
        """
        let data = Data(jsonString.utf8)
        let log = try XCTUnwrap(tracker.recordFromResponse(data: data, model: "deepseek-chat", tierName: "🧠 Flagship", latencyMs: 340))

        XCTAssertEqual(log.cachedTokens, 1200)
        XCTAssertEqual(log.promptTokens, 300) // 1500 - 1200
        XCTAssertEqual(log.cacheHitRate, 0.8, accuracy: 0.001)
    }

    func testRecordFromGeminiResponseJSON() throws {
        let jsonString = """
        {
            "id": "chatcmpl-gemini",
            "choices": [{"message": {"role": "assistant", "content": "Here is your answer"}}],
            "usage": {
                "prompt_tokens": 2000,
                "cached_content_token_count": 1600,
                "completion_tokens": 120,
                "total_tokens": 2120
            }
        }
        """
        let data = Data(jsonString.utf8)
        let log = try XCTUnwrap(tracker.recordFromResponse(data: data, model: "gemini-3.1-flash-lite", tierName: "⚡ Fast", latencyMs: 210))

        XCTAssertEqual(log.cachedTokens, 1600)
        XCTAssertEqual(log.promptTokens, 400) // 2000 - 1600
        XCTAssertEqual(log.cacheHitRate, 0.8, accuracy: 0.001)
    }

    func testRecordFromResponseWithNoCacheFieldIsNotRecorded() {
        let jsonString = """
        {"usage": {"prompt_tokens": 2000, "completion_tokens": 120}}
        """
        let log = tracker.recordFromResponse(data: Data(jsonString.utf8), model: "gemini-3.1-flash-lite",
                                             tierName: "⚡ Fast", latencyMs: 210)
        XCTAssertNil(log, "A response without a cache field must not be recorded as a zero hit")
        XCTAssertEqual(tracker.snapshot().stats.totalRequests, 0)
    }

    func testRecordFromResponseTracksReportedNoHit() throws {
        let jsonString = """
        {"usage": {"prompt_tokens": 1000, "completion_tokens": 10,
                   "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 1000}}
        """
        let log = try XCTUnwrap(tracker.recordFromResponse(data: Data(jsonString.utf8), model: "deepseek-chat",
                                                          tierName: "🧠 Flagship", latencyMs: 300))
        XCTAssertEqual(log.cachedTokens, 0)
        XCTAssertEqual(log.promptTokens, 1000)
        XCTAssertEqual(log.cacheHitRate, 0.0, accuracy: 0.001)
    }

    func testRecordFromResponseRejectsInconsistentTotals() {
        let jsonString = """
        {"usage": {"prompt_tokens": 1000, "prompt_cache_hit_tokens": 800, "prompt_cache_miss_tokens": 100}}
        """
        let log = tracker.recordFromResponse(data: Data(jsonString.utf8), model: "deepseek-chat",
                                             tierName: "🧠 Flagship", latencyMs: 300)
        XCTAssertNil(log)
    }

    func testRecordFromResponseRejectsCachedGreaterThanTotal() {
        let jsonString = """
        {"usage": {"prompt_tokens": 100, "prompt_tokens_details": {"cached_tokens": 500}}}
        """
        let log = tracker.recordFromResponse(data: Data(jsonString.utf8), model: "custom",
                                             tierName: "⚡ Fast", latencyMs: 100)
        XCTAssertNil(log)
    }
}
