import Foundation

/// Deterministic, dependency-free tokenizer for memory recall.
///
/// Lowercases, folds diacritics, splits on non-alphanumerics, removes a fixed
/// English stop-word set, and keeps tokens of two or more characters when they
/// contain a digit or three or more characters otherwise.
public enum MemoryTokenizer {
    public static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "yours", "with", "that", "this", "these", "those",
        "are", "was", "were", "have", "has", "had", "not", "but", "from", "they", "them", "their",
        "will", "would", "can", "could", "should", "about", "into", "over", "under", "then", "than",
        "when", "where", "which", "while", "what", "who", "whom", "how", "why", "all", "any",
        "some", "more", "most", "other", "such", "only", "own", "same", "too", "very", "just",
        "also", "get", "got", "use", "using", "used", "make", "made", "let", "lets", "please",
        "hey", "hello", "hi", "ok", "okay", "yes", "yeah", "nope", "thanks", "thank", "my", "me",
        "i", "we", "our", "us", "he", "she", "it", "its", "his", "her", "been", "being", "do",
        "does", "did", "doing", "if", "or", "as", "at", "by", "in", "of", "on", "to", "up", "out",
        "so", "no", "am", "be", "is", "an", "a",
    ]

    public static func tokenize(_ text: String) -> [String] {
        let folded = text.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var tokens: [String] = []
        for part in folded.components(separatedBy: CharacterSet.alphanumerics.inverted) where !part.isEmpty {
            if stopWords.contains(part) { continue }
            let hasDigit = part.rangeOfCharacter(from: .decimalDigits) != nil
            if hasDigit ? part.count >= 2 : part.count >= 3 {
                tokens.append(part)
            }
        }
        return tokens
    }
}

/// Deterministic local lexical ranking with an explicit, capped prompt budget.
/// No embeddings, no network, no model.
public struct MemoryRetriever: Sendable {
    public init() {}

    /// Named score weights, kept in one place for review.
    public enum Weight {
        public static let exactPhrase = 8.0
        public static let contentToken = 4.0
        public static let triggerToken = 2.0
        public static let lesson = 1.0
        public static let preference = 0.6
        public static let profile = 0.5
        public static let taskOutcome = 0.3
        public static let confidence = 1.0
        public static let pinned = 3.0
        public static let recencyMax = 1.0
        public static let recencyWindowDays = 7.0
    }

    /// Task outcomes leave normal recall after this many days unless pinned or
    /// directly matched by content.
    public static let taskOutcomeExpiryDays = 30.0

    public func retrieve(query: String,
                         items: [MemoryItem],
                         budget: MemoryPromptBudget = .standard,
                         now: Date = Date()) -> [MemoryRecall] {
        let queryTokens = Set(MemoryTokenizer.tokenize(query))
        let normalizedQuery = MemoryTokenizer.tokenize(query).joined(separator: " ")

        var scored: [MemoryRecall] = []
        for item in items {
            if let recall = evaluate(item: item, queryTokens: queryTokens, normalizedQuery: normalizedQuery, now: now) {
                scored.append(recall)
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.updatedAt != rhs.item.updatedAt { return lhs.item.updatedAt > rhs.item.updatedAt }
            return lhs.item.id < rhs.item.id
        }

        return selectWithinBudget(scored, budget: budget)
    }

    // MARK: - Evaluation

    private func evaluate(item: MemoryItem,
                          queryTokens: Set<String>,
                          normalizedQuery: String,
                          now: Date) -> MemoryRecall? {
        let contentTokens = Set(MemoryTokenizer.tokenize(item.content))
        let triggerTokens = Set(MemoryTokenizer.tokenize(item.triggerContext ?? ""))
        let contentOverlap = queryTokens.intersection(contentTokens)
        let triggerOverlap = queryTokens.intersection(triggerTokens)

        let normalizedContent = MemoryTokenizer.tokenize(item.content).joined(separator: " ")
        let normalizedTrigger = MemoryTokenizer.tokenize(item.triggerContext ?? "").joined(separator: " ")
        let exactPhrase = !normalizedQuery.isEmpty
            && (normalizedContent.contains(normalizedQuery) || normalizedTrigger.contains(normalizedQuery))

        let isGlobal = Self.isGlobalPreference(item)
        let ageDays = now.timeIntervalSince(item.updatedAt) / 86_400.0
        let isOldOutcome = item.type == .taskOutcome && !item.isPinned && ageDays > Self.taskOutcomeExpiryDays

        let hasContentMatch = !contentOverlap.isEmpty || exactPhrase
        let hasTriggerMatch = !triggerOverlap.isEmpty

        // Eligibility: pinned always; global preferences always; otherwise a
        // content or trigger match. Old, unmatched task outcomes never qualify.
        let eligible = item.isPinned || isGlobal || hasContentMatch || (hasTriggerMatch && !isOldOutcome)
        guard eligible else { return nil }

        var score = 0.0
        score += Self.typeWeight(item.type)
        score += item.confidence * Weight.confidence
        if exactPhrase { score += Weight.exactPhrase }
        score += Double(contentOverlap.count) * Weight.contentToken
        score += Double(triggerOverlap.count) * Weight.triggerToken
        if item.isPinned { score += Weight.pinned }
        let recency = max(0, Weight.recencyMax - (ageDays / Weight.recencyWindowDays) * Weight.recencyMax)
        score += min(Weight.recencyMax, recency)

        let reason = Self.reason(item: item, exactPhrase: exactPhrase,
                                 contentOverlap: contentOverlap, triggerOverlap: triggerOverlap, isGlobal: isGlobal)
        return MemoryRecall(item: item, score: score, reason: reason, estimatedTokens: Self.estimatedTokens(for: item))
    }

    // MARK: - Selection

    private func selectWithinBudget(_ recalls: [MemoryRecall], budget: MemoryPromptBudget) -> [MemoryRecall] {
        var selected: [MemoryRecall] = []
        var tokens = 0
        for recall in recalls {
            if selected.count >= budget.maxItems { break }
            if tokens + recall.estimatedTokens > budget.maxEstimatedTokens { continue }
            selected.append(recall)
            tokens += recall.estimatedTokens
        }
        return selected
    }

    // MARK: - Helpers

    public static func estimatedTokens(for item: MemoryItem) -> Int {
        let text = item.triggerContext.map { item.content + " " + $0 } ?? item.content
        return max(1, text.utf8.count / 4)
    }

    static func typeWeight(_ type: MemoryType) -> Double {
        switch type {
        case .lesson: return Weight.lesson
        case .preference: return Weight.preference
        case .profile: return Weight.profile
        case .taskOutcome: return Weight.taskOutcome
        }
    }

    static func isGlobalPreference(_ item: MemoryItem) -> Bool {
        guard item.type == .preference, let key = item.replacementKey else { return false }
        return key == "preference:browser-choice" || key.hasSuffix(":global")
    }

    private static func reason(item: MemoryItem,
                               exactPhrase: Bool,
                               contentOverlap: Set<String>,
                               triggerOverlap: Set<String>,
                               isGlobal: Bool) -> String {
        if exactPhrase { return "Exact phrase match" }
        if !contentOverlap.isEmpty { return "Matched " + contentOverlap.sorted().joined(separator: ", ") }
        if !triggerOverlap.isEmpty { return "Matched trigger: " + triggerOverlap.sorted().joined(separator: ", ") }
        if isGlobal { return "Global preference" }
        if item.isPinned { return "Pinned" }
        return "Relevant"
    }
}
