import AgentHarnessKit
import Foundation
import GRDB

// TASK H6. Stubs; replace the bodies, keep the public signatures. See `ContextPersistence` for the contract.

/// Process-local persistence for tests and platforms without GRDB.
public actor InMemoryContextPersistence: ContextPersistence {
    public init() {}

    public func load(sessionID: SessionID) async throws -> ContextSessionState {
        ContextSessionState()
    }

    public func save(sessionID: SessionID, state: ContextSessionState) async throws {}

    public func search(sessionID: SessionID, query: String, limit: Int) async throws -> [ContextSearchHit] {
        []
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
        writer = try DatabasePool(path: directory.appendingPathComponent(fileName).path)
    }

    /// In-memory database (`DatabaseQueue`) for tests.
    public init() throws {
        writer = try DatabaseQueue()
    }

    public func load(sessionID: SessionID) async throws -> ContextSessionState {
        ContextSessionState()
    }

    public func save(sessionID: SessionID, state: ContextSessionState) async throws {}

    public func search(sessionID: SessionID, query: String, limit: Int) async throws -> [ContextSearchHit] {
        []
    }
}
