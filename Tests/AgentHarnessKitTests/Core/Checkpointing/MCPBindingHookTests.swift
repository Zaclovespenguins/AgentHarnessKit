@testable import AgentHarnessKit
import Foundation
import Testing

/// A stand-in for `MCPTool` so core can test the binding hook without the MCP target.
private struct FakeMCPTool: AnyTool, MCPBindingProviding {
    typealias Context = EmptyContext
    let name: String
    let server: String
    var description: String { "fake" }
    var parametersSchema: JSONSchema { .object(properties: [:], required: []) }
    var mcpToolBinding: MCPToolBinding { MCPToolBinding(serverName: server, toolName: name) }
    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        ToolResult(content: "ok")
    }
}

private func callDeltas(_ name: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: "call_\(name)", name: name, kind: .function),
        .toolCallDelta(index: 0, arguments: "{}"),
        .finished(usage: TokenUsage(input: 1, output: 1)),
    ]
}

private let finishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: TokenUsage(input: 1, output: 1)),
]

struct MCPBindingHookTests {
    private func firstCheckpoint(tools: [any AnyTool<EmptyContext>]) async throws -> (InMemoryCheckpointer, AgentCheckpoint) {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [callDeltas("search"), finishDeltas]),
            tools: tools
        )
        for try await _ in agent.stream(
            userMessage: "Hi", context: EmptyContext(), sessionID: session, checkpointer: backend
        ) {}
        let ids = try await backend.list(session: session)
        return try await (backend, backend.load(#require(ids.first)))
    }

    @Test func checkpointRecordsOnlyParticipatingMCPBindings() async throws {
        let (_, checkpoint) = try await firstCheckpoint(tools: [
            FakeMCPTool(name: "search", server: "alpha"),
            FakeMCPTool(name: "unused", server: "beta"),
        ])
        #expect(checkpoint.mcpToolBindings == [MCPToolBinding(serverName: "alpha", toolName: "search")])
    }

    @Test func resumeFailsWhenLiveAgentLacksBinding() async throws {
        let (backend, checkpoint) = try await firstCheckpoint(tools: [FakeMCPTool(name: "search", server: "alpha")])
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [FakeMCPTool(name: "search", server: "other-server")]
        )
        await #expect(throws: AgentCheckpointError.mcpBindingMismatch(
            [MCPToolBinding(serverName: "alpha", toolName: "search")]
        )) {
            _ = try await agent.resume(from: checkpoint.checkpointID, checkpointer: backend, context: EmptyContext())
        }
    }

    @Test func resumeAcceptsMatchingLiveBinding() async throws {
        let (backend, checkpoint) = try await firstCheckpoint(tools: [FakeMCPTool(name: "search", server: "alpha")])
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [finishDeltas]),
            tools: [FakeMCPTool(name: "search", server: "alpha")]
        )
        var sawCompletion = false
        for try await event in try await agent.resume(
            from: checkpoint.checkpointID, checkpointer: backend, context: EmptyContext()
        ) {
            if case .finished = event.kind { sawCompletion = true }
        }
        #expect(sawCompletion)
    }
}
