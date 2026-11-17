import AgentHarnessKit
import Foundation

// TASK M2: implement every `fatalError` in this file. See the reference
// AgentRunKit Sources/AgentRunKit/MCP/MCPClient.swift.

/// Manages a connection to a single MCP server.
public actor MCPClient {
    public nonisolated let serverName: String

    public init(
        serverName: String,
        transport: any MCPTransport,
        initializationTimeout: Duration = .seconds(30),
        toolCallTimeout: Duration = .seconds(60)
    ) {
        fatalError("M2: MCPClient.init")
    }

    public init(configuration: MCPServerConfiguration) {
        self.init(
            serverName: configuration.name,
            transport: configuration.makeTransport(),
            initializationTimeout: configuration.initializationTimeout,
            toolCallTimeout: configuration.toolCallTimeout
        )
    }

    /// Connects the transport, runs `initialize`, sends `notifications/initialized`, and pages through `tools/list`.
    func connectAndInitialize() async throws {
        fatalError("M2: connectAndInitialize")
    }

    func listTools() -> [MCPToolInfo] {
        fatalError("M2: listTools")
    }

    func callTool(name: String, arguments: Data) async throws -> MCPCallResult {
        fatalError("M2: callTool")
    }

    func shutdown() async {
        fatalError("M2: shutdown")
    }
}
