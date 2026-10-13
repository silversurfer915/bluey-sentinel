import Foundation

/// The category of a stored memory. Kept stable for backward compatibility.
public enum MemoryType: String, CaseIterable, Codable, Sendable {
    case profile = "profile"
    case preference = "preference"
    case taskOutcome = "task_outcome"
    case lesson = "lesson"

    public var title: String {
        switch self {
        case .profile: return "Profile Facts"
        case .preference: return "Preferences"
        case .taskOutcome: return "Task Outcomes"
        case .lesson: return "Learned Lessons"
        }
    }

    public var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .preference: return "slider.horizontal.3"
        case .taskOutcome: return "checkmark.circle"
        case .lesson: return "graduationcap"
        }
    }
}

/// Why and how a memory came to exist. Raw values are the strings persisted in
/// SQLite's `source` column, so they are part of the on-disk contract.
public enum MemorySource: String, CaseIterable, Codable, Sendable {
    case manual = "manual"
    case explicitProfile = "explicit_profile"
    case explicitPreference = "explicit_preference"
    case correction = "correction"
    case taskOutcome = "task_outcome"
    case legacy = "legacy"

    /// A short, safe label for dashboards. Never presented as certainty.
    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .explicitProfile: return "Explicit fact"
        case .explicitPreference: return "Explicit preference"
        case .correction: return "Correction"
        case .taskOutcome: return "Confirmed outcome"
        case .legacy: return "Legacy"
        }
    }
}

/// A single stored memory. New metadata fields are decoded leniently so that
/// records written before schema version 2 still load.
public struct MemoryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var type: MemoryType
    public var content: String
    public var triggerContext: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var source: MemorySource
    public var confidence: Double
    public var replacementKey: String?
    public var isPinned: Bool
    public var recallCount: Int
    public var lastRecalledAt: Date?
    public var lastRecallReason: String?

    /// Confidence assigned to a migrated legacy row, and the fallback default.
    public static let defaultConfidence: Double = 0.80

    public init(id: String = UUID().uuidString,
                type: MemoryType,
                content: String,
                triggerContext: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                source: MemorySource = .legacy,
                confidence: Double = MemoryItem.defaultConfidence,
                replacementKey: String? = nil,
                isPinned: Bool = false,
                recallCount: Int = 0,
                lastRecalledAt: Date? = nil,
                lastRecallReason: String? = nil) {
        self.id = id
        self.type = type
        self.content = content
        self.triggerContext = triggerContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.replacementKey = replacementKey
        self.isPinned = isPinned
        self.recallCount = recallCount
        self.lastRecalledAt = lastRecalledAt
        self.lastRecallReason = lastRecallReason
    }

    enum CodingKeys: String, CodingKey {
        case id, type, content, triggerContext, createdAt, updatedAt
        case source, confidence, replacementKey, isPinned, recallCount, lastRecalledAt, lastRecallReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(MemoryType.self, forKey: .type)
        content = try container.decode(String.self, forKey: .content)
        triggerContext = try container.decodeIfPresent(String.self, forKey: .triggerContext)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decodeIfPresent(MemorySource.self, forKey: .source) ?? .legacy
        let rawConfidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? MemoryItem.defaultConfidence
        confidence = min(max(rawConfidence, 0), 1)
        replacementKey = try container.decodeIfPresent(String.self, forKey: .replacementKey)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        recallCount = try container.decodeIfPresent(Int.self, forKey: .recallCount) ?? 0
        lastRecalledAt = try container.decodeIfPresent(Date.self, forKey: .lastRecalledAt)
        lastRecallReason = try container.decodeIfPresent(String.self, forKey: .lastRecallReason)
    }
}

/// An explicit fact extracted from a user message but not yet persisted.
public struct MemoryCandidate: Equatable, Sendable {
    public let type: MemoryType
    public let content: String
    public let triggerContext: String?
    public let source: MemorySource
    public let confidence: Double
    public let replacementKey: String?

    public init(type: MemoryType,
                content: String,
                triggerContext: String? = nil,
                source: MemorySource,
                confidence: Double,
                replacementKey: String? = nil) {
        self.type = type
        self.content = content
        self.triggerContext = triggerContext
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.replacementKey = replacementKey
    }
}

/// A memory chosen for prompt inclusion, with its score and a short safe reason.
public struct MemoryRecall: Equatable, Sendable {
    public let item: MemoryItem
    public let score: Double
    public let reason: String
    public let estimatedTokens: Int

    public init(item: MemoryItem, score: Double, reason: String, estimatedTokens: Int) {
        self.item = item
        self.score = score
        self.reason = reason
        self.estimatedTokens = estimatedTokens
    }
}

/// Hard limits for how much memory may enter a single prompt.
public struct MemoryPromptBudget: Equatable, Sendable {
    public let maxItems: Int
    public let maxEstimatedTokens: Int

    public init(maxItems: Int = 12, maxEstimatedTokens: Int = 1_200) {
        self.maxItems = maxItems
        self.maxEstimatedTokens = maxEstimatedTokens
    }

    public static let standard = MemoryPromptBudget()
}
