@testable import AgentHarnessKit
import Foundation
import Testing

private struct RecorderEchoParams: Codable, SchemaProviding {
    let message: String

    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct RecorderEchoOutput: Codable {
    let echoed: String
}

@Suite
struct PartialTurnRecorderStreamTests {
    @Test
    func snapshotAfterCompletedToolCallTurnMatchesFinishedHistory() async throws {
        let echoTool = try Tool<RecorderEchoParams, RecorderEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes",
            executor: { params, _ in RecorderEchoOutput(echoed: params.message) }
        )
        let firstDeltas: [StreamDelta] = [
            .content("Let me check. "),
            .toolCallStart(index: 0, id: "call_1", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondDeltas: [StreamDelta] = [
            .content("Done."),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstDeltas, secondDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])

        let recorder = PartialTurnRecorder()
        var options = InvocationOptions(
            tokenBudget: nil, requestContext: nil,
            systemPromptOverride: nil, approvalHandler: nil
        )
        options.partialTurnRecorder = recorder

        var finishedHistory: [ChatMessage]?
        for try await event in agent.stream(
            userMessage: .user("Go"), history: [], context: EmptyContext(), options: options
        ) {
            if case let .finished(_, _, _, history) = event.kind {
                finishedHistory = history
            }
        }

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        #expect(finishedHistory != nil)
        #expect(snapshot == finishedHistory)
    }
}
