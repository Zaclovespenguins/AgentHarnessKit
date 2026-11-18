@testable import AgentHarnessKit
import Foundation
import Testing

private let echoToolCallDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_echo", name: "echo", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
    .finished(usage: TokenUsage(input: 10, output: 5)),
]

private let finishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: TokenUsage(input: 5, output: 5)),
]

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func makeEchoTool() throws -> Tool<EchoParams, EchoOutput, EmptyContext> {
    try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: "echo",
        description: "Echoes input",
        executor: { params, _ in EchoOutput(echoed: params.message) }
    )
}

private func runStream(
    sequences: [[StreamDelta]],
    tools: [any AnyTool<EmptyContext>],
    checkpointer: (any AgentCheckpointer)?,
    sessionID: SessionID? = nil,
    contextWindowSize: Int? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
) async throws -> [StreamEvent] {
    let client = StreamingMockLLMClient(streamSequences: sequences, contextWindowSize: contextWindowSize)
    let agent = Agent<EmptyContext>(client: client, tools: tools, configuration: configuration)
    var events: [StreamEvent] = []
    for try await event in agent.stream(
        userMessage: "Hi", context: EmptyContext(),
        sessionID: sessionID, checkpointer: checkpointer
    ) {
        events.append(event)
    }
    return events
}

struct AgentCheckpointingIntegrationTests {
    @Test
    func streamSavesCheckpointAfterToolResults() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        _ = try await runStream(
            sequences: [echoToolCallDeltas, finishDeltas],
            tools: [makeEchoTool()],
            checkpointer: backend,
            sessionID: session
        )
        let ids = try await backend.list(session: session)
        #expect(ids.count == 1)
        let firstCheckpoint = try await backend.load(#require(ids.first))
        let hasToolMessage = firstCheckpoint.messages.contains { message in
            if case .tool = message {
                return true
            }
            return false
        }
        #expect(hasToolMessage)
        #expect(firstCheckpoint.iteration == 1)
        #expect(firstCheckpoint.terminalOutcome == nil)
    }

    @Test(arguments: [TokenUsage(input: 10, output: 5), nil])
    func streamSavesCheckpointMetadataAfterEachNonTerminalIteration(firstUsage: TokenUsage?) async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let echoIteration1: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .finished(usage: firstUsage),
        ]
        let echoIteration2: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"second"}"#),
            .finished(usage: TokenUsage(input: 17, output: 11)),
        ]
        let events = try await runStream(
            sequences: [echoIteration1, echoIteration2, finishDeltas],
            tools: [makeEchoTool()],
            checkpointer: backend,
            sessionID: session
        )
        let ids = try await backend.list(session: session)
        #expect(ids.count == 2)
        let firstCheckpoint = try await backend.load(ids[0])
        let secondCheckpoint = try await backend.load(ids[1])

        #expect(firstCheckpoint.iteration == 1)
        #expect(firstCheckpoint.iterationUsage == firstUsage)
        #expect(firstCheckpoint.tokenUsage.input == (firstUsage == nil ? 0 : 10))
        #expect(firstCheckpoint.tokenUsage.output == (firstUsage == nil ? 0 : 5))
        #expect(firstCheckpoint.tokenUsage.reasoning == 0)
        #expect(firstCheckpoint.tokenUsage.coverage == (firstUsage == nil ? .unavailable : .complete))
        #expect(firstCheckpoint.sessionID == session)

        #expect(secondCheckpoint.iteration == 2)
        #expect(secondCheckpoint.iterationUsage == TokenUsage(input: 17, output: 11))
        #expect(secondCheckpoint.tokenUsage.input == (firstUsage == nil ? 17 : 27))
        #expect(secondCheckpoint.tokenUsage.output == (firstUsage == nil ? 11 : 16))
        #expect(secondCheckpoint.tokenUsage.reasoning == 0)
        #expect(secondCheckpoint.tokenUsage.coverage == (firstUsage == nil ? .partial : .complete))
        guard case let .finished(totals, _, _, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(totals.input == (firstUsage == nil ? 22 : 32))
        #expect(totals.output == (firstUsage == nil ? 16 : 21))
        #expect(totals.coverage == (firstUsage == nil ? .partial : .complete))
    }

    @Test
    func streamSavesSessionAllowlistAfterApproveAlways() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let echoTool = try makeEchoTool()
        let approveEchoCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"first"}"#),
            .finished(usage: TokenUsage(input: 5, output: 3)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [approveEchoCall, finishDeltas])
        let agent = Agent<EmptyContext>(
            client: client, tools: [echoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        var events: [StreamEvent] = []
        for try await event in agent.stream(
            userMessage: "Hi", context: EmptyContext(),
            approvalHandler: { _ in .approveAlways },
            sessionID: session, checkpointer: backend
        ) {
            events.append(event)
        }
        let ids = try await backend.list(session: session)
        let checkpoint = try await backend.load(#require(ids.first))
        #expect(checkpoint.sessionAllowlist.contains("echo"))
    }
}
