import AgentHarnessKit
import Foundation

// TASK M1: implement every `fatalError` in this file. See the reference
// AgentRunKit Sources/AgentRunKit/MCP/MCPContent.swift.

/// Content returned from an MCP tool call.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String)
    case embeddedResource(uri: String, mimeType: String?, content: MCPResourceContent)
}

extension MCPContent: Decodable {
    public init(from decoder: any Decoder) throws {
        fatalError("M1: MCPContent.init(from:)")
    }
}

/// The result of an MCP tools/call request.
public struct MCPCallResult: Sendable, Equatable, Decodable {
    public let content: [MCPContent]
    /// Deterministically encoded JSON of `structuredContent`, if the server sent it.
    public let structuredContent: Data?
    public let isError: Bool

    public init(content: [MCPContent], structuredContent: Data? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public init(from decoder: any Decoder) throws {
        fatalError("M1: MCPCallResult.init(from:)")
    }

    /// Converts MCP content to a text-based tool result, preferring structured content when available.
    public func toToolResult() -> ToolResult {
        fatalError("M1: MCPCallResult.toToolResult()")
    }
}
