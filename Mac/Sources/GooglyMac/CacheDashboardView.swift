import SwiftUI

/// Pure, testable presentation logic for the Token Caching dashboard.
public struct CacheDashboardModel {
    public let snapshot: CacheDashboardSnapshot

    public init(snapshot: CacheDashboardSnapshot) {
        self.snapshot = snapshot
    }

    /// `—` when no request has confirmed cache telemetry yet.
    public var hitRateText: String {
        guard let rate = snapshot.confirmedHitRate else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }

    public var reusedInputText: String {
        Self.grouped(snapshot.reusedInputTokens)
    }

    public var telemetryRequestsText: String {
        Self.grouped(snapshot.requestsWithCacheTelemetry)
    }

    public var medianLatencyText: String {
        guard let median = snapshot.medianLatencyMs else { return "—" }
        return "\(median)ms"
    }

    public var providerBreakdown: [CacheProviderSummary] { snapshot.providerBreakdown }
    public var recentLogs: [CacheRequestLog] { snapshot.recentLogs }

    /// Evidence labels are explicit and never alarming for a normal miss.
    public func evidenceLabel(_ evidence: CacheEvidence) -> String {
        switch evidence {
        case .confirmed: return "Confirmed hit"
        case .reportedNoHit: return "Confirmed miss"
        case .usageWithoutCacheField: return "Cache not reported"
        case .usageUnavailable: return "Usage unavailable"
        }
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Owns cache dashboard state and store-backed reset.
@MainActor
public final class CacheDashboardViewModel: ObservableObject {
    @Published public private(set) var snapshot: CacheDashboardSnapshot

    private let tracker: CacheTracker?

    public init(tracker: CacheTracker = .shared) {
        self.tracker = tracker
        self.snapshot = tracker.snapshot()
        tracker.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Fixture-only initializer: no tracker, no side effects.
    public init(fixtureSnapshot: CacheDashboardSnapshot) {
        self.tracker = nil
        self.snapshot = fixtureSnapshot
    }

    public var model: CacheDashboardModel { CacheDashboardModel(snapshot: snapshot) }

    public func refresh() { if let tracker { snapshot = tracker.snapshot() } }

    public func reset() {
        tracker?.reset()
        refresh()
    }
}

/// Premium Token Caching dashboard: honest, provider-controlled, no invented savings.
public struct CacheDashboardView: View {
    @StateObject private var model: CacheDashboardViewModel
    @State private var isConfirmingReset = false

    public init(tracker: CacheTracker? = nil) {
        #if DEBUG
        if UIPreviewFixtures.isActive {
            _model = StateObject(wrappedValue: CacheDashboardViewModel(fixtureSnapshot: UIPreviewFixtures.cacheModel().snapshot))
            return
        }
        #endif
        _model = StateObject(wrappedValue: CacheDashboardViewModel(tracker: tracker ?? .shared))
    }

    public var body: some View {
        let dashboard = model.model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                metricRow(dashboard)
                providerBreakdown(dashboard)
                recentRequests(dashboard)
            }
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Clear all recorded cache telemetry?", isPresented: $isConfirmingReset) {
            Button("Reset Telemetry", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes the recorded request usage from your Mac. It does not affect provider-side caches.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(BlueyTheme.primary)
                Text("Provider-controlled caching").font(.system(size: 12.5, weight: .semibold))
            }
            Text("Caching is best effort and decided by your provider. Requests with unknown cache telemetry stay visible but are excluded from the hit rate. Bluey never invents a dollar saving.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineSpacing(2.5)
        }
        .padding(12)
        .background(BlueyTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BlueyTheme.primary.opacity(0.15), lineWidth: 1))
    }

    private func metricRow(_ dashboard: CacheDashboardModel) -> some View {
        HStack(spacing: 14) {
            metricCard("Confirmed hit rate", value: dashboard.hitRateText, icon: "bolt.fill")
            metricCard("Reused input tokens", value: dashboard.reusedInputText, icon: "arrow.triangle.2.circlepath")
            metricCard("Requests with telemetry", value: dashboard.telemetryRequestsText, icon: "tray.full.fill")
            metricCard("Median latency", value: dashboard.medianLatencyText, icon: "timer")
        }
    }

    @ViewBuilder
    private func providerBreakdown(_ dashboard: CacheDashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider & model").font(.system(size: 14, weight: .semibold))
            if dashboard.providerBreakdown.isEmpty {
                Text("No requests recorded yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(dashboard.providerBreakdown, id: \.self) { summary in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.provider.title).font(.system(size: 12.5, weight: .medium))
                            Text(summary.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(summary.confirmedHits) hit · \(summary.confirmedMisses) miss · \(summary.unknownRequests) unknown")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text("\(CacheDashboardModel.grouped(summary.reusedInputTokens)) reused")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
        }
    }

    private func recentRequests(_ dashboard: CacheDashboardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent requests").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Reset Telemetry") { isConfirmingReset = true }
                    .controlSize(.small)
                    .accessibilityLabel("Reset cache telemetry")
            }

            if dashboard.recentLogs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No requests recorded yet.").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    Text("Ask Bluey a question to record real provider usage.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Time").frame(width: 60, alignment: .leading)
                            Text("Provider").frame(width: 105, alignment: .leading)
                            Text("Model").frame(width: 110, alignment: .leading)
                            Text("Status").frame(width: 130, alignment: .leading)
                            Text("Input").frame(width: 55, alignment: .trailing)
                            Text("Reused").frame(width: 60, alignment: .trailing)
                            Text("Output").frame(width: 55, alignment: .trailing)
                            Text("Latency").frame(width: 60, alignment: .trailing)
                            Text("Prefix").frame(width: 115, alignment: .leading)
                        }
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).padding(.bottom, 2)
                        Divider()
                        ForEach(dashboard.recentLogs) { log in
                            HStack(spacing: 6) {
                                Text(log.timestamp, style: .time).frame(width: 60, alignment: .leading)
                                Text(log.provider.title).frame(width: 105, alignment: .leading).lineLimit(1)
                                Text(log.model).frame(width: 110, alignment: .leading).lineLimit(1)
                                Text(dashboard.evidenceLabel(log.usage.evidence))
                                    .frame(width: 130, alignment: .leading)
                                    .lineLimit(1)
                                    .foregroundStyle(statusColor(log.usage.evidence))
                                Text("\(log.usage.totalInputTokens ?? 0)").frame(width: 55, alignment: .trailing)
                                Text("\(log.usage.cachedInputTokens ?? 0)")
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundStyle((log.usage.cachedInputTokens ?? 0) > 0 ? BlueyTheme.success : .secondary)
                                Text("\(log.usage.outputTokens ?? 0)").frame(width: 55, alignment: .trailing)
                                Text("\(log.latencyMs)ms").frame(width: 60, alignment: .trailing)
                                Text(log.prefixVersion).frame(width: 115, alignment: .leading).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            Divider()
                        }
                    }
                    .frame(minWidth: 790, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    /// Calm green only for a confirmed hit; neutral gray otherwise.
    private func statusColor(_ evidence: CacheEvidence) -> Color {
        evidence == .confirmed ? BlueyTheme.success : .secondary
    }

    private func metricCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(BlueyTheme.primary)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
