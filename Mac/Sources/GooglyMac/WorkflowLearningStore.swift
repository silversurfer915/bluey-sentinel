import Foundation
import SQLite3

/// A local, WAL-mode SQLite store for normalized workflow observations and
/// owner-reviewed skill proposals. Kept separate from `memory.sqlite`.
public final class WorkflowLearningStore: @unchecked Sendable {
    public static let shared = WorkflowLearningStore()
    public static let schemaVersion: Int32 = 1

    private let queue = DispatchQueue(label: "com.googly.workflowlearning", qos: .utility)
    private var db: OpaquePointer?
    public let databaseURL: URL
    public var onChange: (() -> Void)?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.databaseURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = appSupport.appendingPathComponent("Googly", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.databaseURL = folder.appendingPathComponent("workflow-skills.sqlite")
        }
        queue.sync {
            open()
            configure()
            createSchema()
        }
    }

    deinit {
        queue.sync {
            if let db = self.db { sqlite3_close(db); self.db = nil }
        }
    }

    // MARK: - Setup

    private func open() {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            NSLog("[WorkflowLearningStore] Failed to open database at \(databaseURL.path)")
        }
    }

    private func configure() {
        guard let db = db else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_busy_timeout(db, 3_000)
    }

    private func createSchema() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS workflow_observations (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS workflow_skills (
            id TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_workflow_skills_status ON workflow_skills(status);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[WorkflowLearningStore] Failed to create schema: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_exec(db, "PRAGMA user_version = \(Self.schemaVersion);", nil, nil, nil)
    }

    // MARK: - Observations

    public func recordObservation(_ observation: WorkflowObservation) {
        guard let payload = try? JSONEncoder().encode(observation),
              let json = String(data: payload, encoding: .utf8) else { return }
        executeWrite("INSERT OR REPLACE INTO workflow_observations (id, payload) VALUES (?, ?);",
                     bindings: [UUID().uuidString, json])
    }

    public func observations() -> [WorkflowObservation] {
        queryPayloads("SELECT payload FROM workflow_observations;").compactMap { decode($0) }
    }

    // MARK: - Proposals

    /// Inserts a proposal unless one with the same deterministic id exists.
    public func saveProposal(_ proposal: WorkflowSkillProposal) {
        guard let payload = try? JSONEncoder().encode(proposal),
              let json = String(data: payload, encoding: .utf8) else { return }
        executeWrite("INSERT OR IGNORE INTO workflow_skills (id, status, payload) VALUES (?, ?, ?);",
                     bindings: [proposal.id.uuidString, proposal.status.rawValue, json])
    }

    /// Regenerates proposals from stored observations and keeps existing rows.
    public func refreshProposals(using extractor: WorkflowSkillExtractor) {
        for proposal in extractor.proposals(from: observations()) {
            saveProposal(proposal)
        }
    }

    public func proposals() -> [WorkflowSkillProposal] {
        queryPayloads("SELECT payload FROM workflow_skills ORDER BY status ASC;").compactMap { decode($0) }
    }

    public func publishedSkills() -> [WorkflowSkillProposal] {
        proposals().filter { $0.status == .published }
    }

    public func proposal(id: UUID) -> WorkflowSkillProposal? {
        proposals().first { $0.id == id }
    }

    // MARK: - Owner review lifecycle

    @discardableResult
    public func setStatus(id: UUID, status: WorkflowSkillStatus) -> WorkflowSkillProposal? {
        guard var proposal = proposal(id: id) else { return nil }
        proposal = proposal.withStatus(status)
        replace(proposal)
        return proposal
    }

    /// Owner-triggered publication. There is deliberately no agent/tool path here.
    @discardableResult
    public func publish(id: UUID) -> WorkflowSkillProposal? { setStatus(id: id, status: .published) }
    @discardableResult
    public func reject(id: UUID) -> WorkflowSkillProposal? { setStatus(id: id, status: .rejected) }
    @discardableResult
    public func pause(id: UUID) -> WorkflowSkillProposal? { setStatus(id: id, status: .paused) }
    @discardableResult
    public func resume(id: UUID) -> WorkflowSkillProposal? { setStatus(id: id, status: .published) }

    /// Editing a published or paused skill creates a new proposal revision and
    /// leaves the published revision unchanged until separately approved.
    @discardableResult
    public func editProposal(id: UUID,
                             title: String,
                             description: String,
                             preconditions: [String],
                             steps: [String]) -> WorkflowSkillProposal? {
        guard let existing = proposal(id: id) else { return nil }
        if existing.status == .published || existing.status == .paused {
            let revised = WorkflowSkillProposal(revision: existing.revision + 1,
                                                title: title, description: description,
                                                preconditions: preconditions, steps: steps,
                                                evidenceCount: existing.evidenceCount,
                                                firstSeenAt: existing.firstSeenAt,
                                                lastSeenAt: existing.lastSeenAt,
                                                status: .proposed)
            insert(revised)
            return revised
        }
        let updated = WorkflowSkillProposal(id: existing.id, revision: existing.revision,
                                            title: title, description: description,
                                            preconditions: preconditions, steps: steps,
                                            evidenceCount: existing.evidenceCount,
                                            firstSeenAt: existing.firstSeenAt,
                                            lastSeenAt: existing.lastSeenAt,
                                            status: existing.status)
        replace(updated)
        return updated
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        executeWrite("DELETE FROM workflow_skills WHERE id = ?;", bindings: [id.uuidString])
        return proposal(id: id) == nil
    }

    public func reset() {
        executeWrite("DELETE FROM workflow_observations;", bindings: [])
        executeWrite("DELETE FROM workflow_skills;", bindings: [])
    }

    /// Diagnostic helper: every serialized payload, for privacy assertions.
    func rawPayloads() -> [String] {
        queryPayloads("SELECT payload FROM workflow_observations;")
            + queryPayloads("SELECT payload FROM workflow_skills;")
    }

    // MARK: - SQLite helpers

    private func insert(_ proposal: WorkflowSkillProposal) {
        saveProposal(proposal)
    }

    private func replace(_ proposal: WorkflowSkillProposal) {
        guard let payload = try? JSONEncoder().encode(proposal),
              let json = String(data: payload, encoding: .utf8) else { return }
        executeWrite("INSERT OR REPLACE INTO workflow_skills (id, status, payload) VALUES (?, ?, ?);",
                     bindings: [proposal.id.uuidString, proposal.status.rawValue, json])
    }

    private func decode<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func queryPayloads(_ sql: String) -> [String] {
        var results: [String] = []
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let value = sqlite3_column_text(statement, 0) {
                        results.append(String(cString: value))
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        return results
    }

    private func executeWrite(_ sql: String, bindings: [String]) {
        var committed = false
        queue.sync {
            guard let db = db else { return }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, value) in bindings.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, nil)
                }
                committed = sqlite3_step(statement) == SQLITE_DONE
                if !committed {
                    NSLog("[WorkflowLearningStore] Write failed: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(statement)
        }
        if committed {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }
}
