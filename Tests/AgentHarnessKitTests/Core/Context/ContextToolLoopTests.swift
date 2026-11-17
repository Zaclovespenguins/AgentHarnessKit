@testable import AgentHarnessKit
import Foundation
import Testing

/// Store that offers `compress` and `context_status`, answers them, and reports a settable version.
private actor ToolOfferingStore: ContextStore {
    private(set) var executed: [(call: ToolCall, session: SessionID)] = []
    private(set) var renderedSessions: [SessionID] = []
    var version: String? = "v1"

    nonisolated let toolDefinitions: [ToolDefinition] = [
        ToolDefinition(name: "compress", description: "Fold", parametersSchema: .object(properties: [:], required: [])),
        ToolDefinition(
            name: "context_status", description: "Status", parametersSchema: .object(properties: [:], required: [])
        ),
    ]

    func setVersion(_ value: String?) {
        version = value
    }

    func render(sessionID: SessionID, messages: [ChatMessage], windowSize _: Int?) async throws -> [ChatMessage] {
        renderedSessions.append(sessionID)
        return messages
    }

    func record(sessionID _: SessionID, messages _: [ChatMessage], usage _: TokenUsage?) async throws {}

    func executeTool(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        executed.append((call, sessionID))
        if call.name == "compress" {
            version = "v2"
            return ContextToolOutcome(
                result: ToolResult(content: "folded b0"),
                events: [.contextFolded(ContextFold(blockIDs: [ContextBlockID("b0")], tokensSaved: 40))]
            )
        }
        return ContextToolOutcome(result: ToolResult(content: "bad range", isError: true))
    }

    func stateVersion(sessionID _: SessionID) async throws -> String? {
        version
    }
}

private actor CapturingClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("CapturingClient")
    private let responses: [AssistantMessage]
    private(set) var toolNames: [[String]] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages _: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        toolNames.append(tools.map(\.name))
        return responses[toolNames.count - 1]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private let compressThenFinish: [[StreamDelta]] = [
    [
        .toolCallStart(index: 0, id: "k1", name: "compress", kind: .function),
        .toolCallDelta(index: 0, arguments: "{}"),
        .finished(usage: TokenUsage(input: 5, output: 2)),
    ],
    [
        .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
        .finished(usage: TokenUsage(input: 7, output: 3)),
    ],
]

struct ContextToolLoopTests {
    @Test
    func runOffersAndExecutesContextToolsWithoutUserToolsOrApproval() async throws {
        let store = ToolOfferingStore()
        let client = CapturingClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "k1", name: "compress", arguments: "{}"),
                ToolCall(id: "k2", name: "context_status", arguments: "{}"),
            ]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(
            client: client, tools: [],
            configuration: AgentConfiguration(contextStore: store, approvalPolicy: .allTools)
        )
        let result = try await agent.run(
            userMessage: "Go", context: EmptyContext(),
            approvalHandler: { _ in Issue.record("context tools must not ask for approval"); return .deny(reason: nil) }
        )

        #expect(result.content == "done")
        let names = await client.toolNames
        #expect(names.first.map(Set.init) == ["finish", "compress", "context_status"])
        let executed = await store.executed
        #expect(executed.map(\.call.id) == ["k1", "k2"])
        let toolMessages = result.history.compactMap { message -> String? in
            if case let .tool(id, name, content) = message { return "\(id) \(name) \(content)" }
            return nil
        }
        #expect(toolMessages == ["k1 compress folded b0", "k2 context_status bad range"])
    }

    @Test
    func contextToolsWithoutAStoreAreUnknown() async throws {
        let client = CapturingClient(responses: [
            AssistantMessage(content: "", toolCalls: [ToolCall(id: "k1", name: "compress", arguments: "{}")]),
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#),
            ]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: AgentConfiguration())
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())
        #expect(await client.toolNames.first == ["finish"])
        let toolContent = result.history.compactMap { message -> String? in
            if case let .tool(_, _, content) = message { return content }
            return nil
        }
        #expect(toolContent.count == 1)
        #expect(toolContent.first != "folded b0")
    }

    @Test
    func streamEmitsToolAndContextEventsAndCheckpointsTheVersion() async throws {
        let store = ToolOfferingStore()
        let checkpointer = InMemoryCheckpointer()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: compressThenFinish), tools: [],
            configuration: AgentConfiguration(contextStore: store)
        )
        let session = SessionID()
        var kinds: [StreamEvent.Kind] = []
        for try await event in agent.stream(
            userMessage: "Go", context: EmptyContext(), sessionID: session, checkpointer: checkpointer
        ) {
            kinds.append(event.kind)
        }

        let started = kinds.firstIndex(of: .toolCallStarted(name: "compress", id: "k1"))
        let completed = kinds.firstIndex(of: .toolCallCompleted(
            id: "k1", name: "compress", result: ToolResult(content: "folded b0")
        ))
        let folded = kinds.firstIndex(of: .contextFolded(ContextFold(blockIDs: [ContextBlockID("b0")], tokensSaved: 40)))
        #expect(started != nil && completed != nil && folded != nil)
        if let started, let completed, let folded {
            #expect(started < completed && completed < folded)
        }
        #expect(await store.executed.map(\.session) == [session])

        let ids = try await checkpointer.list(session: session)
        let checkpoints = try await ids.asyncMap { try await checkpointer.load($0) }
        #expect(!checkpoints.isEmpty)
        #expect(checkpoints.contains { $0.contextStateVersion == "v2" })
    }

    @Test
    func resumeFailsWhenTheStoreVersionMoved() async throws {
        let store = ToolOfferingStore()
        let checkpointer = InMemoryCheckpointer()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: compressThenFinish), tools: [],
            configuration: AgentConfiguration(contextStore: store)
        )
        let session = SessionID()
        for try await _ in agent.stream(
            userMessage: "Go", context: EmptyContext(), sessionID: session, checkpointer: checkpointer
        ) {}
        let checkpointID = try #require(try await checkpointer.list(session: session).first)
        let expected = try #require(try await checkpointer.load(checkpointID).contextStateVersion)

        await store.setVersion("moved")
        do {
            _ = try await agent.resume(from: checkpointID, checkpointer: checkpointer, context: EmptyContext())
            Issue.record("resume should fail on a stale context version")
        } catch let AgentCheckpointError.contextStateMismatch(expectedVersion, actual) {
            #expect(expectedVersion == expected)
            #expect(actual == "moved")
        }

        let storeless = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: compressThenFinish), tools: [],
            configuration: AgentConfiguration()
        )
        do {
            _ = try await storeless.resume(from: checkpointID, checkpointer: checkpointer, context: EmptyContext())
            Issue.record("resume without the store should fail")
        } catch let AgentCheckpointError.contextStateMismatch(_, actual) {
            #expect(actual == nil)
        }
    }

    @Test
    func checkpointVersionIsOptionalInJSON() throws {
        let checkpoint = AgentCheckpoint(
            messages: [.user("hi")], iteration: 1, tokenUsage: TokenUsageTotals(), iterationUsage: nil,
            sessionAllowlist: [], sessionID: SessionID(), runID: RunID(), checkpointID: CheckpointID(),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(checkpoint)
        #expect(!String(decoding: data, as: UTF8.self).contains("contextStateVersion"))
        #expect(try JSONDecoder().decode(AgentCheckpoint.self, from: data).contextStateVersion == nil)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            try await result.append(transform(element))
        }
        return result
    }
}
