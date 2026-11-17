import AgentHarnessKit
import Foundation

// TASK M3: implement every `fatalError` in this file. See the reference
// AgentRunKit Sources/AgentRunKit/MCP/MCPSession.swift.

/// Coordinates multiple MCP server connections with scoped tool access.
public struct MCPSession: Sendable {
    private let configurations: [MCPServerConfiguration]
    private let transportFactory: @Sendable (MCPServerConfiguration) -> any MCPTransport

    /// Builds each server's transport from its configuration (stdio on macOS/Linux, HTTP everywhere).
    public init(configurations: [MCPServerConfiguration]) {
        self.init(configurations: configurations) { $0.makeTransport() }
    }

    init(
        configurations: [MCPServerConfiguration],
        transportFactory: @escaping @Sendable (MCPServerConfiguration) -> any MCPTransport
    ) {
        self.configurations = configurations
        self.transportFactory = transportFactory
    }

    /// Connects to all configured servers, discovers tools, passes them to the closure, then shuts down.
    public func withTools<C: ToolContext, R: Sendable>(
        _ body: @Sendable ([any AnyTool<C>]) async throws -> R
    ) async throws -> R {
        fatalError("M3: withTools")
    }
}
