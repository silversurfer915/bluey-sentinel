import Foundation

#if DEBUG
/// Deterministic, privacy-safe fixture data for the debug screenshot harness.
///
/// These constructors are pure: they never touch the shared memory or cache
/// stores, the Keychain, Sanctra, or the network, and contain no real content.
public enum UIPreviewFixtures {
    /// Set only by the debug launch handler; false on every normal launch.
    public static var isActive = false
    public static var reduceMotion = false
    public static var screenshotPath: String?
    public static var requestedPage: String?

    private static var referenceNow: Date { Date() }

    public static var memoryItems: [MemoryItem] {
        let now = referenceNow
        return [
            MemoryItem(id: "preview-optics", type: .profile,
                       content: "Studies wave optics for the physics exam",
                       createdAt: now.addingTimeInterval(-6 * 86_400),
                       updatedAt: now.addingTimeInterval(-2 * 86_400),
                       source: .explicitProfile, confidence: 0.95,
                       replacementKey: "profile:study_subject",
                       recallCount: 4, lastRecalledAt: now.addingTimeInterval(-86_400),
                       lastRecallReason: "Matched wave, optics"),
            MemoryItem(id: "preview-concise", type: .preference,
                       content: "Keep answers concise",
                       createdAt: now.addingTimeInterval(-10 * 86_400),
                       updatedAt: now.addingTimeInterval(-86_400),
                       source: .explicitPreference, confidence: 0.95,
                       replacementKey: "preference:length:global",
                       isPinned: true, recallCount: 7,
                       lastRecalledAt: now.addingTimeInterval(-3_600),
                       lastRecallReason: "Global preference"),
            MemoryItem(id: "preview-terminal", type: .lesson,
                       content: "Never close Terminal during a build",
                       createdAt: now.addingTimeInterval(-9 * 86_400),
                       updatedAt: now.addingTimeInterval(-3 * 86_400),
                       source: .correction, confidence: 0.98,
                       recallCount: 2, lastRecalledAt: now.addingTimeInterval(-2 * 86_400),
                       lastRecallReason: "Matched terminal, build"),
            MemoryItem(id: "preview-long", type: .taskOutcome,
                       content: "Completed: reorganised the downloads folder into subjects and removed twelve duplicate lecture PDFs without touching the originals",
                       createdAt: now.addingTimeInterval(-5 * 86_400),
                       updatedAt: now.addingTimeInterval(-4 * 86_400),
                       source: .taskOutcome, confidence: 0.90),
            MemoryItem(id: "preview-legacy", type: .profile,
                       content: "Uses a standing desk in the afternoons",
                       createdAt: now.addingTimeInterval(-40 * 86_400),
                       updatedAt: now.addingTimeInterval(-30 * 86_400),
                       source: .legacy, confidence: 0.80),
        ]
    }

    public static func memoryModel() -> MemoryDashboardModel {
        MemoryDashboardModel(items: memoryItems)
    }

    public static var cacheLogs: [CacheRequestLog] {
        let now = referenceNow
        return [
            CacheRequestLog(timestamp: now.addingTimeInterval(-60), provider: .deepseek,
                            model: "deepseek-chat", tier: .flagship, prefixVersion: "bluey-prompt-v2",
                            usage: NormalizedTokenUsage(totalInputTokens: 2_400, cachedInputTokens: 1_800,
                                                        uncachedInputTokens: 600, outputTokens: 120,
                                                        evidence: .confirmed, warningCode: nil),
                            latencyMs: 340),
            CacheRequestLog(timestamp: now.addingTimeInterval(-180), provider: .gemini,
                            model: "gemini-3.1-flash-lite", tier: .fast, prefixVersion: "bluey-prompt-v2",
                            usage: NormalizedTokenUsage(totalInputTokens: 1_200, cachedInputTokens: 0,
                                                        uncachedInputTokens: 1_200, outputTokens: 80,
                                                        evidence: .reportedNoHit, warningCode: nil),
                            latencyMs: 210),
            CacheRequestLog(timestamp: now.addingTimeInterval(-300), provider: .custom,
                            model: "local-model", tier: .fast, prefixVersion: "bluey-prompt-v2",
                            usage: NormalizedTokenUsage(totalInputTokens: 900, cachedInputTokens: nil,
                                                        uncachedInputTokens: nil, outputTokens: 40,
                                                        evidence: .usageWithoutCacheField, warningCode: nil),
                            latencyMs: 120),
            CacheRequestLog(timestamp: now.addingTimeInterval(-420), provider: .tokenHarbor,
                            model: "harbor-fast", tier: .fast, prefixVersion: "bluey-prompt-v2",
                            usage: NormalizedTokenUsage(totalInputTokens: nil, cachedInputTokens: nil,
                                                        uncachedInputTokens: nil, outputTokens: nil,
                                                        evidence: .usageUnavailable, warningCode: nil),
                            latencyMs: 95),
        ]
    }

    public static func cacheModel() -> CacheDashboardModel {
        let logs = cacheLogs
        let breakdown = [
            CacheProviderSummary(provider: .deepseek, model: "deepseek-chat",
                                 confirmedHits: 1, confirmedMisses: 0, unknownRequests: 0, reusedInputTokens: 1_800),
            CacheProviderSummary(provider: .gemini, model: "gemini-3.1-flash-lite",
                                 confirmedHits: 0, confirmedMisses: 1, unknownRequests: 0, reusedInputTokens: 0),
            CacheProviderSummary(provider: .custom, model: "local-model",
                                 confirmedHits: 0, confirmedMisses: 0, unknownRequests: 1, reusedInputTokens: 0),
            CacheProviderSummary(provider: .tokenHarbor, model: "harbor-fast",
                                 confirmedHits: 0, confirmedMisses: 0, unknownRequests: 1, reusedInputTokens: 0),
        ]
        let snapshot = CacheDashboardSnapshot(totalRequests: logs.count,
                                              requestsWithCacheTelemetry: 2,
                                              confirmedHitRate: 0.5,
                                              reusedInputTokens: 1_800,
                                              medianLatencyMs: 165,
                                              unknownTelemetryRequests: 2,
                                              providerBreakdown: breakdown,
                                              recentLogs: logs)
        return CacheDashboardModel(snapshot: snapshot)
    }

    public static func workflowProposals() -> [WorkflowSkillProposal] {
        let now = referenceNow
        return [
            WorkflowSkillProposal(revision: 1, title: "Web research · 2 steps",
                                  description: "A web research routine of 2 verified steps, seen 4 times. Bluey still re-observes and verifies each step before acting.",
                                  preconditions: ["Re-observe the current screen before acting", "The destination page must be reachable"],
                                  steps: ["web_research — web", "computer_navigate — browser"],
                                  evidenceCount: 4,
                                  firstSeenAt: now.addingTimeInterval(-12 * 86_400),
                                  lastSeenAt: now.addingTimeInterval(-86_400),
                                  status: .proposed),
            WorkflowSkillProposal(revision: 2, title: "File management · 3 steps",
                                  description: "A file management routine of 3 verified steps, seen 6 times. Bluey still re-observes and verifies each step before acting.",
                                  preconditions: ["Re-observe the current screen before acting", "The referenced workspace files must still exist"],
                                  steps: ["computer_list_files — list", "computer_read_file — read", "computer_write_file — write"],
                                  evidenceCount: 6,
                                  firstSeenAt: now.addingTimeInterval(-20 * 86_400),
                                  lastSeenAt: now.addingTimeInterval(-2 * 86_400),
                                  status: .published),
            WorkflowSkillProposal(revision: 1, title: "Computer use · 2 steps",
                                  description: "A computer use routine of 2 verified steps, seen 3 times.",
                                  preconditions: ["Re-observe the current screen before acting"],
                                  steps: ["computer_snapshot — screen", "computer_click — visible-control"],
                                  evidenceCount: 3,
                                  firstSeenAt: now.addingTimeInterval(-8 * 86_400),
                                  lastSeenAt: now.addingTimeInterval(-3 * 86_400),
                                  status: .paused),
        ]
    }
}
#endif
