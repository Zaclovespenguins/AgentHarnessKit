import AgentHarnessKit
import Foundation
import GRDB

// TASK H6. See `ContextPersistence` for the contract.

/// Search terms: lowercased alphanumeric runs, the same split FTS5's unicode61 tokenizer makes.
/// Every term of a query must be a whole token of the text (any order, not adjacent).
enum ContextSearchTerms {
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

/// Rules shared by both stores: messages are append-only and refs run 1...count.
enum ContextMessageRules {
    static func checkAppendOnly(saved: [StoredMessage], given: [StoredMessage]) throws {
        if given.count < saved.count {
            throw ContextPersistenceError.messagesRemoved(saved: saved.count, given: given.count)
        }
        for (index, stored) in given.enumerated() {
            guard stored.ref == MessageRef(index + 1) else {
                throw ContextPersistenceError.messageRewritten(stored.ref)
            }
            if index < saved.count, saved[index] != stored {
                throw ContextPersistenceError.messageRewritten(stored.ref)
            }
        }
    }

    /// Block search and ordering key: ascending ordinal, then id. Unparsed ids sort last.
    static func blockOrder(_ lhs: ContextBlock, _ rhs: ContextBlock) -> Bool {
        (lhs.ordinal ?? Int.max, lhs.id.rawValue) < (rhs.ordinal ?? Int.max, rhs.id.rawValue)
    }
}

/// Process-local persistence for tests and platforms without GRDB.
public actor InMemoryContextPersistence: ContextPersistence {
    private var sessions: [SessionID: ContextSessionState] = [:]

    public init() {}

    public func load(sessionID: SessionID) async throws -> ContextSessionState {
        sessions[sessionID] ?? ContextSessionState()
    }

    public func save(sessionID: SessionID, state: ContextSessionState) async throws {
        let existing = sessions[sessionID] ?? ContextSessionState()
        try ContextMessageRules.checkAppendOnly(saved: existing.messages, given: state.messages)
        var blocks = existing.blocks
        for block in state.blocks {
            if let index = blocks.firstIndex(where: { $0.id == block.id }) {
                blocks[index] = block
            } else {
                blocks.append(block)
            }
        }
        var merged = state
        merged.blocks = blocks
        sessions[sessionID] = merged
    }

    public func search(sessionID: SessionID, query: String, limit: Int) async throws -> [ContextSearchHit] {
        let terms = ContextSearchTerms.tokens(query)
        guard !terms.isEmpty, limit > 0, let state = sessions[sessionID] else { return [] }
        func matches(_ text: String) -> Bool {
            let words = Set(ContextSearchTerms.tokens(text))
            return terms.allSatisfy { words.contains($0) }
        }
        var hits: [ContextSearchHit] = []
        for block in state.blocks.filter(\.active).sorted(by: ContextMessageRules.blockOrder)
            where matches(block.summary) {
            hits.append(ContextSearchHit(source: .block(block.id), snippet: block.summary))
        }
        for stored in state.messages {
            let text = ContextTokens.text(of: stored.message)
            if matches(text) {
                hits.append(ContextSearchHit(source: .message(stored.ref), snippet: text))
            }
        }
        return Array(hits.prefix(limit))
    }
}

/// GRDB persistence: one shared database keyed by session (docs/ARCHITECTURE.md section 4).
/// Tables `message`, `block`, `block_source`, `session_meta`, plus FTS5 indexes over message text and
/// block summaries; created by a `DatabaseMigrator` migration named "v1".
public final class GRDBContextPersistence: ContextPersistence {
    private let writer: any DatabaseWriter

    /// File database (`DatabasePool`, WAL) at `directory/fileName`. The directory must exist; nothing is
    /// derived from TMPDIR or the home directory.
    public init(directory: URL, fileName: String = "context.sqlite") throws {
        let pool = try DatabasePool(path: directory.appendingPathComponent(fileName).path)
        try Self.migrate(pool)
        writer = pool
    }

    /// In-memory database (`DatabaseQueue`) for tests.
    public init() throws {
        let queue = try DatabaseQueue()
        try Self.migrate(queue)
        writer = queue
    }

    public func load(sessionID: SessionID) async throws -> ContextSessionState {
        let session = sessionID.rawValue.uuidString
        return try await writer.read { db in
            guard let meta = try Row.fetchOne(
                db, sql: "SELECT * FROM session_meta WHERE sessionID = ?", arguments: [session]
            ) else {
                return ContextSessionState()
            }
            let messages = try Self.loadMessages(db, session)
            let sources = try Self.loadSources(db, session)
            // rowid order is first-insertion order, i.e. creation order (upserts keep the rowid).
            let blocks = try Row.fetchAll(
                db, sql: "SELECT * FROM block WHERE sessionID = ? ORDER BY rowid", arguments: [session]
            ).map { try Self.block(from: $0, sources: sources) }
            let nudge: Int? = meta["nudgeBaseline"]
            let input: Int? = meta["lastInputTokens"]
            return ContextSessionState(
                messages: messages,
                blocks: blocks,
                nextBlockOrdinal: meta["nextBlockOrdinal"],
                nudgeBaseline: nudge,
                lastInputTokens: input,
                version: meta["version"]
            )
        }
    }

    public func save(sessionID: SessionID, state: ContextSessionState) async throws {
        let session = sessionID.rawValue.uuidString
        try await writer.write { db in
            let saved = try Self.loadMessages(db, session)
            try ContextMessageRules.checkAppendOnly(saved: saved, given: state.messages)
            for stored in state.messages.dropFirst(saved.count) {
                let json = try Self.encode(stored.message)
                try db.execute(
                    sql: "INSERT INTO message (sessionID, ordinal, json, body, tokens) VALUES (?, ?, ?, ?, ?)",
                    arguments: [session, stored.ref.ordinal, json, ContextTokens.text(of: stored.message), stored.tokens]
                )
            }
            for block in state.blocks {
                try Self.upsert(block, session, db)
            }
            try db.execute(sql: """
                INSERT INTO session_meta (sessionID, nextBlockOrdinal, nudgeBaseline, lastInputTokens, version)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(sessionID) DO UPDATE SET
                    nextBlockOrdinal = excluded.nextBlockOrdinal,
                    nudgeBaseline = excluded.nudgeBaseline,
                    lastInputTokens = excluded.lastInputTokens,
                    version = excluded.version
                """, arguments: [
                    session, state.nextBlockOrdinal, state.nudgeBaseline, state.lastInputTokens, state.version,
                ])
        }
    }

    public func search(sessionID: SessionID, query: String, limit: Int) async throws -> [ContextSearchHit] {
        let terms = ContextSearchTerms.tokens(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        // Tokens are alphanumeric only, so quoting them cannot break FTS5 syntax.
        let match = terms.map { "\"\($0)\"" }.joined(separator: " ")
        let session = sessionID.rawValue.uuidString
        return try await writer.read { db in
            let blockRows = try Row.fetchAll(db, sql: """
                SELECT block.id AS id, block.summary AS summary FROM block_fts
                JOIN block ON block.rowid = block_fts.rowid
                WHERE block_fts MATCH ? AND block.sessionID = ? AND block.active = 1
                ORDER BY block.sortOrdinal, block.id LIMIT ?
                """, arguments: [match, session, limit])
            let messageRows = try Row.fetchAll(db, sql: """
                SELECT message.ordinal AS ordinal, message.body AS body FROM message_fts
                JOIN message ON message.rowid = message_fts.rowid
                WHERE message_fts MATCH ? AND message.sessionID = ?
                ORDER BY message.ordinal LIMIT ?
                """, arguments: [match, session, limit])
            let blocks = blockRows.map { row -> ContextSearchHit in
                let id: String = row["id"]
                let summary: String = row["summary"]
                return ContextSearchHit(source: .block(ContextBlockID(id)), snippet: summary)
            }
            let messages = messageRows.map { row -> ContextSearchHit in
                let ordinal: Int = row["ordinal"]
                let body: String = row["body"]
                return ContextSearchHit(source: .message(MessageRef(ordinal)), snippet: body)
            }
            return Array((blocks + messages).prefix(limit))
        }
    }

    // MARK: - Schema

    private static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "message") { t in
                t.column("sessionID", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("json", .text).notNull()
                t.column("body", .text).notNull()
                t.column("tokens", .integer).notNull()
                t.primaryKey(["sessionID", "ordinal"])
            }
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("body")
            }
            try db.create(table: "block") { t in
                t.column("sessionID", .text).notNull()
                t.column("id", .text).notNull()
                t.column("sortOrdinal", .integer).notNull()
                t.column("tier", .integer).notNull()
                t.column("topic", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("effective", .text).notNull() // JSON array of message ordinals
                t.column("active", .boolean).notNull()
                t.column("generation", .text).notNull()
                t.column("survivedCount", .integer).notNull()
                t.column("createdByCallID", .text)
                t.primaryKey(["sessionID", "id"])
            }
            try db.create(virtualTable: "block_fts", using: FTS5()) { t in
                t.synchronize(withTable: "block")
                t.column("summary")
            }
            // One row per direct source: kind "message" (messageOrdinal) or "block" (sourceBlockID).
            try db.create(table: "block_source") { t in
                t.column("sessionID", .text).notNull()
                t.column("blockID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("messageOrdinal", .integer)
                t.column("sourceBlockID", .text)
                t.primaryKey(["sessionID", "blockID", "kind", "position"])
            }
            try db.create(table: "session_meta") { t in
                t.primaryKey("sessionID", .text)
                t.column("nextBlockOrdinal", .integer).notNull()
                t.column("nudgeBaseline", .integer)
                t.column("lastInputTokens", .integer)
                t.column("version", .integer).notNull()
            }
        }
        try migrator.migrate(writer)
    }

    // MARK: - Rows

    private static func encode(_ message: ChatMessage) throws -> String {
        String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    private static func loadMessages(_ db: Database, _ session: String) throws -> [StoredMessage] {
        try Row.fetchAll(
            db, sql: "SELECT ordinal, json, tokens FROM message WHERE sessionID = ? ORDER BY ordinal",
            arguments: [session]
        ).map { row in
            let ordinal: Int = row["ordinal"]
            let json: String = row["json"]
            let tokens: Int = row["tokens"]
            let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
            return StoredMessage(ref: MessageRef(ordinal), message: message, tokens: tokens)
        }
    }

    /// Source rows of every block in the session, keyed by block id, each list in position order.
    private static func loadSources(
        _ db: Database, _ session: String
    ) throws -> [String: (messages: [MessageRef], blocks: [ContextBlockID])] {
        var result: [String: (messages: [MessageRef], blocks: [ContextBlockID])] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT blockID, kind, messageOrdinal, sourceBlockID FROM block_source
            WHERE sessionID = ? ORDER BY blockID, kind, position
            """, arguments: [session])
        for row in rows {
            let blockID: String = row["blockID"]
            let kind: String = row["kind"]
            var entry = result[blockID] ?? (messages: [], blocks: [])
            if kind == "message" {
                let ordinal: Int = row["messageOrdinal"]
                entry.messages.append(MessageRef(ordinal))
            } else {
                let source: String = row["sourceBlockID"]
                entry.blocks.append(ContextBlockID(source))
            }
            result[blockID] = entry
        }
        return result
    }

    private static func block(
        from row: Row, sources: [String: (messages: [MessageRef], blocks: [ContextBlockID])]
    ) throws -> ContextBlock {
        let id: String = row["id"]
        let generationName: String = row["generation"]
        guard let generation = BlockGeneration(rawValue: generationName) else {
            throw ContextStorageCorruption.unknownGeneration(generationName)
        }
        let effectiveJSON: String = row["effective"]
        let effective = try JSONDecoder().decode([Int].self, from: Data(effectiveJSON.utf8))
        let source = sources[id]
        let block = ContextBlock(
            id: ContextBlockID(id),
            tier: row["tier"],
            topic: row["topic"],
            summary: row["summary"],
            directMessageRefs: source?.messages ?? [],
            directBlockIDs: source?.blocks ?? [],
            effectiveMessageRefs: effective.map(MessageRef.init),
            active: row["active"],
            generation: generation,
            survivedCount: row["survivedCount"],
            createdByCallID: row["createdByCallID"]
        )
        return block
    }

    private static func upsert(_ block: ContextBlock, _ session: String, _ db: Database) throws {
        let effective = try JSONEncoder().encode(block.effectiveMessageRefs.map(\.ordinal))
        try db.execute(sql: """
            INSERT INTO block (sessionID, id, sortOrdinal, tier, topic, summary, effective, active,
                               generation, survivedCount, createdByCallID)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sessionID, id) DO UPDATE SET
                sortOrdinal = excluded.sortOrdinal,
                tier = excluded.tier,
                topic = excluded.topic,
                summary = excluded.summary,
                effective = excluded.effective,
                active = excluded.active,
                generation = excluded.generation,
                survivedCount = excluded.survivedCount,
                createdByCallID = excluded.createdByCallID
            """, arguments: [
                session, block.id.rawValue, block.ordinal ?? Int.max, block.tier, block.topic, block.summary,
                String(decoding: effective, as: UTF8.self), block.active, block.generation.rawValue,
                block.survivedCount, block.createdByCallID,
            ])
        try db.execute(
            sql: "DELETE FROM block_source WHERE sessionID = ? AND blockID = ?",
            arguments: [session, block.id.rawValue]
        )
        for (position, ref) in block.directMessageRefs.enumerated() {
            try db.execute(sql: """
                INSERT INTO block_source (sessionID, blockID, kind, position, messageOrdinal, sourceBlockID)
                VALUES (?, ?, 'message', ?, ?, NULL)
                """, arguments: [session, block.id.rawValue, position, ref.ordinal])
        }
        for (position, source) in block.directBlockIDs.enumerated() {
            try db.execute(sql: """
                INSERT INTO block_source (sessionID, blockID, kind, position, messageOrdinal, sourceBlockID)
                VALUES (?, ?, 'block', ?, NULL, ?)
                """, arguments: [session, block.id.rawValue, position, source.rawValue])
        }
    }
}

/// A row in the context database holds a value the model does not know.
enum ContextStorageCorruption: Error {
    case unknownGeneration(String)
}
