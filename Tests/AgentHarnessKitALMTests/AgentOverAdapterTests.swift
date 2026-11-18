@testable import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation
import Testing

private struct AddParams: Codable, SchemaProviding {
    // swiftlint:disable identifier_name
    let a: Int
    let b: Int
    // swiftlint:enable identifier_name

    static var jsonSchema: JSONSchema {
        addTool.parametersSchema
    }
}

private struct AddOutput: Codable {
    let sum: Int
}

private func makeAgent(
    _ server: MockServer,
    configuration: AgentConfiguration = AgentConfiguration()
) throws -> Agent<EmptyContext> {
    let add = try Tool<AddParams, AddOutput, EmptyContext>(
        name: "add", description: "Add two integers and return the sum.",
        executor: { params, _ in AddOutput(sum: params.a + params.b) }
    )
    return Agent(client: mockClient(server), tools: [add], configuration: configuration)
}

private func awaitPending(_ queue: ToolApprovalQueue, count: Int) async -> [ToolApprovalRequest] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        let pending = await queue.pending()
        if pending.count == count {
            return pending
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await queue.pending()
}

private func enqueueAddThenFinish(_ server: MockServer) {
    server.enqueue(.toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#), .usage(input: 20, output: 5))
    server.enqueue(
        .toolCall(id: "call_2", name: "finish", arguments: #"{"content":"The sum is 5."}"#),
        .usage(input: 30, output: 6)
    )
}

/// Completes once `fire()` has been called, so a test can wait for a point in the stream without sleeping.
private actor StreamPointSignal {
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

private func isEmptyAssistant(_ message: ChatMessage) -> Bool {
    guard case let .assistant(assistant) = message else { return false }
    return assistant.content.isEmpty && assistant.toolCalls.isEmpty
}

private actor StreamPointHistory {
    private(set) var value: [ChatMessage]?

    func set(_ history: [ChatMessage]) {
        value = history
    }
}

/// The whole stack on the mock: Agent loop -> HarnessModelClient -> ALM -> HTTP.
@Suite(.serialized)
struct AgentOverAdapterTests {
    @Test func runExecutesTheToolAndFinishes() async throws {
        let server = try MockServer()
        enqueueAddThenFinish(server)
        let result = try await makeAgent(server).run(userMessage: "What is 2 + 3?", context: EmptyContext())

        #expect(result.content == "The sum is 5.")
        #expect(result.finishReason == .completed)
        #expect(result.iterations == 2)
        #expect(result.totalTokenUsage.input == 50)
        #expect(server.requestCount == 2)
        let first = server.requestJSON(0)["tools"] as? [[String: Any]] ?? []
        let names = first.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(Set(names) == ["add", "finish"])
        let sent = server.requestJSON(1)["messages"] as? [[String: Any]] ?? []
        #expect(sent.last?["role"] as? String == "tool")
        #expect(jsonObject(sent.last?["content"] as? String ?? "") == ["sum": 5])
    }

    @Test func streamExecutesTheToolAndFinishes() async throws {
        let server = try MockServer()
        enqueueAddThenFinish(server)
        var kinds: [String] = []
        var finishedContent: String?
        var toolResult: String?
        for try await event in try makeAgent(server).stream(userMessage: "What is 2 + 3?", context: EmptyContext()) {
            switch event.kind {
            case .toolCallStarted: kinds.append("started")
            case let .toolCallCompleted(_, name, result):
                kinds.append("completed:\(name)")
                toolResult = result.content
            case .iterationCompleted: kinds.append("iteration")
            case let .finished(_, content, _, _):
                kinds.append("finished")
                finishedContent = content
            default: break
            }
        }

        #expect(kinds == ["started", "iteration", "completed:add", "iteration", "finished"])
        #expect(jsonObject(toolResult ?? "") == ["sum": 5])
        #expect(finishedContent == "The sum is 5.")
        #expect(server.requestCount == 2)
    }

    @Test func followUpRequestBodyHoldsTheFinishAnswerOnce() async throws {
        let server = try MockServer()
        let answer = "The sum is five (terminal-answer-marker)."
        server.enqueue(
            .toolCall(id: "call_1", name: "finish", arguments: #"{"content":"\#(answer)"}"#),
            .usage(input: 10, output: 3)
        )
        server.enqueue(.text("Anything else?"), .usage(input: 20, output: 3))
        let agent = try makeAgent(server)

        let first = try await agent.run(userMessage: "What is 2 + 3?", context: EmptyContext())
        guard case let .assistant(restored) = first.history.last else {
            Issue.record("Expected the finish answer to end history")
            return
        }
        #expect(restored.content == answer)
        #expect(restored.toolCalls.isEmpty)

        _ = try await agent.run(userMessage: "Thanks", history: first.history, context: EmptyContext())

        #expect(server.requestCount == 2)
        let sent = server.requestJSON(1)["messages"] as? [[String: Any]] ?? []
        let body = try String(decoding: JSONSerialization.data(withJSONObject: sent), as: UTF8.self)
        #expect(body.components(separatedBy: answer).count - 1 == 1)
        let assistants = sent.filter { $0["role"] as? String == "assistant" }
        #expect(assistants.count == 1)
        #expect(assistants.first?["tool_calls"] == nil)
    }

    /// Iteration 2 is an empty streamed response (`finish_reason: stop`, no text, no tool calls). Its empty
    /// assistant message is committed before `.iterationCompleted`, so the consumer cancels at that point and
    /// the recorder must drop the empty message from its snapshot. The turn may already have finished by the
    /// time the cancel lands; nothing else writes to the recorder after `.iterationCompleted`, so the outcome holds.
    @Test func cancelAfterEmptyStopResponseLeavesNoEmptyAssistantInSnapshot() async throws {
        let server = try MockServer()
        server.enqueue(.toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#), .usage(input: 20, output: 5))
        server.enqueue(.usage(input: 30, output: 1))
        let agent = try makeAgent(server)
        let recorder = PartialTurnRecorder()
        var options = InvocationOptions(
            tokenBudget: nil, requestContext: nil,
            systemPromptOverride: "System", approvalHandler: nil,
            sessionID: SessionID(), runID: RunID()
        )
        options.partialTurnRecorder = recorder
        let emptyResponseReceived = StreamPointSignal()
        let eventHistory = StreamPointHistory()

        let consumer = Task {
            for try await event in agent.stream(
                userMessage: .user("What is 2 + 3?"), history: [], context: EmptyContext(), options: options
            ) {
                if case let .iterationCompleted(_, iteration, history) = event.kind, iteration == 2 {
                    await eventHistory.set(history)
                    await emptyResponseReceived.fire()
                }
            }
        }
        await emptyResponseReceived.wait()
        consumer.cancel()
        _ = await consumer.result

        // The recorder saw the empty response: the event history ends with an empty assistant message.
        let delivered = try #require(await eventHistory.value)
        #expect(delivered.count == 5)
        #expect(delivered.last.map(isEmptyAssistant) == true)

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        #expect(snapshot.prefix(2) == [.system("System"), .user("What is 2 + 3?")])
        #expect(snapshot.count == 4)
        #expect(snapshot.last == .tool(id: "call_1", name: "add", content: #"{"sum":5}"#))
        #expect(!snapshot.contains(where: isEmptyAssistant))
    }

    /// 6.14: v0.2 items 1 and 4 over the real adapter. The call parks in a `ToolApprovalQueue`; the consumer takes
    /// the snapshot through the public `partialTurnRecorder:` and then cancels. The snapshot holds the synthetic
    /// cancelled result, the queue drains, and the tool never runs (no second request).
    @Test func cancelWhileParkedInQueueGivesSyntheticResultOverAdapter() async throws {
        let server = try MockServer()
        enqueueAddThenFinish(server)
        let agent = try makeAgent(server, configuration: AgentConfiguration(approvalPolicy: .allTools))
        let queue = ToolApprovalQueue()
        let recorder = PartialTurnRecorder()

        let consumer = Task {
            for try await _ in agent.stream(
                userMessage: "What is 2 + 3?", context: EmptyContext(),
                approvalHandler: queue.handler, partialTurnRecorder: recorder
            ) {}
        }
        let parked = await awaitPending(queue, count: 1)
        #expect(parked.map(\.toolCallId) == ["call_1"])

        let snapshot = recorder.snapshot()
        consumer.cancel()
        _ = await consumer.result

        try snapshot.validateForLLMRequest()
        #expect(snapshot.first == .user("What is 2 + 3?"))
        #expect(snapshot.last == .tool(
            id: "call_1", name: "add", content: PartialTurnRecorder.cancelledToolResultContent
        ))
        #expect(await awaitPending(queue, count: 0).isEmpty)
        #expect(server.requestCount == 1)
    }
}
