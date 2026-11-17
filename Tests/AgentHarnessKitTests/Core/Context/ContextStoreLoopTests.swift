@testable import AgentHarnessKit
import Foundation
import Testing

private struct RecordCall {
    let session: SessionID
    let messages: [ChatMessage]
    let usage: TokenUsage?
}

private actor RecordingContextStore: ContextStore {
    private(set) var renderCalls: [(session: SessionID, messages: [ChatMessage])] = []
    private(set) var recordCalls: [RecordCall] = []
    private let rewrite: (@Sendable ([ChatMessage]) -> [ChatMessage])?

    init(rewrite: (@Sendable ([ChatMessage]) -> [ChatMessage])? = nil) {
        self.rewrite = rewrite
    }

    func render(sessionID: SessionID, messages: [ChatMessage]) async throws -> [ChatMessage] {
        renderCalls.append((sessionID, messages))
        return rewrite?(messages) ?? messages
    }

    func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws {
        // Slow store: makes "finished yielded before record" fail deterministically.
        try await Task.sleep(for: .milliseconds(20))
        recordCalls.append(RecordCall(session: sessionID, messages: messages, usage: usage))
    }
}

private actor MessageCapturingClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("MessageCapturingClient")
    private let responses: [AssistantMessage]
    private(set) var requests: [[ChatMessage]] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        requests.append(messages)
        return responses[requests.count - 1]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct PingParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct PingOutput: Codable {
    let pong: Bool
}

private func makePingTool() throws -> Tool<PingParams, PingOutput, EmptyContext> {
    try Tool(name: "ping", description: "Ping", executor: { _, _ in PingOutput(pong: true) })
}

private let pingThenFinish: [AssistantMessage] = [
    AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: "call_ping", name: "ping", arguments: "{}")],
        tokenUsage: TokenUsage(input: 5, output: 2)
    ),
    AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: "call_finish", name: "finish", arguments: #"{"content": "done"}"#)],
        tokenUsage: TokenUsage(input: 7, output: 3)
    ),
]

struct ContextStoreLoopTests {
    @Test
    func inMemoryStoreIsAPassThrough() async throws {
        let store = InMemoryContextStore()
        let messages: [ChatMessage] = [.system("S"), .user("Hi")]
        #expect(try await store.render(sessionID: SessionID(), messages: messages) == messages)
        try await store.record(sessionID: SessionID(), messages: messages, usage: nil)
    }

    @Test
    func runRendersBeforeEveryRequestAndRecordsEveryMessage() async throws {
        let store = RecordingContextStore()
        let client = MessageCapturingClient(responses: pingThenFinish)
        let agent = try Agent<EmptyContext>(
            client: client, tools: [makePingTool()],
            configuration: AgentConfiguration(systemPrompt: "System", contextStore: store)
        )
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        let renders = await store.renderCalls
        let records = await store.recordCalls
        #expect(result.content == "done")
        #expect(renders.count == 2)
        #expect(records.count == 2)
        #expect(Set(renders.map(\.session) + records.map(\.session)).count == 1)
        #expect(renders[0].messages == [.system("System"), .user("Go")])
        #expect(records.map(\.usage) == [TokenUsage(input: 5, output: 2), TokenUsage(input: 7, output: 3)])

        let recorded = records.flatMap(\.messages)
        #expect(Array(recorded.prefix(2)) == [.system("System"), .user("Go")])
        #expect(recorded.count == 5)
        guard case .assistant = recorded[2], case let .tool(id, name, _) = recorded[3],
              case .assistant = recorded[4]
        else {
            Issue.record("Unexpected recorded shape: \(recorded)")
            return
        }
        #expect(id == "call_ping" && name == "ping")
        #expect(renders[1].messages == Array(recorded.prefix(4)))
    }

    @Test
    func renderedMessagesGoToTheClientButHistoryStaysCanonical() async throws {
        let store = RecordingContextStore(rewrite: { [.system("FOLDED")] + $0.dropFirst() })
        let client = MessageCapturingClient(responses: [pingThenFinish[1]])
        let agent = Agent<EmptyContext>(
            client: client, tools: [],
            configuration: AgentConfiguration(systemPrompt: "System", contextStore: store)
        )
        let result = try await agent.run(userMessage: "Go", context: EmptyContext())

        #expect(await client.requests == [[.system("FOLDED"), .user("Go")]])
        #expect(result.history.first == .system("System"))
    }

    @Test
    func streamUsesTheStreamSessionIDForTheStore() async throws {
        let store = RecordingContextStore()
        let client = StreamingMockLLMClient(streamSequences: [
            [
                .toolCallStart(index: 0, id: "call_ping", name: "ping", kind: .function),
                .toolCallDelta(index: 0, arguments: "{}"),
                .finished(usage: TokenUsage(input: 5, output: 2)),
            ],
            [
                .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
                .finished(usage: TokenUsage(input: 7, output: 3)),
            ],
        ])
        let agent = try Agent<EmptyContext>(
            client: client, tools: [makePingTool()],
            configuration: AgentConfiguration(contextStore: store)
        )
        let session = SessionID()
        var finishedHistory: [ChatMessage] = []
        for try await event in agent.stream(userMessage: "Go", context: EmptyContext(), sessionID: session) {
            if case let .finished(_, _, _, history) = event.kind {
                finishedHistory = history
                // The store must hold the whole run before the consumer sees the terminal event.
                #expect(await store.recordCalls.count == 2)
            }
        }

        let renders = await store.renderCalls
        let records = await store.recordCalls
        #expect(renders.count == 2 && records.count == 2)
        #expect(Set(renders.map(\.session) + records.map(\.session)) == [session])
        #expect(records.flatMap(\.messages).count == 4)
        #expect(Array(records.flatMap(\.messages).prefix(3)) == Array(finishedHistory.prefix(3)))
        #expect(records.map(\.usage) == [TokenUsage(input: 5, output: 2), TokenUsage(input: 7, output: 3)])
    }
}
