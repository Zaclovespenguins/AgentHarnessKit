import Foundation

/// Persists and renders a session's context around each model request. Phase 4b swaps in the GRDB implementation.
public protocol ContextStore: Sendable {
    /// Called before every model request with the loop's full history; returns the messages to send.
    func render(sessionID: SessionID, messages: [ChatMessage]) async throws -> [ChatMessage]
    /// Called after each iteration with the messages appended since the previous record call and that response's usage.
    func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws
}

/// A no-op context store that sends history unchanged and persists nothing. Phase 4b replaces it with the GRDB store.
public struct InMemoryContextStore: ContextStore {
    public init() {}

    public func render(sessionID: SessionID, messages: [ChatMessage]) async throws -> [ChatMessage] {
        messages
    }

    public func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws {}
}
