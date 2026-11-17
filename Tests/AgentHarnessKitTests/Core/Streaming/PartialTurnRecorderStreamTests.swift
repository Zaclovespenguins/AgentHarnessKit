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

/// Completes once `fire()` has been called. Lets a test wait for a point inside the stream without sleeping.
private actor OneShotSignal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        fired = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// Streams one text delta, then parks until the consumer cancels. Cancelling the consumer terminates the
/// stream through `onTermination`, which cancels the parked producer.
private struct ParkingTextClient: LLMClient, ToolCallSurfacingClient {
    let providerIdentifier: ProviderIdentifier = .custom("ParkingTextClient")
    let contextWindowSize: Int? = nil

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("ParkingTextClient only streams"))
    }

    func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                continuation.yield(.content("Hel"))
                // Parks until the consumer cancels. The sleep is cancelled, not waited on for timing.
                try? await Task.sleep(for: .seconds(3600))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

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

    @Test
    func snapshotAfterCancelMidTextKeepsTextSoFar() async throws {
        let agent = Agent<EmptyContext>(client: ParkingTextClient(), tools: [])
        let recorder = PartialTurnRecorder()
        var options = InvocationOptions(
            tokenBudget: nil, requestContext: nil,
            systemPromptOverride: "System", approvalHandler: nil
        )
        options.partialTurnRecorder = recorder
        let firstDelta = OneShotSignal()

        let consumer = Task {
            for try await event in agent.stream(
                userMessage: .user("Go"), history: [], context: EmptyContext(), options: options
            ) {
                if case .delta = event.kind {
                    await firstDelta.fire()
                }
            }
        }
        await firstDelta.wait()
        consumer.cancel()
        _ = await consumer.result

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        #expect(snapshot.prefix(2) == [.system("System"), .user("Go")])
        #expect(snapshot.count == 3)
        #expect(snapshot.last == .assistant(AssistantMessage(content: "Hel")))
    }

    @Test
    func snapshotAfterCancelDuringToolExecutionSynthesizesCancelledResult() async throws {
        let entered = OneShotSignal()
        let gatedTool = try Tool<RecorderEchoParams, RecorderEchoOutput, EmptyContext>(
            name: "gated",
            description: "Waits until cancelled",
            executor: { _, _ in
                await entered.fire()
                // Parks until the agent task is cancelled. The sleep is cancelled, not waited on for timing.
                try await Task.sleep(for: .seconds(3600))
                return RecorderEchoOutput(echoed: "never")
            }
        )
        let client = StreamingMockLLMClient(streamSequences: [[
            .toolCallStart(index: 0, id: "call_1", name: "gated", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]])
        let agent = Agent<EmptyContext>(client: client, tools: [gatedTool])
        let recorder = PartialTurnRecorder()
        var options = InvocationOptions(
            tokenBudget: nil, requestContext: nil,
            systemPromptOverride: "System", approvalHandler: nil
        )
        options.partialTurnRecorder = recorder

        let consumer = Task {
            for try await _ in agent.stream(
                userMessage: .user("Go"), history: [], context: EmptyContext(), options: options
            ) {}
        }
        await entered.wait()
        consumer.cancel()
        _ = await consumer.result

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        #expect(snapshot.prefix(2) == [.system("System"), .user("Go")])
        #expect(snapshot.count == 4)
        guard snapshot.count == 4 else { return }
        guard case let .assistant(assistant) = snapshot[2] else {
            Issue.record("Expected the tool-calling assistant message at index 2")
            return
        }
        #expect(assistant.toolCalls.map(\.id) == ["call_1"])
        #expect(snapshot[3] == .tool(
            id: "call_1", name: "gated", content: PartialTurnRecorder.cancelledToolResultContent
        ))
    }
}
