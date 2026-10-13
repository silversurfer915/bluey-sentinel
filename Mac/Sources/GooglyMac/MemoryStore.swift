import Foundation
import SQLite3

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
            migrateSchema()
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

    /// The on-disk schema version this build writes.
    public static let schemaVersion: Int32 = 2

    /// Every column, in decode order, shared by the read queries.
    private static let selectColumns = """
    id, type, content, trigger_context, created_at, updated_at, \
    source, confidence, replacement_key, is_pinned, recall_count, last_recalled_at, last_recall_reason
    """

    private func openDatabase() {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to open database at \(databaseURL.path)")
        }
    }

    /// Creates the version-2 schema, migrating and backing up an existing
    /// version-1 database without deleting any row. Idempotent across relaunches.
    private func migrateSchema() {
        guard let db = db else { return }
        let version = userVersion(db)
        let existingTable = tableExists("memories", db: db)

        if version >= Self.schemaVersion {
            createSchemaStatements(db)
            return
        }

        if version == 0 && !existingTable {
            // A brand-new database: create the full version-2 schema directly.
            createSchemaStatements(db)
            setUserVersion(Self.schemaVersion, db: db)
            return
        }

        // An existing version-1 (or unversioned) database: back up, then migrate
        // inside a single immediate transaction.
        backupVersion1Database()
        if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Could not begin migration transaction")
            return
        }
        addColumnIfMissing("source", definition: "TEXT NOT NULL DEFAULT 'legacy'", db: db)
        addColumnIfMissing("confidence", definition: "REAL NOT NULL DEFAULT 0.80", db: db)
        addColumnIfMissing("replacement_key", definition: "TEXT", db: db)
        addColumnIfMissing("is_pinned", definition: "INTEGER NOT NULL DEFAULT 0", db: db)
        addColumnIfMissing("recall_count", definition: "INTEGER NOT NULL DEFAULT 0", db: db)
        addColumnIfMissing("last_recalled_at", definition: "REAL", db: db)
        addColumnIfMissing("last_recall_reason", definition: "TEXT", db: db)
        createIndexStatements(db)
        setUserVersion(Self.schemaVersion, db: db)
        if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Migration commit failed; rolling back")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
    }

    private func createSchemaStatements(_ db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            trigger_context TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            source TEXT NOT NULL DEFAULT 'legacy',
            confidence REAL NOT NULL DEFAULT 0.80,
            replacement_key TEXT,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            recall_count INTEGER NOT NULL DEFAULT 0,
            last_recalled_at REAL,
            last_recall_reason TEXT
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to create schema: \(String(cString: sqlite3_errmsg(db)))")
        }
        createIndexStatements(db)
    }

    private func createIndexStatements(_ db: OpaquePointer) {
        let sql = """
        CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type);
        CREATE INDEX IF NOT EXISTS idx_memories_created_at ON memories(created_at);
        CREATE INDEX IF NOT EXISTS idx_memories_updated_at ON memories(updated_at);
        CREATE INDEX IF NOT EXISTS idx_memories_replacement_key ON memories(replacement_key);
        CREATE INDEX IF NOT EXISTS idx_memories_last_recalled_at ON memories(last_recalled_at);
        CREATE INDEX IF NOT EXISTS idx_memories_type_pinned ON memories(type, is_pinned);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to create indexes: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Uses SQLite's backup API so an open database (including any WAL/journal)
    /// is captured consistently. Never overwrites an existing backup.
    private func backupVersion1Database() {
        let backupURL = databaseURL.appendingPathExtension("v1-backup")
        if FileManager.default.fileExists(atPath: backupURL.path) { return }
        guard let source = db else { return }

        var destination: OpaquePointer?
        if sqlite3_open(backupURL.path, &destination) != SQLITE_OK {
            NSLog("[MemoryStore] Could not open migration backup at \(backupURL.path)")
            sqlite3_close(destination)
            return
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            NSLog("[MemoryStore] Could not start migration backup")
            return
        }
        sqlite3_backup_step(backup, -1)
        if sqlite3_backup_finish(backup) != SQLITE_OK {
            NSLog("[MemoryStore] Migration backup did not finish cleanly")
        }
    }

    private func userVersion(_ db: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    private func setUserVersion(_ version: Int32, db: OpaquePointer) {
        let sql = "PRAGMA user_version = \(version);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to set user_version")
        }
    }

    private func tableExists(_ name: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        var found = false
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            found = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        return found
    }

    private func tableColumns(_ db: OpaquePointer) -> Set<String> {
        var columns: Set<String> = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(memories);", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: name))
                }
            }
        }
        sqlite3_finalize(statement)
        return columns
    }

    private func addColumnIfMissing(_ name: String, definition: String, db: OpaquePointer) {
        guard !tableColumns(db).contains(name) else { return }
        let sql = "ALTER TABLE memories ADD COLUMN \(name) \(definition);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[MemoryStore] Failed to add column \(name): \(String(cString: sqlite3_errmsg(db)))")
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
        // Shared vocabulary is not proof that one fact supersedes another. Only a
        // recognized single property can replace a different value automatically.
        guard let propertyA = replacementProperty(cleanA, type: type),
              let propertyB = replacementProperty(cleanB, type: type) else { return false }
        return propertyA == propertyB
    }

    private func replacementProperty(_ text: String, type: MemoryType) -> String? {
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if type == .profile {
            if matches(#"\b(my name|name spelling|call me|i am called)\b"#) { return "name" }
            if matches(#"\b(i live in|i am living in|my location|my city|my hometown)\b"#) { return "residence" }
            if matches(#"\b(in class|in grade|my grade|my class is)\b"#) { return "grade" }
            if matches(#"\b(my school|school is|attend school)\b"#) { return "school" }
            if matches(#"\b(my college|college is|attend college)\b"#) { return "college" }
            if matches(#"\b(i work as|my job|my profession)\b"#) { return "profession" }
            if matches(#"\b(i work at|my employer)\b"#) { return "employer" }
            return nil
        }
        guard type == .preference else { return nil }
        let apps = ["safari", "chrome", "firefox", "arc", "brave", "terminal", "xcode"]
        let appScope = apps.filter { app in
            text.range(of: "\\b" + app + "\\b", options: .regularExpression) != nil
        }.sorted().joined(separator: ",")
        let scope = appScope.isEmpty ? "global" : appScope
        if matches(#"\b(dark mode|light mode|theme|appearance)\b"#) { return "appearance:" + scope }
        if matches(#"\b(markdown|plain text|format)\b"#) { return "format:" + scope }
        if matches(#"\b(short|concise|detailed|brief|length)\b"#) { return "length:" + scope }
        if matches(#"\b(voice|daniel|kokoro|puck)\b"#) { return "voice:" + scope }
        if matches(#"\b(browser|browsing)\b"#) && !matches(#"\b(tabs?|windows?|close|closing|open|opening)\b"#) {
            return "browser-choice"
        }
        return nil
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
            INSERT OR REPLACE INTO memories
                (id, type, content, trigger_context, created_at, updated_at,
                 source, confidence, replacement_key, is_pinned, recall_count, last_recalled_at, last_recall_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                sqlite3_bind_text(statement, 7, (item.source.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 8, item.confidence)
                if let key = item.replacementKey {
                    sqlite3_bind_text(statement, 9, (key as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                sqlite3_bind_int(statement, 10, item.isPinned ? 1 : 0)
                sqlite3_bind_int(statement, 11, Int32(item.recallCount))
                if let recalled = item.lastRecalledAt {
                    sqlite3_bind_double(statement, 12, recalled.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 12)
                }
                if let reason = item.lastRecallReason {
                    sqlite3_bind_text(statement, 13, (reason as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 13)
                }

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

    /// Pins or unpins a memory without changing its content or `updatedAt`.
    @discardableResult
    public func setPinned(id: String, isPinned: Bool) -> Bool {
        var success = false
        dbQueue.sync {
            guard let db = db else { return }
            let sql = "UPDATE memories SET is_pinned = ? WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, isPinned ? 1 : 0)
                sqlite3_bind_text(statement, 2, (id as NSString).utf8String, -1, nil)
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
        return query("SELECT \(Self.selectColumns) FROM memories ORDER BY updated_at DESC, created_at DESC, id ASC;")
    }

    public func memories(of type: MemoryType) -> [MemoryItem] {
        return query("SELECT \(Self.selectColumns) FROM memories WHERE type = ? ORDER BY updated_at DESC, created_at DESC, id ASC;", bindings: [type.rawValue])
    }

    public func search(query text: String) -> [MemoryItem] {
        let pattern = "%\(text.trimmingCharacters(in: .whitespacesAndNewlines))%"
        return query("""
        SELECT \(Self.selectColumns)
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
                    if let item = Self.decode(statement) { results.append(item) }
                }
            }
            sqlite3_finalize(statement)
        }
        return results
    }

    /// Decodes a row selected with `selectColumns`, tolerating nulls and unknown
    /// enum values from older writes.
    private static func decode(_ statement: OpaquePointer?) -> MemoryItem? {
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }

        guard let id = text(0), let rawType = text(1), let content = text(2) else { return nil }
        let type = MemoryType(rawValue: rawType) ?? .profile
        let source = text(6).flatMap(MemorySource.init(rawValue:)) ?? .legacy
        return MemoryItem(
            id: id,
            type: type,
            content: content,
            triggerContext: text(3),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            source: source,
            confidence: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? MemoryItem.defaultConfidence : sqlite3_column_double(statement, 7),
            replacementKey: text(8),
            isPinned: sqlite3_column_int(statement, 9) != 0,
            recallCount: Int(sqlite3_column_int(statement, 10)),
            lastRecalledAt: sqlite3_column_type(statement, 11) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            lastRecallReason: text(12)
        )
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
