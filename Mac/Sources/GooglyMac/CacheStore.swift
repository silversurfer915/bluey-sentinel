import Foundation
import SQLite3

/// One persisted provider request. Contains no prompts or responses.
public struct CacheRequestLog: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let provider: AIProvider
    public let model: String
    public let tier: ModelTier
    public let prefixVersion: String
    public let usage: NormalizedTokenUsage
    public let latencyMs: Int

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                provider: AIProvider,
                model: String,
                tier: ModelTier,
                prefixVersion: String,
                usage: NormalizedTokenUsage,
                latencyMs: Int) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.tier = tier
        self.prefixVersion = prefixVersion
        self.usage = usage
        self.latencyMs = latencyMs
    }
}

/// Confirmed/no-hit/unknown counts for one provider and model.
public struct CacheProviderSummary: Equatable, Hashable, Sendable {
    public let provider: AIProvider
    public let model: String
    public let confirmedHits: Int
    public let confirmedMisses: Int
    public let unknownRequests: Int
    public let reusedInputTokens: Int

    public init(provider: AIProvider, model: String, confirmedHits: Int,
                confirmedMisses: Int, unknownRequests: Int, reusedInputTokens: Int) {
        self.provider = provider
        self.model = model
        self.confirmedHits = confirmedHits
        self.confirmedMisses = confirmedMisses
        self.unknownRequests = unknownRequests
        self.reusedInputTokens = reusedInputTokens
    }
}

/// Honest, observable cache telemetry. Unknown telemetry is never counted as a
/// miss, and no dollar saving is invented.
public struct CacheDashboardSnapshot: Equatable, Sendable {
    public let totalRequests: Int
    public let requestsWithCacheTelemetry: Int
    public let confirmedHitRate: Double?
    public let reusedInputTokens: Int
    public let medianLatencyMs: Int?
    public let unknownTelemetryRequests: Int
    public let providerBreakdown: [CacheProviderSummary]
    public let recentLogs: [CacheRequestLog]

    public init(totalRequests: Int,
                requestsWithCacheTelemetry: Int,
                confirmedHitRate: Double?,
                reusedInputTokens: Int,
                medianLatencyMs: Int?,
                unknownTelemetryRequests: Int,
                providerBreakdown: [CacheProviderSummary],
                recentLogs: [CacheRequestLog]) {
        self.totalRequests = totalRequests
        self.requestsWithCacheTelemetry = requestsWithCacheTelemetry
        self.confirmedHitRate = confirmedHitRate
        self.reusedInputTokens = reusedInputTokens
        self.medianLatencyMs = medianLatencyMs
        self.unknownTelemetryRequests = unknownTelemetryRequests
        self.providerBreakdown = providerBreakdown
        self.recentLogs = recentLogs
    }
}

/// A local, WAL-mode SQLite store for provider cache telemetry. It keeps the
/// newest 500 records and drops records older than 90 days after each insert.
public final class CacheStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1
    public static let maxRecords = 500
    public static let retentionDays: Double = 90
    public static let recentLogLimit = 100

    private let queue = DispatchQueue(label: "com.googly.cachestore", qos: .utility)
    private var db: OpaquePointer?
    public let databaseURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.databaseURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = appSupport.appendingPathComponent("Googly", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.databaseURL = folder.appendingPathComponent("cache.sqlite")
        }
        queue.sync {
            open()
            configure()
            createSchema()
        }
    }

    deinit {
        queue.sync {
            if let db = self.db { sqlite3_close(db); self.db = nil }
        }
    }

    // MARK: - Setup

    private func open() {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            NSLog("[CacheStore] Failed to open database at \(databaseURL.path)")
        }
    }

    private func configure() {
        guard let db = db else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_busy_timeout(db, 3_000)
    }

    private func createSchema() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS cache_requests (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            tier TEXT NOT NULL,
            prefix_version TEXT NOT NULL,
            total_input_tokens INTEGER,
            cached_input_tokens INTEGER,
            uncached_input_tokens INTEGER,
            output_tokens INTEGER,
            evidence TEXT NOT NULL,
            warning_code TEXT,
            latency_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cache_requests_timestamp ON cache_requests(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_cache_requests_provider_model ON cache_requests(provider, model, timestamp);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[CacheStore] Failed to create schema: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_exec(db, "PRAGMA user_version = \(Self.schemaVersion);", nil, nil, nil)
    }

    // MARK: - Writing

    public func record(_ log: CacheRequestLog) {
        queue.sync {
            guard let db = db else { return }
            let sql = """
            INSERT OR REPLACE INTO cache_requests
                (id, timestamp, provider, model, tier, prefix_version,
                 total_input_tokens, cached_input_tokens, uncached_input_tokens, output_tokens,
                 evidence, warning_code, latency_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindText(statement, 1, log.id.uuidString)
                sqlite3_bind_double(statement, 2, log.timestamp.timeIntervalSince1970)
                bindText(statement, 3, log.provider.rawValue)
                bindText(statement, 4, log.model)
                bindText(statement, 5, log.tier.rawValue)
                bindText(statement, 6, log.prefixVersion)
                bindOptionalInt(statement, 7, log.usage.totalInputTokens)
                bindOptionalInt(statement, 8, log.usage.cachedInputTokens)
                bindOptionalInt(statement, 9, log.usage.uncachedInputTokens)
                bindOptionalInt(statement, 10, log.usage.outputTokens)
                bindText(statement, 11, log.usage.evidence.rawValue)
                bindOptionalText(statement, 12, log.usage.warningCode)
                sqlite3_bind_int64(statement, 13, Int64(log.latencyMs))
                if sqlite3_step(statement) != SQLITE_DONE {
                    NSLog("[CacheStore] Insert failed: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(statement)
            applyRetention(db)
        }
    }

    private func applyRetention(_ db: OpaquePointer) {
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86_400).timeIntervalSince1970
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM cache_requests WHERE timestamp < ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, cutoff)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        sqlite3_exec(db, "DELETE FROM cache_requests WHERE id NOT IN (SELECT id FROM cache_requests ORDER BY timestamp DESC, id DESC LIMIT \(Self.maxRecords));", nil, nil, nil)
    }

    // MARK: - Reading

    public func logs(newestFirst limit: Int? = nil) -> [CacheRequestLog] {
        var results: [CacheRequestLog] = []
        queue.sync {
            guard let db = db else { return }
            var sql = "SELECT id, timestamp, provider, model, tier, prefix_version, total_input_tokens, cached_input_tokens, uncached_input_tokens, output_tokens, evidence, warning_code, latency_ms FROM cache_requests ORDER BY timestamp DESC, id DESC"
            if let limit { sql += " LIMIT \(limit)" }
            sql += ";"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let log = decodeLog(statement) { results.append(log) }
                }
            }
            sqlite3_finalize(statement)
        }
        return results
    }

    public func count() -> Int {
        var result = 0
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cache_requests;", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW {
                result = Int(sqlite3_column_int64(statement, 0))
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    public func snapshot(now: Date = Date()) -> CacheDashboardSnapshot {
        let all = logs(newestFirst: nil)

        var confirmedHits = 0
        var confirmedMisses = 0
        var unknown = 0
        var reused = 0
        var latencies: [Int] = []
        var groups: [String: (provider: AIProvider, model: String, hits: Int, misses: Int, unknown: Int, reused: Int)] = [:]

        for log in all {
            latencies.append(log.latencyMs)
            if let cached = log.usage.cachedInputTokens { reused += cached }

            let key = "\(log.provider.rawValue)|\(log.model)"
            var group = groups[key] ?? (log.provider, log.model, 0, 0, 0, 0)
            if let cached = log.usage.cachedInputTokens { group.reused += cached }

            switch log.usage.evidence {
            case .confirmed:
                confirmedHits += 1
                group.hits += 1
            case .reportedNoHit:
                confirmedMisses += 1
                group.misses += 1
            case .usageWithoutCacheField, .usageUnavailable:
                unknown += 1
                group.unknown += 1
            }
            groups[key] = group
        }

        let telemetry = confirmedHits + confirmedMisses
        let hitRate = telemetry > 0 ? Double(confirmedHits) / Double(telemetry) : nil

        let breakdown = groups.values
            .map { CacheProviderSummary(provider: $0.provider, model: $0.model,
                                        confirmedHits: $0.hits, confirmedMisses: $0.misses,
                                        unknownRequests: $0.unknown, reusedInputTokens: $0.reused) }
            .sorted { ($0.provider.rawValue, $0.model) < ($1.provider.rawValue, $1.model) }

        return CacheDashboardSnapshot(
            totalRequests: all.count,
            requestsWithCacheTelemetry: telemetry,
            confirmedHitRate: hitRate,
            reusedInputTokens: reused,
            medianLatencyMs: Self.median(latencies),
            unknownTelemetryRequests: unknown,
            providerBreakdown: breakdown,
            recentLogs: Array(all.prefix(Self.recentLogLimit))
        )
    }

    public func reset() {
        queue.sync {
            guard let db = db else { return }
            if sqlite3_exec(db, "DELETE FROM cache_requests;", nil, nil, nil) != SQLITE_OK {
                NSLog("[CacheStore] Reset failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    // MARK: - Helpers

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return Int((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2.0)
    }

    private func decodeLog(_ statement: OpaquePointer?) -> CacheRequestLog? {
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        }
        func optionalInt(_ index: Int32) -> Int? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
        }

        guard let idString = text(0), let id = UUID(uuidString: idString),
              let provider = text(2).flatMap(AIProvider.init(rawValue:)),
              let model = text(3),
              let tier = text(4).flatMap(ModelTier.init(rawValue:)),
              let prefix = text(5),
              let evidence = text(10).flatMap(CacheEvidence.init(rawValue:)) else { return nil }

        let usage = NormalizedTokenUsage(
            totalInputTokens: optionalInt(6),
            cachedInputTokens: optionalInt(7),
            uncachedInputTokens: optionalInt(8),
            outputTokens: optionalInt(9),
            evidence: evidence,
            warningCode: text(11)
        )
        return CacheRequestLog(
            id: id,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            provider: provider,
            model: model,
            tier: tier,
            prefixVersion: prefix,
            usage: usage,
            latencyMs: Int(sqlite3_column_int64(statement, 12))
        )
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) }
    }
}
