import Foundation

/// A task result that Bluey's execution state has already verified. Assistant
/// prose is never an outcome; only the agent's terminal state produces one.
public enum VerifiedTaskOutcome: Equatable, Sendable {
    case completed(summary: String)
    case unfinished(summary: String)

    public var summary: String {
        switch self {
        case .completed(let summary), .unfinished(let summary): return summary
        }
    }

    var labeledSummary: String {
        switch self {
        case .completed(let summary): return "Completed: \(summary)"
        case .unfinished(let summary): return "Unfinished: \(summary)"
        }
    }
}

/// A fixed, non-sensitive reason a value was refused. Never carries the value.
public enum SensitiveRejection: String, Equatable, Sendable {
    case apiKey = "api_key"
    case bearerToken = "bearer_token"
    case password = "password"
    case recoveryPhrase = "recovery_phrase"
    case oneTimeCode = "one_time_code"
    case paymentCard = "payment_card"
    case cvvPin = "cvv_pin"
    case governmentID = "government_id"
}

/// A pure, deterministic extractor for explicit user statements only.
///
/// It never receives assistant text. Questions, hypotheticals, quoted or
/// attributed third-party text, and sensitive values are refused before any
/// candidate is produced. Stored content keeps the user's original casing.
public struct ConservativeMemoryExtractor: Sendable {
    public init() {}

    // MARK: - Public entry point

    public func extract(userText: String, verifiedOutcome: VerifiedTaskOutcome? = nil) -> [MemoryCandidate] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [MemoryCandidate] = []

        if !trimmed.isEmpty, sensitiveRejection(in: trimmed) == nil {
            for clause in Self.clauses(in: trimmed) {
                if let candidate = candidate(forClause: clause, userText: trimmed) {
                    candidates.append(candidate)
                }
            }
        }

        if let verifiedOutcome {
            let summary = verifiedOutcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, sensitiveRejection(in: summary) == nil {
                candidates.append(MemoryCandidate(
                    type: .taskOutcome,
                    content: verifiedOutcome.labeledSummary,
                    triggerContext: nil,
                    source: .taskOutcome,
                    confidence: 0.90,
                    replacementKey: nil
                ))
            }
        }

        return candidates
    }

    /// Runs sensitive detection first, as required. Returns only a fixed code.
    public func sensitiveRejection(in text: String) -> SensitiveRejection? {
        for rule in Self.sensitiveRules where rule.regex.firstMatch(in: text) != nil {
            return rule.kind
        }
        return nil
    }

    // MARK: - Candidate construction

    private func candidate(forClause clause: String, userText: String) -> MemoryCandidate? {
        guard !clause.isEmpty, !isExcluded(clause) else { return nil }

        var target = clause
        var wasRememberDirective = false
        if let remainder = Self.rememberRemainder(clause) {
            target = remainder
            wasRememberDirective = true
            guard !target.isEmpty, !isExcluded(target) else { return nil }
        }

        if let candidate = correctionCandidate(in: target, context: userText) { return candidate }
        if let candidate = preferenceCandidate(in: target, context: userText) { return candidate }
        if let candidate = profileCandidate(in: target, context: userText) { return candidate }

        if wasRememberDirective, target.count >= 5, target.count <= 200 {
            return MemoryCandidate(type: .profile, content: target, triggerContext: userText,
                                   source: .explicitProfile, confidence: 0.95, replacementKey: nil)
        }
        return nil
    }

    private func correctionCandidate(in target: String, context: String) -> MemoryCandidate? {
        guard Self.correctionRules.contains(where: { $0.firstMatch(in: target) != nil }) else { return nil }
        let content = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 6, content.count <= 200 else { return nil }
        return MemoryCandidate(type: .lesson, content: content, triggerContext: context,
                               source: .correction, confidence: 0.98, replacementKey: nil)
    }

    private func preferenceCandidate(in target: String, context: String) -> MemoryCandidate? {
        guard Self.preferenceRules.contains(where: { $0.firstMatch(in: target) != nil }) else { return nil }
        let content = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 5, content.count <= 160 else { return nil }
        return MemoryCandidate(type: .preference, content: content, triggerContext: context,
                               source: .explicitPreference, confidence: 0.95,
                               replacementKey: Self.preferenceReplacementKey(for: content))
    }

    private func profileCandidate(in target: String, context: String) -> MemoryCandidate? {
        for rule in Self.profileRules where rule.regex.firstMatch(in: target) != nil {
            let content = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.count >= 5, content.count <= 160 else { return nil }
            return MemoryCandidate(type: .profile, content: content, triggerContext: context,
                                   source: .explicitProfile, confidence: 0.95, replacementKey: rule.key)
        }
        return nil
    }

    // MARK: - Exclusion guards

    private func isExcluded(_ clause: String) -> Bool {
        if clause.hasSuffix("?") { return true }
        if clause.contains("\"") || clause.contains("\u{201C}") || clause.contains("\u{201D}") { return true }
        return Self.exclusionRules.contains { $0.firstMatch(in: clause) != nil }
    }

    // MARK: - Clause splitting

    static func clauses(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func rememberRemainder(_ clause: String) -> String? {
        firstCapture(rememberRule, in: clause)
    }

    // MARK: - Replacement keys

    private static let knownApps = ["safari", "chrome", "firefox", "arc", "brave", "terminal", "xcode"]

    static func preferenceReplacementKey(for text: String) -> String? {
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let apps = knownApps.filter { has("\\b" + $0 + "\\b") }.sorted()
        let scope = apps.isEmpty ? "global" : apps.joined(separator: ",")
        if has(#"\b(dark mode|light mode|theme|appearance)\b"#) { return "preference:appearance:\(scope)" }
        if has(#"\b(markdown|plain text|format)\b"#) { return "preference:format:\(scope)" }
        if has(#"\b(short|concise|detailed|brief|length)\b"#) { return "preference:length:\(scope)" }
        if has(#"\b(voice|daniel|kokoro|puck)\b"#) { return "preference:voice:\(scope)" }
        if apps.count == 1 { return "preference:app:\(apps[0])" }
        if has(#"\b(browser|browsing)\b"#) && !has(#"\b(tabs?|windows?|close|closing|open|opening)\b"#) {
            return "preference:browser-choice"
        }
        return nil
    }

    // MARK: - Compiled rules

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static and known-good; a failure here is a programmer error.
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? NSRegularExpression()
    }

    private static func firstCapture(_ expression: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static let rememberRule = regex(#"^\s*(?:please\s+|kindly\s+)?remember(?:\s+that|\s+this)?\s*:?\s+(.+)$"#)

    private static let exclusionRules: [NSRegularExpression] = [
        regex(#"^\s*(?:if|what if|would|could|should|suppose|supposing|hypothetically|imagine|assuming)\b"#),
        regex(#"\b(?:do you remember|did you remember|can you remember|will you remember|are you remembering|do i remember)\b"#),
        regex(#"\b(?:says|said|wrote|writes|claims|claimed|according to)\b"#),
    ]

    private static let correctionRules: [NSRegularExpression] = [
        regex(#"\b(?:don'?t|do not|never|stop)\s+\S"#),
        regex(#"\bnext time\s+(?:please\s+)?\S"#),
        regex(#"\bin the future\s+(?:please\s+)?\S"#),
        regex(#"\binstead of\s+\S.{1,80}?,\s*(?:do|use|try)\s+\S"#),
        regex(#"\b(?:you (?:made a )?mistake|that'?s wrong|that is wrong|incorrect)[:,]?\s*\S"#),
    ]

    private static let preferenceRules: [NSRegularExpression] = [
        regex(#"\bi prefer\s+\S"#),
        regex(#"\bi like\s+\S"#),
        regex(#"\bmy preference is\s+\S"#),
        regex(#"\balways\s+(?:use|keep|make|answer|reply|respond)\s+\S"#),
        regex(#"\bkeep\s+(?:answers|replies|responses)\s+(?:short|concise|brief|detailed)\b"#),
        regex(#"\buse\s+(?:markdown|plain text|dark mode|light mode|concise|short answers|safari|chrome|firefox|arc|brave|terminal|xcode)\b"#),
    ]

    private static let profileRules: [(key: String, regex: NSRegularExpression)] = [
        ("profile:name", regex(#"\b(?:my name is|my name'?s|name spelling is|call me|i'?m called|i am called)\b"#)),
        ("profile:residence", regex(#"\b(?:i live in|i'?m living in|i am living in|my location is|my city is|my hometown is)\b"#)),
        ("profile:grade", regex(#"\b(?:i'?m in class|i am in class|i'?m in grade|i am in grade|my grade is|my class is)\b"#)),
        ("profile:school", regex(#"\b(?:my school is|i attend school|i go to school)\b"#)),
        ("profile:college", regex(#"\b(?:my college is|i attend college|i go to college)\b"#)),
        ("profile:profession", regex(#"\b(?:i work as|my job is|my profession is)\b"#)),
        ("profile:employer", regex(#"\b(?:i work at|my employer is)\b"#)),
        ("profile:study_subject", regex(#"\b(?:i study|i'?m studying|i am studying|my subject is)\b"#)),
        ("profile:exam", regex(#"\b(?:my exam is|my test is|my exam date is|my test date is)\b"#)),
    ]

    private static let sensitiveRules: [(kind: SensitiveRejection, regex: NSRegularExpression)] = [
        (.apiKey, regex(#"\b(?:sk|pk|rk)[-_](?:live|test|prod)?[-_]?[A-Za-z0-9]{16,}"#)),
        (.apiKey, regex(#"\bAIza[0-9A-Za-z\-_]{30,}"#)),
        (.apiKey, regex(#"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#)),
        (.apiKey, regex(#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#)),
        (.apiKey, regex(#"\bAKIA[0-9A-Z]{16}\b"#)),
        (.bearerToken, regex(#"\bbearer\s+[A-Za-z0-9._\-]{16,}"#)),
        (.password, regex(#"\b(?:password|passwd|pwd)\s*(?:is|:|=)\s*\S+"#)),
        (.recoveryPhrase, regex(#"\b(?:seed|recovery|mnemonic|secret)\s+phrase\b"#)),
        (.recoveryPhrase, regex(#"\bprivate\s+key\b"#)),
        (.recoveryPhrase, regex(#"\b(?:[a-z]{2,10}\s+){11,23}[a-z]{2,10}\b"#)),
        (.oneTimeCode, regex(#"\b(?:otp|one[-\s]?time(?:\s+(?:pass|code|password))?|verification code|authentication code|security code|2fa code|sms code)\b"#)),
        (.paymentCard, regex(#"\b(?:\d[ -]?){13,19}\b"#)),
        (.cvvPin, regex(#"\b(?:cvv|cvc|cvv2)\b"#)),
        (.cvvPin, regex(#"\b(?:card|atm|my)\s+pin\b"#)),
        (.cvvPin, regex(#"\bpin\s*(?:is|number|code|:)\b"#)),
        (.governmentID, regex(#"\b(?:ssn|social security(?: number)?|passport number|aadhaar|aadhar|national id|driver'?s license|license number|tax id)\b"#)),
    ]
}

private extension NSRegularExpression {
    /// Convenience: match against the whole string.
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}
