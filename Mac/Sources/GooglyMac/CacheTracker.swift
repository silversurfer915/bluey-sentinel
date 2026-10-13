import Foundation

/// A thin, relaunch-safe facade over the persisted cache telemetry store.
/// Keeps the shared singleton, change notifications, snapshot, and reset entry
/// points while delegating storage and aggregation to `CacheStore`.
public final class CacheTracker: @unchecked Sendable {
    public static let shared = CacheTracker()

    public let store: CacheStore
    public var onChange: (() -> Void)?

    public init(store: CacheStore = CacheStore()) {
        self.store = store
    }

    // MARK: - Recording

    /// Persists one request observation, including responses without usage.
    @discardableResult
    public func record(usage: NormalizedTokenUsage,
                       provider: AIProvider,
                       model: String,
                       tier: ModelTier,
                       prefixVersion: String,
                       latencyMs: Int,
                       timestamp: Date = Date()) -> CacheRequestLog {
        let log = CacheRequestLog(timestamp: timestamp, provider: provider, model: model,
                                  tier: tier, prefixVersion: prefixVersion,
                                  usage: usage, latencyMs: latencyMs)
        store.record(log)
        notifyChange()
        return log
    }

    /// Normalizes a provider response and persists it. Unknown telemetry is
    /// stored honestly rather than dropped or turned into a zero hit.
    @discardableResult
    public func recordFromResponse(data: Data,
                                   provider: AIProvider,
                                   model: String,
                                   tier: ModelTier,
                                   prefixVersion: String,
                                   latencyMs: Int) -> CacheRequestLog {
        let usage = CacheUsageNormalizer().normalize(data: data, provider: provider, model: model)
        return record(usage: usage, provider: provider, model: model, tier: tier,
                      prefixVersion: prefixVersion, latencyMs: latencyMs)
    }

    // MARK: - Querying

    public func snapshot() -> CacheDashboardSnapshot {
        store.snapshot()
    }

    public func reset() {
        store.reset()
        notifyChange()
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
