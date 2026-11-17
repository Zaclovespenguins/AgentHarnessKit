@testable import AgentHarnessKit
import Foundation
import Testing

/// Replies with `responses[n]` where n is the number of assistant messages already in the request.
private struct H9ScriptedClient: LLMClient {
    let providerIdentifier: ProviderIdentifier = .custom("H9Scripted")
    let responses: [AssistantMessage]

    func turn(_ messages: [ChatMessage]) -> AssistantMessage {
        let assistantTurns = messages.count { if case .assistant = $0 { true } else { false } }
        return responses[assistantTurns]
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        turn(messages)
    }

    func stream(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let response = turn(messages)
        return AsyncThrowingStream { continuation in
            if !response.content.isEmpty {
                continuation.yield(.content(response.content))
            }
            for (index, call) in response.toolCalls.enumerated() {
                continuation.yield(.toolCallStart(index: index, id: call.id, name: call.name, kind: call.kind))
                continuation.yield(.toolCallDelta(index: index, arguments: call.arguments))
            }
            continuation.yield(.finished(usage: response.tokenUsage))
            continuation.finish()
        }
    }
}

private actor H9ContextStore: ContextStore {
    nonisolated let toolDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "context_status", description: "Context status",
            parametersSchema: .object(properties: [:], required: [])
        ),
    ]
    nonisolated let version: String?
    private let outcome: ContextToolOutcome
    private(set) var executed: [String] = []
    private(set) var sessionIDs: [SessionID] = []

    init(
        version: String? = nil,
        outcome: ContextToolOutcome = ContextToolOutcome(result: ToolResult(content: "status ok"))
    ) {
        self.version = version
        self.outcome = outcome
    }

    func render(sessionID _: SessionID, messages: [ChatMessage], windowSize _: Int?) async throws -> [ChatMessage] {
        messages
    }

    func record(sessionID _: SessionID, messages _: [ChatMessage], usage _: TokenUsage?) async throws {}

    func executeTool(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        executed.append(call.name)
        sessionIDs.append(sessionID)
        return outcome
    }

    func stateVersion(sessionID _: SessionID) async throws -> String? {
        version
    }
}

private actor H9CheckpointRecorder: AgentCheckpointer {
    private(set) var saved: [AgentCheckpoint] = []

    func save(_ checkpoint: AgentCheckpoint) async throws {
        saved.append(checkpoint)
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        guard let found = saved.first(where: { $0.checkpointID == id }) else {
            throw AgentCheckpointError.notFound(id)
        }
        return found
    }

    func list(session: SessionID) async throws -> [CheckpointID] {
        saved.filter { $0.sessionID == session }.map(\.checkpointID)
    }
}

private actor H9ApprovalProbe {
    private(set) var requests = 0

    func handle(_: ToolApprovalRequest) -> ToolApprovalDecision {
        requests += 1
        return .approve
    }
}

private func toolCallTurn(_ id: String, _ name: String) -> AssistantMessage {
    AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: id, name: name, arguments: "{}")],
        tokenUsage: TokenUsage(input: 1, output: 1)
    )
}

private func textTurn(_ text: String) -> AssistantMessage {
    AssistantMessage(content: text, toolCalls: [], tokenUsage: TokenUsage(input: 1, output: 1))
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let h9Status = ContextStatus(windowSize: 100, usedTokens: 10, blockCount: 1)

struct H9SelfTests {
    @Test
    func contextToolDefinitionsAreOfferedToTheModel() {
        let store = H9ContextStore()
        let agent = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [textTurn("done")]),
            tools: [],
            configuration: AgentConfiguration(contextStore: store)
        )
        #expect(agent.toolDefinitions.map(\.name).contains("context_status"))
    }

    @Test
    func runPathRoutesContextCallsToStoreWithoutApproval() async throws {
        let store = H9ContextStore()
        let probe = H9ApprovalProbe()
        let agent = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [toolCallTurn("c1", "context_status"), textTurn("done")]),
            tools: [],
            configuration: AgentConfiguration(contextStore: store, approvalPolicy: .allTools)
        )
        let result = try await agent.run(
            userMessage: "hi", context: EmptyContext(), approvalHandler: { await probe.handle($0) }
        )
        #expect(await store.executed == ["context_status"])
        #expect(await probe.requests == 0)
        let toolMessages = result.history.compactMap { message -> String? in
            if case let .tool(id, name, content) = message, id == "c1", name == "context_status" { return content }
            return nil
        }
        #expect(toolMessages == ["status ok"])
    }

    @Test
    func streamingPathEmitsCompletionAndOutcomeEventsWithIterationOrigin() async throws {
        let store = H9ContextStore(outcome: ContextToolOutcome(
            result: ToolResult(content: "status ok"),
            events: [.contextStatus(h9Status)]
        ))
        let agent = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [toolCallTurn("c1", "context_status"), textTurn("done")]),
            tools: [],
            configuration: AgentConfiguration(contextStore: store)
        )
        let sid = SessionID()
        let events = try await collect(agent.stream(
            userMessage: "hi", context: EmptyContext(), sessionID: sid
        ))
        let completed = events.first { if case .toolCallCompleted = $0.kind { true } else { false } }
        let status = events.first { if case .contextStatus = $0.kind { true } else { false } }
        #expect(completed?.kind == .toolCallCompleted(
            id: "c1", name: "context_status", result: ToolResult(content: "status ok")
        ))
        #expect(status?.kind == .contextStatus(h9Status))
        #expect(completed?.sessionID == sid)
        #expect(status?.sessionID == sid)
        #expect(status?.runID == completed?.runID)
        #expect(await store.executed == ["context_status"])
    }

    @Test
    func contextStateVersionIsEncodedOnlyWhenPresent() throws {
        let base = AgentCheckpoint(
            messages: [.user("hi")], iteration: 1, tokenUsage: TokenUsageTotals(),
            sessionID: SessionID(), runID: RunID()
        )
        let withoutKey = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        #expect(withoutKey?["contextStateVersion"] == nil)

        let versioned = AgentCheckpoint(
            messages: [.user("hi")], iteration: 1, tokenUsage: TokenUsageTotals(),
            sessionID: SessionID(), runID: RunID(), contextStateVersion: "v1"
        )
        let data = try JSONEncoder().encode(versioned)
        #expect(try JSONDecoder().decode(AgentCheckpoint.self, from: data).contextStateVersion == "v1")
        let legacy = try JSONEncoder().encode(base)
        #expect(try JSONDecoder().decode(AgentCheckpoint.self, from: legacy).contextStateVersion == nil)
    }

    @Test
    func snapshotsRecordTheStoreStateVersion() async throws {
        let recorder = H9CheckpointRecorder()
        let agent = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [toolCallTurn("c1", "context_status"), textTurn("done")]),
            tools: [],
            configuration: AgentConfiguration(contextStore: H9ContextStore(version: "v1"))
        )
        _ = try await collect(agent.stream(
            userMessage: "hi", context: EmptyContext(), checkpointer: recorder
        ))
        let saved = await recorder.saved
        #expect(!saved.isEmpty)
        #expect(saved.allSatisfy { $0.contextStateVersion == "v1" })
    }

    @Test
    func resumeRejectsContextStateMismatch() async throws {
        let recorder = H9CheckpointRecorder()
        let checkpoint = AgentCheckpoint(
            messages: [.system("S"), .user("hi")], iteration: 1, tokenUsage: TokenUsageTotals(),
            sessionID: SessionID(), runID: RunID(), contextStateVersion: "v1"
        )
        try await recorder.save(checkpoint)

        let mismatched = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [textTurn("done")]),
            tools: [],
            configuration: AgentConfiguration(contextStore: H9ContextStore(version: "v2"))
        )
        await #expect(throws: AgentCheckpointError.contextStateMismatch(expected: "v1", actual: "v2")) {
            _ = try await mismatched.resume(
                from: checkpoint.checkpointID, checkpointer: recorder, context: EmptyContext()
            )
        }

        let storeless = Agent<EmptyContext>(
            client: H9ScriptedClient(responses: [textTurn("done")]),
            tools: []
        )
        await #expect(throws: AgentCheckpointError.contextStateMismatch(expected: "v1", actual: nil)) {
            _ = try await storeless.resume(
                from: checkpoint.checkpointID, checkpointer: recorder, context: EmptyContext()
            )
        }
    }
}
