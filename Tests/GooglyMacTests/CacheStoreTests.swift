import XCTest
@testable import GooglyMac

final class CacheStoreTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cache_store_\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + suffix))
        }
        super.tearDown()
    }

    private func log(provider: AIProvider = .gemini,
                     model: String = "gemini-flash",
                     evidence: CacheEvidence,
                     cached: Int?,
                     total: Int?,
                     latency: Int,
                     timestamp: Date = Date()) -> CacheRequestLog {
        let uncached: Int? = {
            guard let total else { return nil }
            return total - (cached ?? 0)
        }()
        return CacheRequestLog(timestamp: timestamp, provider: provider, model: model, tier: .fast,
                               prefixVersion: "bluey-prompt-v2",
                               usage: NormalizedTokenUsage(totalInputTokens: total,
                                                           cachedInputTokens: cached,
                                                           uncachedInputTokens: uncached,
                                                           outputTokens: 10,
                                                           evidence: evidence,
                                                           warningCode: nil),
                               latencyMs: latency)
    }

    // MARK: - Persistence and relaunch

    func testRecordsSurviveRelaunchInNewestFirstOrder() {
        let t0 = Date()
        var store: CacheStore? = CacheStore(fileURL: tempURL)
        store?.record(log(evidence: .confirmed, cached: 800, total: 1_000, latency: 100, timestamp: t0))
        store?.record(log(evidence: .reportedNoHit, cached: 0, total: 500, latency: 200, timestamp: t0.addingTimeInterval(1)))
        store?.record(log(evidence: .usageWithoutCacheField, cached: nil, total: 300, latency: 300, timestamp: t0.addingTimeInterval(2)))
        store = nil

        let reopened = CacheStore(fileURL: tempURL)
        let logs = reopened.logs(newestFirst: nil)
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs.map(\.usage.evidence), [.usageWithoutCacheField, .reportedNoHit, .confirmed])
        XCTAssertEqual(logs.last?.usage.cachedInputTokens, 800)

        let snapshot = reopened.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 3)
        XCTAssertEqual(snapshot.requestsWithCacheTelemetry, 2)
        XCTAssertEqual(snapshot.confirmedHitRate ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.reusedInputTokens, 800)
        XCTAssertEqual(snapshot.unknownTelemetryRequests, 1)
        XCTAssertEqual(snapshot.medianLatencyMs, 200)
    }

    // MARK: - Aggregates

    func testAggregatesExcludeUnknownAndSeparateProviders() {
        let store = CacheStore(fileURL: tempURL)
        let now = Date()
        store.record(log(provider: .deepseek, model: "deepseek-chat", evidence: .confirmed, cached: 900, total: 1_000, latency: 10, timestamp: now))
        store.record(log(provider: .deepseek, model: "deepseek-chat", evidence: .reportedNoHit, cached: 0, total: 100, latency: 20, timestamp: now.addingTimeInterval(1)))
        store.record(log(provider: .gemini, model: "gemini-flash", evidence: .usageWithoutCacheField, cached: nil, total: 500, latency: 30, timestamp: now.addingTimeInterval(2)))
        store.record(log(provider: .gemini, model: "gemini-flash", evidence: .usageUnavailable, cached: nil, total: nil, latency: 40, timestamp: now.addingTimeInterval(3)))

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 4)
        XCTAssertEqual(snapshot.requestsWithCacheTelemetry, 2)
        XCTAssertEqual(snapshot.confirmedHitRate ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.reusedInputTokens, 900)
        XCTAssertEqual(snapshot.unknownTelemetryRequests, 2)
        XCTAssertEqual(snapshot.providerBreakdown.count, 2)

        let deepseek = snapshot.providerBreakdown.first { $0.provider == .deepseek }
        XCTAssertEqual(deepseek?.confirmedHits, 1)
        XCTAssertEqual(deepseek?.confirmedMisses, 1)
        XCTAssertEqual(deepseek?.unknownRequests, 0)
        XCTAssertEqual(deepseek?.reusedInputTokens, 900)

        let gemini = snapshot.providerBreakdown.first { $0.provider == .gemini }
        XCTAssertEqual(gemini?.unknownRequests, 2)
        XCTAssertEqual(gemini?.confirmedHits, 0)
    }

    func testMedianLatencyOddAndEven() {
        XCTAssertNil(CacheStore.median([]))
        XCTAssertEqual(CacheStore.median([50]), 50)
        XCTAssertEqual(CacheStore.median([10, 20, 30]), 20)
        XCTAssertEqual(CacheStore.median([10, 20, 30, 40]), 25)
        XCTAssertEqual(CacheStore.median([10, 20, 21, 40]), 20)
    }

    func testZeroConfirmedTelemetryYieldsNilHitRate() {
        let store = CacheStore(fileURL: tempURL)
        store.record(log(evidence: .usageWithoutCacheField, cached: nil, total: 100, latency: 10))
        let snapshot = store.snapshot()
        XCTAssertNil(snapshot.confirmedHitRate, "Unknown telemetry must render as unknown, not 0%")
        XCTAssertEqual(snapshot.requestsWithCacheTelemetry, 0)
    }

    // MARK: - Retention and reset

    func testRetentionCapsAt500AndDropsOldRecords() {
        let store = CacheStore(fileURL: tempURL)
        let now = Date()
        for index in 0..<510 {
            store.record(log(evidence: .reportedNoHit, cached: 0, total: 1, latency: 1,
                             timestamp: now.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(store.count(), 500)

        store.record(log(evidence: .reportedNoHit, cached: 0, total: 1, latency: 1,
                         timestamp: now.addingTimeInterval(-200 * 86_400)))
        XCTAssertEqual(store.count(), 500, "A record older than 90 days must be dropped")
        XCTAssertTrue(store.logs(newestFirst: nil).allSatisfy { $0.timestamp > now.addingTimeInterval(-90 * 86_400) })
    }

    func testResetClearsDiskAndSurvivesReopen() {
        var store: CacheStore? = CacheStore(fileURL: tempURL)
        store?.record(log(evidence: .confirmed, cached: 1, total: 2, latency: 1))
        XCTAssertEqual(store?.count(), 1)

        store?.reset()
        XCTAssertEqual(store?.count(), 0)
        store = nil

        let reopened = CacheStore(fileURL: tempURL)
        XCTAssertEqual(reopened.count(), 0)
        XCTAssertEqual(reopened.snapshot().totalRequests, 0)
    }
}
