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

    /// Extracts facts, preferences, corrections, and lessons from a turn and saves them.
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
                        let lesson = add(type: .lesson, content: "Correction received: \"\(matchedText)\". Never repeat this mistake.", triggerContext: userPrompt)
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
                        let pref = add(type: .preference, content: matchedText.capitalizedSentence, triggerContext: userPrompt)
                        created.append(pref)
                    }
                }
            }
        }

        // 3. User Profile Facts
        // Examples: "My name is Hareesh", "I am studying wave optics", "I work on iOS", "I am a developer"
        let factPatterns = [
            "my name is ([a-zA-Z0-9\\s]+)",
            "i am studying ([a-zA-Z0-9\\s]+)",
            "i'm studying ([a-zA-Z0-9\\s]+)",
            "i work as ([a-zA-Z0-9\\s]+)",
            "i am a ([a-zA-Z0-9\\s]+)"
        ]
        for pattern in factPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(userPrompt.startIndex..<userPrompt.endIndex, in: userPrompt)
                if let match = regex.firstMatch(in: userPrompt, options: [], range: range) {
                    let matchedText = (userPrompt as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if matchedText.count > 5 && matchedText.count < 100 {
                        let fact = add(type: .profile, content: matchedText.capitalizedSentence, triggerContext: userPrompt)
                        created.append(fact)
                    }
                }
            }
        }

        // 4. Task Outcome
        if let outcome = taskOutcome, !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let taskItem = add(type: .taskOutcome, content: outcome.trimmingCharacters(in: .whitespacesAndNewlines), triggerContext: userPrompt)
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
