import Foundation

/// The result of the harness executing one reserved context tool (`compress`, `decompress`, `search_context`,
/// `context_status`) on the model's behalf.
public struct ContextToolOutcome: Sendable, Equatable {
    /// Sent back to the model as the tool result. Validation failures are `isError: true` with readable text.
    public let result: ToolResult
    /// `contextFolded` / `contextRestored` / `contextStatus` events the loop emits after the tool result.
    public let events: [StreamEvent.Kind]

    public init(result: ToolResult, events: [StreamEvent.Kind] = []) {
        self.result = result
        self.events = events
    }
}

/// Persists and renders a session's context around each model request.
public protocol ContextStore: Sendable {
    /// Called before every model request with the loop's full history; returns the messages to send.
    /// `windowSize` is the model's context window (`LLMClient.contextWindowSize`); stores that need it throw
    /// `AgentError.missingContextWindowSize` when it is nil.
    func render(sessionID: SessionID, messages: [ChatMessage], windowSize: Int?) async throws -> [ChatMessage]
    /// Called after each iteration with the messages appended since the previous record call and that response's usage.
    func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws
    /// Reserved tools the loop offers the model in addition to the agent's own tools. Names must be among
    /// `compress`, `decompress`, `search_context`, `context_status`.
    var toolDefinitions: [ToolDefinition] { get }
    /// Executes a call to one of `toolDefinitions`. Model mistakes are returned as `isError` results, not thrown.
    func executeTool(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome
    /// Opaque version of the session's block state, stored in checkpoints and compared on resume. nil when the
    /// store keeps no durable state.
    func stateVersion(sessionID: SessionID) async throws -> String?
}

public extension ContextStore {
    var toolDefinitions: [ToolDefinition] {
        []
    }

    func executeTool(_ call: ToolCall, sessionID _: SessionID) async throws -> ContextToolOutcome {
        ContextToolOutcome(result: ToolResult(content: "Unknown context tool: \(call.name)", isError: true))
    }

    func stateVersion(sessionID _: SessionID) async throws -> String? {
        nil
    }
}

/// A no-op context store that sends history unchanged and persists nothing.
public struct InMemoryContextStore: ContextStore {
    public init() {}

    public func render(sessionID _: SessionID, messages: [ChatMessage],
                       windowSize _: Int?) async throws -> [ChatMessage] {
        messages
    }

    public func record(sessionID _: SessionID, messages _: [ChatMessage], usage _: TokenUsage?) async throws {}
}
