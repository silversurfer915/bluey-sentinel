import Foundation

public struct CacheRequestLog: Identifiable, Codable {
    public var id: UUID
    public var timestamp: Date
    public var model: String
    public var tierName: String
    public var promptTokens: Int
    public var cachedTokens: Int
    public var completionTokens: Int
    public var latencyMs: Int

    public var totalPromptTokens: Int {
        return promptTokens + cachedTokens
    }

    public var cacheHitRate: Double {
        let total = totalPromptTokens
        return total > 0 ? (Double(cachedTokens) / Double(total)) : 0.0
    }

    /// Estimated dollar savings from cache hits (based on ~75% provider cache discount)
    public var estimatedSavingsUSD: Double {
        // Average blended input price: ~$0.50 per 1M tokens, 75% discount on cached tokens = ~$0.375 / 1M tokens
        return (Double(cachedTokens) / 1_000_000.0) * 0.375
    }

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                model: String,
                tierName: String,
                promptTokens: Int,
                cachedTokens: Int,
                completionTokens: Int,
                latencyMs: Int) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.tierName = tierName
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
        self.latencyMs = latencyMs
    }
}

public struct CacheCumulativeStats {
    public var totalRequests: Int = 0
    public var totalPromptTokens: Int = 0
    public var totalCachedTokens: Int = 0
    public var totalCompletionTokens: Int = 0
    public var totalLatencyMs: Int = 0

    public var overallHitRate: Double {
        let total = totalPromptTokens + totalCachedTokens
        return total > 0 ? (Double(totalCachedTokens) / Double(total)) : 0.0
    }

    public var totalSavingsUSD: Double {
        return (Double(totalCachedTokens) / 1_000_000.0) * 0.375
    }
}

/// Tracks token usage, Gemini/DeepSeek prompt context cache hits, and estimated cost savings.
public final class CacheTracker: @unchecked Sendable {
    public static let shared = CacheTracker()

    private let queue = DispatchQueue(label: "com.googly.cachetracker", qos: .utility)
    private var stats = CacheCumulativeStats()
    private var logs: [CacheRequestLog] = []
    public var onChange: (() -> Void)?

    public init() {}

    // MARK: - Recording

    public func record(model: String,
                       tierName: String,
                       promptTokens: Int,
                       cachedTokens: Int,
                       completionTokens: Int,
                       latencyMs: Int) {
        let log = CacheRequestLog(
            model: model,
            tierName: tierName,
            promptTokens: promptTokens,
            cachedTokens: cachedTokens,
            completionTokens: completionTokens,
            latencyMs: latencyMs
        )
        queue.sync {
            stats.totalRequests += 1
            stats.totalPromptTokens += promptTokens
            stats.totalCachedTokens += cachedTokens
            stats.totalCompletionTokens += completionTokens
            stats.totalLatencyMs += latencyMs
            logs.insert(log, at: 0)
            if logs.count > 100 {
                logs = Array(logs.prefix(100))
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// Normalizes a provider response and records only observations whose cache
    /// telemetry the provider actually reported. Unknown cache state is not
    /// recorded here; the persistent store tracks it honestly in a later task.
    @discardableResult
    public func recordFromResponse(data: Data, model: String, tierName: String, latencyMs: Int) -> CacheRequestLog? {
        let usage = CacheUsageNormalizer().normalize(data: data, provider: .auto, model: model)
        switch usage.evidence {
        case .usageUnavailable, .usageWithoutCacheField:
            return nil
        case .confirmed, .reportedNoHit:
            break
        }

        let uncached = usage.uncachedInputTokens ?? 0
        let cached = usage.cachedInputTokens ?? 0
        let output = usage.outputTokens ?? 0

        record(
            model: model,
            tierName: tierName,
            promptTokens: uncached,
            cachedTokens: cached,
            completionTokens: output,
            latencyMs: latencyMs
        )

        return CacheRequestLog(
            model: model,
            tierName: tierName,
            promptTokens: uncached,
            cachedTokens: cached,
            completionTokens: output,
            latencyMs: latencyMs
        )
    }

    // MARK: - Querying

    public func snapshot() -> (stats: CacheCumulativeStats, recentLogs: [CacheRequestLog]) {
        return queue.sync {
            (self.stats, self.logs)
        }
    }

    public func reset() {
        queue.sync {
            self.stats = CacheCumulativeStats()
            self.logs.removeAll()
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
