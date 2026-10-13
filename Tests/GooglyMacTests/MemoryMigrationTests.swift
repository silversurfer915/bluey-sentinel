import XCTest
import SQLite3
@testable import GooglyMac

/// Covers the version-1 to version-2 memory schema migration, the new
/// `MemoryItem` metadata defaults, and `MemorySource` coding.
final class MemoryMigrationTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_migration_\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: backupURL)
        super.tearDown()
    }

    private var backupURL: URL { tempURL.appendingPathExtension("v1-backup") }

    // MARK: - Model compatibility

    func testOldMemoryItemJSONDecodesWithLegacyDefaults() throws {
        let json = """
        {"id":"a","type":"profile","content":"My name is Test","createdAt":1000,"updatedAt":2000}
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(MemoryItem.self, from: json)

        XCTAssertEqual(item.id, "a")
        XCTAssertEqual(item.type, .profile)
        XCTAssertEqual(item.source, .legacy)
        XCTAssertEqual(item.confidence, 0.80, accuracy: 0.0001)
        XCTAssertFalse(item.isPinned)
        XCTAssertEqual(item.recallCount, 0)
        XCTAssertNil(item.replacementKey)
        XCTAssertNil(item.lastRecalledAt)
        XCTAssertNil(item.lastRecallReason)
    }

    func testConfidenceValuesClampIntoUnitRange() {
        XCTAssertEqual(MemoryItem(type: .profile, content: "x", confidence: 5.0).confidence, 1.0)
        XCTAssertEqual(MemoryItem(type: .profile, content: "x", confidence: -3.0).confidence, 0.0)
        XCTAssertEqual(MemoryItem(type: .profile, content: "x", confidence: 0.95).confidence, 0.95, accuracy: 0.0001)
        XCTAssertEqual(MemoryItem(type: .profile, content: "x").confidence, 0.80, accuracy: 0.0001)
    }

    func testEveryMemorySourceRoundTripsThroughCodable() throws {
        for source in MemorySource.allCases {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(MemorySource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }

    func testMemoryItemWithNewFieldsRoundTripsThroughCodable() throws {
        let item = MemoryItem(
            id: "rt",
            type: .preference,
            content: "Keep answers concise",
            triggerContext: "chat",
            source: .explicitPreference,
            confidence: 0.95,
            replacementKey: "preference:length:global",
            isPinned: true,
            recallCount: 3,
            lastRecalledAt: Date(timeIntervalSince1970: 123),
            lastRecallReason: #"Matched "concise""#
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }

    // MARK: - Migration

    func testVersion1DatabaseMigratesWithBackupAndPreservesRows() throws {
        let firstCreated = 1_600_000_000.0
        let secondCreated = 1_600_000_500.0
        makeVersion1Database(rows: [
            (id: "row-1", type: "profile", content: "My name is Ada", context: nil,
             created: firstCreated, updated: firstCreated + 10),
            (id: "row-2", type: "preference", content: "I prefer dark mode", context: "appearance",
             created: secondCreated, updated: secondCreated + 10),
        ])
        XCTAssertEqual(userVersion(), 1)

        var store: MemoryStore? = MemoryStore(fileURL: tempURL)
        let items = store?.allMemories() ?? []
        XCTAssertEqual(items.count, 2)

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let one = try XCTUnwrap(byID["row-1"])
        XCTAssertEqual(one.content, "My name is Ada")
        XCTAssertEqual(one.createdAt.timeIntervalSince1970, firstCreated, accuracy: 0.001)
        XCTAssertEqual(one.updatedAt.timeIntervalSince1970, firstCreated + 10, accuracy: 0.001)
        XCTAssertEqual(one.source, .legacy)
        XCTAssertEqual(one.confidence, 0.80, accuracy: 0.0001)
        XCTAssertFalse(one.isPinned)
        XCTAssertEqual(one.recallCount, 0)
        XCTAssertNil(one.replacementKey)
        XCTAssertNil(one.lastRecalledAt)

        let two = try XCTUnwrap(byID["row-2"])
        XCTAssertEqual(two.content, "I prefer dark mode")
        XCTAssertEqual(two.triggerContext, "appearance")
        XCTAssertEqual(two.createdAt.timeIntervalSince1970, secondCreated, accuracy: 0.001)
        XCTAssertEqual(two.source, .legacy)

        XCTAssertEqual(userVersion(), 2, "PRAGMA user_version must become 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path),
                      "A SQLite-API backup must exist beside the migrated database")

        // Reopening must return the same two rows without deleting anything.
        store = nil
        let reopened = MemoryStore(fileURL: tempURL)
        let reopenedItems = reopened.allMemories()
        XCTAssertEqual(reopenedItems.count, 2)
        XCTAssertEqual(Set(reopenedItems.map(\.id)), ["row-1", "row-2"])
        XCTAssertEqual(userVersion(), 2)
    }

    func testMigrationDoesNotOverwriteAnExistingBackup() throws {
        makeVersion1Database(rows: [
            (id: "row-1", type: "profile", content: "My name is Ada", context: nil,
             created: 1_600_000_000.0, updated: 1_600_000_010.0),
        ])
        // Place a sentinel backup before migrating.
        let sentinel = Data("sentinel-backup".utf8)
        try sentinel.write(to: backupURL)

        _ = MemoryStore(fileURL: tempURL)

        let preserved = try Data(contentsOf: backupURL)
        XCTAssertEqual(preserved, sentinel, "An existing backup must not be overwritten")
    }

    func testSetPinnedPersistsAcrossReopen() throws {
        makeVersion1Database(rows: [
            (id: "row-1", type: "profile", content: "My name is Ada", context: nil,
             created: 1_600_000_000.0, updated: 1_600_000_010.0),
        ])
        var store: MemoryStore? = MemoryStore(fileURL: tempURL)
        XCTAssertTrue(store?.setPinned(id: "row-1", isPinned: true) ?? false)

        store = nil
        let reopened = MemoryStore(fileURL: tempURL)
        let item = try XCTUnwrap(reopened.allMemories().first)
        XCTAssertTrue(item.isPinned)
    }

    // MARK: - Helpers

    @discardableResult
    private func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            XCTFail("Could not open SQLite database at \(url.path)")
            return nil
        }
        return db
    }

    private func makeVersion1Database(rows: [(id: String, type: String, content: String,
                                              context: String?, created: Double, updated: Double)]) {
        guard let db = open(tempURL) else { return }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE memories (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            trigger_context TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        for row in rows {
            let sql = "INSERT INTO memories (id, type, content, trigger_context, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_text(statement, 1, (row.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (row.type as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (row.content as NSString).utf8String, -1, nil)
            if let context = row.context {
                sqlite3_bind_text(statement, 4, (context as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, row.created)
            sqlite3_bind_double(statement, 6, row.updated)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }

    private func userVersion() -> Int32 {
        guard let db = open(tempURL) else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }
}
