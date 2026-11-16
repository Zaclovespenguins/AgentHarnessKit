import Foundation
import GRDB

public let gateSeedRefs = ["r1", "r2", "r3"]
public let gateChildRef = "child-1"

public struct GateCheck: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case pass = "PASS"
        case fail = "FAIL"
        case notApplicable = "N/A"
    }

    public let name: String
    public let status: Status
    public let detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct GateReport: Sendable, Codable {
    public var checks: [GateCheck] = []
    public var sqliteVersion: String?
    public var compileOptions: [String] = []
    public var journalMode: String?

    public var passed: Bool { checks.allSatisfy { $0.status != .fail } }

    public init() {}
}

/// Opens (creating if needed) a DatabasePool at `directory/context.sqlite` and applies migrations.
/// The directory is always supplied by the caller; nothing here assumes TMPDIR or a home directory.
public func openGatePool(directory: URL) throws -> DatabasePool {
    let url = directory.appendingPathComponent("context.sqlite")
    let pool = try DatabasePool(path: url.path)
    try gateMigrator().migrate(pool)
    return pool
}

func gateMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-message-fts5") { db in
        try db.create(table: "message") { t in
            t.primaryKey("ref", .text)
            t.column("sessionID", .text).notNull().indexed()
            t.column("role", .text).notNull()
            t.column("content", .text).notNull()
            t.column("tokens", .integer)
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(virtualTable: "message_fts", using: FTS5()) { t in
            t.synchronize(withTable: "message")
            t.column("content")
        }
    }
    return migrator
}

/// Runs the GRDB gate in `directory`. `secondProcess` runs while the pool is still open and
/// returns extra checks; pass nil on platforms that cannot spawn a process (iOS).
public func runGRDBGate(
    directory: URL,
    secondProcess: (@Sendable (DatabasePool) -> [GateCheck])? = nil
) -> GateReport {
    var report = GateReport()

    func record(_ name: String, _ body: () throws -> String) -> Bool {
        do {
            report.checks.append(GateCheck(name: name, status: .pass, detail: try body()))
            return true
        } catch {
            report.checks.append(GateCheck(name: name, status: .fail, detail: "\(error)"))
            return false
        }
    }

    var pool: DatabasePool?
    guard record("1 open DatabasePool", {
        pool = try openGatePool(directory: directory)
        return "path=\(directory.appendingPathComponent("context.sqlite").path)"
    }), let pool else {
        return report
    }

    _ = record("2 migration creates message + FTS5 message_fts") {
        let tables = try pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name IN ('message','message_fts')")
        }
        guard Set(tables) == ["message", "message_fts"] else {
            throw GateError("tables found: \(tables)")
        }
        return "tables=\(tables.sorted().joined(separator: ","))"
    }

    _ = record("3 write rows") {
        try pool.write { db in
            let rows: [(String, String, String, String, Int)] = [
                ("r1", "s1", "user", "the quick brown fox", 5),
                ("r2", "s1", "assistant", "a lazy dog sleeps", 4),
                ("r3", "s2", "user", "zebra crossing in another session", 6),
            ]
            for (ref, session, role, content, tokens) in rows {
                try db.execute(
                    sql: "INSERT INTO message (ref, sessionID, role, content, tokens, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [ref, session, role, content, tokens, Date()]
                )
            }
        }
        return "wrote \(gateSeedRefs.count) rows"
    }

    _ = record("4 read rows back") {
        let refs = try pool.read { db in
            try String.fetchAll(db, sql: "SELECT ref FROM message ORDER BY ref")
        }
        guard refs == gateSeedRefs else { throw GateError("refs=\(refs)") }
        return "refs=\(refs.joined(separator: ","))"
    }

    _ = record("5 FTS5 MATCH returns expected row") {
        let refs = try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT message.ref FROM message
                JOIN message_fts ON message_fts.rowid = message.rowid
                WHERE message_fts MATCH ?
                """, arguments: ["zebra"])
        }
        guard refs == ["r3"] else { throw GateError("MATCH zebra returned \(refs)") }
        return "MATCH zebra -> \(refs.joined(separator: ","))"
    }

    _ = record("6 sqlite_version and compile_options") {
        let (version, options) = try pool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown",
                try String.fetchAll(db, sql: "PRAGMA compile_options")
            )
        }
        report.sqliteVersion = version
        report.compileOptions = options.filter { $0.contains("FTS") || $0.contains("THREADSAFE") }.sorted()
        guard report.compileOptions.contains(where: { $0.contains("ENABLE_FTS5") }) else {
            throw GateError("ENABLE_FTS5 not in compile_options")
        }
        return "sqlite \(version)"
    }

    _ = record("7 WAL journal mode") {
        let mode = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
        report.journalMode = mode
        guard mode.lowercased() == "wal" else { throw GateError("journal_mode=\(mode)") }
        return "journal_mode=\(mode)"
    }

    if let secondProcess {
        report.checks.append(contentsOf: secondProcess(pool))
    } else {
        report.checks.append(GateCheck(
            name: "8 second process",
            status: .notApplicable,
            detail: "N/A (no Process on this platform; not run)"
        ))
    }
    return report
}

struct GateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
