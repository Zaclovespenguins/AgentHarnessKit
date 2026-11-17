import AgentHarnessKit
import Foundation

// TASK M3: implement every `fatalError` in this file. See the reference
// AgentRunKit Sources/AgentRunKit/MCP/MCPTool.swift.

/// Adapts an MCP-discovered tool to the ``AnyTool`` protocol.
public struct MCPTool<C: ToolContext>: AnyTool, MCPBindingProviding, Sendable {
    public typealias Context = C

    public let name: String
    public let description: String
    public let parametersSchema: JSONSchema

    public init(info: MCPToolInfo, client: MCPClient) {
        fatalError("M3: MCPTool.init")
    }

    public func execute(arguments: Data, context _: C) async throws -> ToolResult {
        fatalError("M3: MCPTool.execute")
    }

    /// `MCPToolBinding(serverName: client.serverName, toolName: name)`.
    public var mcpToolBinding: MCPToolBinding {
        fatalError("M3: mcpToolBinding")
    }
}
