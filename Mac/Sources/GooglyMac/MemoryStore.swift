import Foundation
import SQLite3

public enum MemoryType: String, CaseIterable, Codable {
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

public struct MemoryItem: Identifiable, Codable, Equatable {
    public var id: String
    public var type: MemoryType
    public var content: String
    public var triggerContext: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                type: MemoryType,
                content: String,
                triggerContext: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.type = type
        self.content = content
        self.triggerContext = triggerContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A thread-safe, local, zero-dependency SQLite memory store for Bluey.
/// Persists facts, preferences, task outcomes, and learned lessons across app restarts.
public final class MemoryStore: @unchecked Sendable {
    public static let shared = MemoryStore()

    private let dbQueue = DispatchQueue(label: "com.googly.memorystore", qos: .userInitiated)
    private var db: OpaquePointer?
    public let databaseURL: URL
    public var onChange: (() -> Void)?

    public init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.databaseURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = appSupport.appendingPathComponent("Googly", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.databaseURL = folder.appendingPathComponent("memory.sqlite")
        }
        dbQueue.sync {
            openDatabase()
            createSchema()
        }
        deduplicateExistingMemories()
    }

    deinit {
        dbQueue.sync {
            if let db = self.db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    // MARK: - SQLite Setup

    private func openDatabase() {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to open database at \(databaseURL.path)")
        }
    }

    private func createSchema() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            trigger_context TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type);
        CREATE INDEX IF NOT EXISTS idx_memories_created_at ON memories(created_at);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            NSLog("[MemoryStore] Failed to create schema: \(errmsg)")
        }
    }

    // MARK: - CRUD Operations

    @discardableResult
    public func add(type: MemoryType, content: String, triggerContext: String? = nil) -> MemoryItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = MemoryItem(type: type, content: trimmed, triggerContext: triggerContext)
        save(item)
        return item
    }

    // MARK: - Deduplication & Memory Replacement

    /// Adds a new memory item or updates an existing related memory if the information modifies or corrects prior facts.
    @discardableResult
    public func addOrUpdate(type: MemoryType, content: String, triggerContext: String? = nil) -> MemoryItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MemoryItem(type: type, content: "", triggerContext: triggerContext)
        }

        let existing = memories(of: type)
        if let match = findRelatedMemory(in: existing, newContent: trimmed, type: type) {
            // Update existing memory in-place with the latest information
            var updated = match
            updated.content = trimmed
            updated.updatedAt = Date()
            if let ctx = triggerContext, !ctx.isEmpty {
                updated.triggerContext = ctx
            }
            save(updated)

            // Remove any other older duplicates matching this same topic
            for other in existing where other.id != match.id && isRelated(a: other.content, b: trimmed, type: type) {
                delete(id: other.id)
            }
            return updated
        }

        // No related memory exists: create a new one
        return add(type: type, content: trimmed, triggerContext: triggerContext)
    }

    /// Finds an existing memory that covers the same topic or property and should be updated.
    public func findRelatedMemory(in items: [MemoryItem], newContent: String, type: MemoryType) -> MemoryItem? {
        return items.first { isRelated(a: $0.content, b: newContent, type: type) }
    }

    /// Determines whether two memory texts discuss the same topic or property and should update/replace each other.
    public func isRelated(a: String, b: String, type: MemoryType) -> Bool {
        let cleanA = a.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanB = b.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanA == cleanB { return true }

        let stripPrefix = { (s: String) -> String in
            var text = s
            let prefixes = [
                "completed: ", "unfinished task: ", "unfinished: ", "correction received: ",
                "please remember that ", "remember that ", "my ", "i am ", "i'm "
            ]
            for p in prefixes {
                if text.hasPrefix(p) { text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return text
        }
        let strippedA = stripPrefix(cleanA)
        let strippedB = stripPrefix(cleanB)

        // 1. Semantic Topic Matchers
        // Name
        let isName = { (s: String) -> Bool in
            s.contains("name") || s.contains("called") || s.contains("call me") || s.contains("spelling")
        }
        if isName(cleanA) && isName(cleanB) { return true }

        // Location / Residence
        let isLocation = { (s: String) -> Bool in
            s.contains("live in") || s.contains("living in") || s.contains("location") || s.contains("city") || s.contains("coimbatore") || s.contains("bangalore") || s.contains("chennai") || s.contains("hometown")
        }
        if isLocation(cleanA) && isLocation(cleanB) { return true }

        // Class / School / Grade / Study Subject
        let isClassOrSchool = { (s: String) -> Bool in
            s.contains("class") || s.contains("grade") || s.contains("school") || s.contains("college") || s.contains("studying")
        }
        if isClassOrSchool(cleanA) && isClassOrSchool(cleanB) { return true }

        // Profession / Role
        let isJob = { (s: String) -> Bool in
            s.contains("work as") || s.contains("work at") || s.contains("job") || s.contains("developer") || s.contains("engineer") || s.contains("student")
        }
        if isJob(cleanA) && isJob(cleanB) { return true }

        // Preference categories (e.g. browser, theme, model, voice)
        if type == .preference {
            let prefCategories = [
                ["safari", "chrome", "firefox", "arc", "brave", "browser"],
                ["dark mode", "light mode", "theme", "appearance"],
                ["markdown", "plain text", "format"],
                ["short", "concise", "detailed", "brief", "length"],
                ["daniel", "kokoro", "puck", "voice"]
            ]
            for group in prefCategories {
                let aMatches = group.contains { cleanA.contains($0) }
                let bMatches = group.contains { cleanB.contains($0) }
                if aMatches && bMatches { return true }
            }
        }

        // Lessons: check matching trigger context or action target
        if type == .lesson {
            let actionWords = ["terminal", "safari", "chrome", "tab", "click", "window", "close", "delete", "quit"]
            for action in actionWords {
                if cleanA.contains(action) && cleanB.contains(action) { return true }
            }
        }

        // 2. High Token Overlap (Jaccard similarity on core keywords)
        let stopWords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "for", "are", "was",
            "were", "been", "have", "has", "had", "please", "remember", "completed",
            "you", "your", "i'm", "i've", "when", "will", "would", "could", "should"
        ]
        let tokensA = Set(strippedA.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) })
        let tokensB = Set(strippedB.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) })

        guard !tokensA.isEmpty && !tokensB.isEmpty else { return false }
        let common = tokensA.intersection(tokensB)
        let union = tokensA.union(tokensB)
        let jaccard = Double(common.count) / Double(union.count)

        if common.count >= 2 || jaccard >= 0.35 {
            return true
        }

        return false
    }

    /// Scans existing database and unifies any duplicates created previously.
    public func deduplicateExistingMemories() {
        for type in MemoryType.allCases {
            let items = memories(of: type)
            var kept: [MemoryItem] = []
            for item in items {
                if kept.contains(where: { isRelated(a: $0.content, b: item.content, type: type) }) {
                    delete(id: item.id)
                } else {
                    kept.append(item)
                }
            }
        }
    }

    public func save(_ item: MemoryItem) {
        dbQueue.sync {
            guard let db = db else { return }
            let sql = """
            INSERT OR REPLACE INTO memories (id, type, content, trigger_context, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (item.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (item.type.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (item.content as NSString).utf8String, -1, nil)
                if let ctx = item.triggerContext {
                    sqlite3_bind_text(statement, 4, (ctx as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                sqlite3_bind_double(statement, 5, item.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 6, item.updatedAt.timeIntervalSince1970)

                if sqlite3_step(statement) != SQLITE_DONE {
                    let errmsg = String(cString: sqlite3_errmsg(db))
                    NSLog("[MemoryStore] Save failed: \(errmsg)")
                }
            }
            sqlite3_finalize(statement)
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    @discardableResult
    public func update(id: String, content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var success = false
        dbQueue.sync {
            guard let db = db else { return }
            let sql = "UPDATE memories SET content = ?, updated_at = ? WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (trimmed as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(statement, 3, (id as NSString).utf8String, -1, nil)
                success = sqlite3_step(statement) == SQLITE_DONE
            }
            sqlite3_finalize(statement)
        }
        if success {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        return success
    }

    @discardableResult
    public func delete(id: String) -> Bool {
        var success = false
        dbQueue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM memories WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                success = sqlite3_step(statement) == SQLITE_DONE
            }
            sqlite3_finalize(statement)
        }
        if success {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        return success
    }

    @discardableResult
    public func forgetEverything() -> Bool {
        var success = false
        dbQueue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM memories;"
            success = sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
        if success {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        return success
    }

    // MARK: - Querying

    public func all() -> [MemoryItem] {
        return allMemories()
    }

    public func allMemories() -> [MemoryItem] {
        return query("SELECT id, type, content, trigger_context, created_at, updated_at FROM memories ORDER BY created_at DESC;")
    }

    public func memories(of type: MemoryType) -> [MemoryItem] {
        return query("SELECT id, type, content, trigger_context, created_at, updated_at FROM memories WHERE type = ? ORDER BY created_at DESC;", bindings: [type.rawValue])
    }

    public func search(query text: String) -> [MemoryItem] {
        let pattern = "%\(text.trimmingCharacters(in: .whitespacesAndNewlines))%"
        return query("""
        SELECT id, type, content, trigger_context, created_at, updated_at
        FROM memories
        WHERE content LIKE ? OR trigger_context LIKE ?
        ORDER BY updated_at DESC;
        """, bindings: [pattern, pattern])
    }

    private func query(_ sql: String, bindings: [String] = []) -> [MemoryItem] {
        var results: [MemoryItem] = []
        dbQueue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, val) in bindings.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), (val as NSString).utf8String, -1, nil)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(statement, 0))
                    let rawType = String(cString: sqlite3_column_text(statement, 1))
                    let content = String(cString: sqlite3_column_text(statement, 2))
                    var context: String? = nil
                    if let cStr = sqlite3_column_text(statement, 3) {
                        context = String(cString: cStr)
                    }
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    let type = MemoryType(rawValue: rawType) ?? .profile
                    results.append(MemoryItem(id: id, type: type, content: content, triggerContext: context, createdAt: createdAt, updatedAt: updatedAt))
                }
            }
            sqlite3_finalize(statement)
        }
        return results
    }

    // MARK: - Context Retrieval & Ranking

    /// Retrieves relevant memories to inject into system prompt before a conversation/task.
    /// Prioritizes lessons (so corrections are never forgotten!), profile facts, and keyword-matched items.
    public func retrieveRelevant(query prompt: String, limit: Int = 14) -> [MemoryItem] {
        let all = allMemories()
        guard !all.isEmpty else { return [] }

        let queryTokens = Set(prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })

        // Score each memory
        var scored: [(item: MemoryItem, score: Double)] = []
        for item in all {
            var score = 0.0

            // Lessons carry highest base priority
            switch item.type {
            case .lesson:
                score += 5.0
            case .preference:
                score += 3.0
            case .profile:
                score += 2.5
            case .taskOutcome:
                score += 1.0
            }

            // Keyword match boost
            let itemTokens = Set(item.content.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 })
            let overlap = queryTokens.intersection(itemTokens)
            score += Double(overlap.count) * 4.0

            if let ctx = item.triggerContext {
                let ctxTokens = Set(ctx.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 })
                let ctxOverlap = queryTokens.intersection(ctxTokens)
                score += Double(ctxOverlap.count) * 3.0
            }

            // Recency boost (within last 7 days gets up to +1.0)
            let ageDays = Date().timeIntervalSince(item.updatedAt) / 86400.0
            if ageDays < 7 {
                score += max(0, 1.0 - (ageDays / 7.0))
            }

            scored.append((item, score))
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit).map { $0.item })
    }

    /// Formats memories into structured text ready for injection into the system prompt.
    public func formatPromptContext(for prompt: String) -> String {
        let items = retrieveRelevant(query: prompt)
        guard !items.isEmpty else { return "" }

        var sections: [String] = []
        sections.append("--- PERSISTENT LONG-TERM MEMORY & LEARNED LESSONS ---")
        sections.append("These are verified facts, user preferences, and critical lessons learned from past user corrections. Strictly adhere to them.")

        let lessons = items.filter { $0.type == .lesson }
        if !lessons.isEmpty {
            sections.append("\n[CRITICAL LESSONS & CORRECTIONS - NEVER REPEAT THESE MISTAKES]:")
            for l in lessons {
                if let ctx = l.triggerContext, !ctx.isEmpty {
                    sections.append("• When \(ctx): \(l.content)")
                } else {
                    sections.append("• \(l.content)")
                }
            }
        }

        let preferences = items.filter { $0.type == .preference }
        if !preferences.isEmpty {
            sections.append("\n[USER PREFERENCES]:")
            for p in preferences {
                sections.append("• \(p.content)")
            }
        }

        let profileFacts = items.filter { $0.type == .profile }
        if !profileFacts.isEmpty {
            sections.append("\n[USER PROFILE FACTS]:")
            for f in profileFacts {
                sections.append("• \(f.content)")
            }
        }

        let outcomes = items.filter { $0.type == .taskOutcome }
        if !outcomes.isEmpty {
            sections.append("\n[RECENT TASK OUTCOMES]:")
            for o in outcomes.prefix(3) {
                sections.append("• \(o.content)")
            }
        }

        sections.append("-------------------------------------------------------")
        return sections.joined(separator: "\n")
    }

    // MARK: - Learning & Memory Extraction

    /// Extracts facts, preferences, corrections, and lessons from a turn and saves or updates them.
    @discardableResult
    public func extractMemories(userPrompt: String, assistantReply: String, taskOutcome: String? = nil) -> [MemoryItem] {
        var created: [MemoryItem] = []

        // 1. Correction / Negative Feedback Detection -> Learned Lesson
        // Examples: "Don't click that", "Never close Terminal", "Stop opening tabs",
        // "Next time use Safari", "You made a mistake: do X instead"
        let correctionPatterns = [
            "(?:don't|do not|never|stop)\\s+([a-zA-Z0-9\\s,–-]+)",
            "(?:next time|in the future)\\s+(?:please\\s+)?([a-zA-Z0-9\\s,–-]+)",
            "(?:instead of|rather than)\\s+([a-zA-Z0-9\\s,–-]+),\\s*(?:do\\s+|use\\s+)?([a-zA-Z0-9\\s,–-]+)",
            "(?:wrong|mistake|incorrect)[:,]?\\s+([a-zA-Z0-9\\s,–-]+)"
        ]

        for pattern in correctionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(userPrompt.startIndex..<userPrompt.endIndex, in: userPrompt)
                if let match = regex.firstMatch(in: userPrompt, options: [], range: range) {
                    let matchedText = (userPrompt as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if matchedText.count > 6 && matchedText.count < 140 {
                        let lesson = addOrUpdate(type: .lesson, content: "Correction received: \"\(matchedText)\". Never repeat this mistake.", triggerContext: userPrompt)
                        created.append(lesson)
                        break
                    }
                }
            }
        }

        // 2. Explicit User Preferences
        // Examples: "I prefer dark mode", "I like Safari", "Always use markdown", "Keep answers short"
        let prefPatterns = [
            "i prefer ([a-zA-Z0-9\\s,–-]+)",
            "i like ([a-zA-Z0-9\\s,–-]+)",
            "always (?:use |keep |make )([a-zA-Z0-9\\s,–-]+)",
            "my preference is ([a-zA-Z0-9\\s,–-]+)"
        ]
        for pattern in prefPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(userPrompt.startIndex..<userPrompt.endIndex, in: userPrompt)
                if let match = regex.firstMatch(in: userPrompt, options: [], range: range) {
                    let matchedText = (userPrompt as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if matchedText.count > 5 && matchedText.count < 120 {
                        let pref = addOrUpdate(type: .preference, content: matchedText.capitalizedSentence, triggerContext: userPrompt)
                        created.append(pref)
                    }
                }
            }
        }

        // 3. User Profile Facts (Supports single and compound clauses separated by 'and' or commas)
        // Examples: "My name spelling is HARWESH", "I live in Coimbatore", "I'm in class 12", "My name is Harish"
        let factPatterns = [
            "my name is ([a-zA-Z0-9\\s]+)",
            "name spelling is ([a-zA-Z0-9\\s]+)",
            "my name spelling is ([a-zA-Z0-9\\s]+)",
            "call me ([a-zA-Z0-9\\s]+)",
            "i am studying ([a-zA-Z0-9\\s]+)",
            "i'm studying ([a-zA-Z0-9\\s]+)",
            "i live in ([a-zA-Z0-9\\s]+)",
            "my location is ([a-zA-Z0-9\\s]+)",
            "i'm in class ([a-zA-Z0-9\\s]+)",
            "i am in class ([a-zA-Z0-9\\s]+)",
            "i work as ([a-zA-Z0-9\\s]+)",
            "i work at ([a-zA-Z0-9\\s]+)",
            "i am a ([a-zA-Z0-9\\s]+)"
        ]

        // Split compound sentences ("I live in Coimbatore and my name is Harish and I'm in class 12")
        let cleanPrompt = userPrompt.replacingOccurrences(of: "(?i)please remember that\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)remember that\\s+", with: "", options: .regularExpression)
        let clauses = cleanPrompt.components(separatedBy: " and ")

        for clause in clauses {
            let trimmedClause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in factPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(trimmedClause.startIndex..<trimmedClause.endIndex, in: trimmedClause)
                    if let match = regex.firstMatch(in: trimmedClause, options: [], range: range) {
                        let matchedText = (trimmedClause as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                        if matchedText.count > 4 && matchedText.count < 100 {
                            let fact = addOrUpdate(type: .profile, content: matchedText.capitalizedSentence, triggerContext: userPrompt)
                            created.append(fact)
                            break
                        }
                    }
                }
            }
        }

        // 4. Fallback explicit "remember that ..." directives if no specific fact regex matched
        if created.isEmpty {
            let rememberPatterns = [
                "(?:please\\s+)?remember that\\s+([a-zA-Z0-9\\s,–-]+)"
            ]
            for pattern in rememberPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(userPrompt.startIndex..<userPrompt.endIndex, in: userPrompt)
                    if let match = regex.firstMatch(in: userPrompt, options: [], range: range), match.numberOfRanges > 1 {
                        let factText = (userPrompt as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if factText.count > 5 && factText.count < 120 {
                            let fact = addOrUpdate(type: .profile, content: factText.capitalizedSentence, triggerContext: userPrompt)
                            created.append(fact)
                        }
                    }
                }
            }
        }

        // 5. Task Outcome (only for actual tasks, not conversational chat)
        if let outcome = taskOutcome, !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let taskItem = addOrUpdate(type: .taskOutcome, content: outcome.trimmingCharacters(in: .whitespacesAndNewlines), triggerContext: userPrompt)
            created.append(taskItem)
        }

        return created
    }
}

private extension String {
    var capitalizedSentence: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
