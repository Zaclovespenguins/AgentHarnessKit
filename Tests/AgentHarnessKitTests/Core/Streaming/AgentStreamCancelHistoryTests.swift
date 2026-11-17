#if canImport(Observation)
    @testable import AgentHarnessKit
    import Foundation
    import Testing

    private struct CancelHistoryEchoParams: Codable, SchemaProviding {
        let message: String

        static var jsonSchema: JSONSchema {
            .object(properties: ["message": .string()], required: ["message"])
        }
    }

    private struct CancelHistoryEchoOutput: Codable {
        let echoed: String
    }

    /// One-shot latch. The producer calls `arrive()`, which records the arrival and parks until `open()`.
    /// The test calls `awaitArrival()` to learn that the producer reached the latch, without sleeping.
    private actor CancelHistoryLatch {
        private var isOpen = false
        private var hasArrived = false
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

        func arrive() async {
            hasArrived = true
            let waiters = arrivalWaiters
            arrivalWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            guard !isOpen else { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func awaitArrival() async {
            guard !hasArrived else { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }

        /// Releases everything parked here. Called at the end of each test so no producer task outlives it.
        func open() {
            isOpen = true
            let waiters = parked
            parked = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// One scripted LLM response. When `holdOpen` is set, the stream parks at that latch after yielding
    /// `deltas` and never finishes until the test opens it, which is how a test cancels mid-response.
    private struct CancelHistoryTurn {
        let deltas: [StreamDelta]
        let holdOpen: CancelHistoryLatch?
    }

    private actor CancelHistoryMockLLMClient: LLMClient, ToolCallSurfacingClient {
        nonisolated let providerIdentifier: ProviderIdentifier = .custom("CancelHistoryMockLLMClient")
        private let turns: [CancelHistoryTurn]
        private var turnIndex = 0

        init(turns: [CancelHistoryTurn]) {
            self.turns = turns
        }

        func generate(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            responseFormat _: ResponseFormat?,
            requestContext _: RequestContext?
        ) async throws -> AssistantMessage {
            throw AgentError.llmError(.other("generate is not used by the cancel-history tests"))
        }

        func nextTurn() -> CancelHistoryTurn? {
            defer { turnIndex += 1 }
            return turnIndex < turns.count ? turns[turnIndex] : nil
        }

        nonisolated func stream(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            requestContext _: RequestContext?
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    let turn = await self.nextTurn()
                    for delta in turn?.deltas ?? [] {
                        continuation.yield(delta)
                    }
                    if let latch = turn?.holdOpen {
                        await latch.arrive()
                    }
                    continuation.finish()
                }
            }
        }
    }

    @MainActor
    private func makeStream(
        turns: [CancelHistoryTurn],
        tools: [any AnyTool<EmptyContext>] = []
    ) -> AgentStream<EmptyContext> {
        let client = CancelHistoryMockLLMClient(turns: turns)
        return AgentStream(agent: Agent<EmptyContext>(client: client, tools: tools))
    }

    private func makeEchoTool(
        latch: CancelHistoryLatch? = nil
    ) throws -> Tool<CancelHistoryEchoParams, CancelHistoryEchoOutput, EmptyContext> {
        try Tool(
            name: "echo",
            description: "Echoes the message",
            executor: { params, _ in
                if let latch {
                    await latch.arrive()
                }
                return CancelHistoryEchoOutput(echoed: params.message)
            }
        )
    }

    private func finishDeltas(_ content: String) -> [StreamDelta] {
        [
            .toolCallStart(index: 0, id: "finish_call", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "\#(content)"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ]
    }

    /// Bounded poll on observable state. Records an issue instead of hanging if the condition never holds.
    @MainActor
    private func awaitCondition(_ description: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    private func awaitStreamIdle(_ stream: AgentStream<EmptyContext>) async {
        await awaitCondition("stream to finish") { !stream.isStreaming }
    }

    /// Sends `history` plus a fresh user message through a new stream whose client answers with one finish call.
    @MainActor
    private func expectResendCompletes(
        history: [ChatMessage],
        tools: [any AnyTool<EmptyContext>] = []
    ) async {
        let stream = makeStream(turns: [CancelHistoryTurn(deltas: finishDeltas("resent"), holdOpen: nil)], tools: tools)
        stream.send("Continue", history: history, context: EmptyContext())
        await awaitStreamIdle(stream)
        if let error = stream.error {
            Issue.record("Resend with partial history failed: \(error)")
        }
        #expect(stream.finishReason == .completed)
    }

    private func toolMessages(_ messages: [ChatMessage]) -> [(id: String, content: String)] {
        var result: [(id: String, content: String)] = []
        for message in messages {
            if case let .tool(id, _, content) = message {
                result.append((id: id, content: content))
            }
        }
        return result
    }

    private func assistantMessages(_ messages: [ChatMessage]) -> [AssistantMessage] {
        var result: [AssistantMessage] = []
        for message in messages {
            if case let .assistant(assistant) = message {
                result.append(assistant)
            }
        }
        return result
    }

    struct AgentStreamCancelHistoryTests {
        private let priorHistory: [ChatMessage] = [
            .user("Earlier question"),
            .assistant(AssistantMessage(content: "Earlier answer")),
        ]

        @MainActor @Test
        func cancelMidTextKeepsTextSoFarAsValidHistory() async throws {
            let hold = CancelHistoryLatch()
            let turn = CancelHistoryTurn(
                deltas: [.content("Hel"), .content("lo")],
                holdOpen: hold
            )
            let stream = makeStream(turns: [turn])

            stream.send("Go", history: priorHistory, context: EmptyContext())
            await awaitCondition("text 'Hello' to be observed") { stream.content == "Hello" }
            stream.cancel()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(partial.starts(with: priorHistory + [.user("Go")]))
            let last = assistantMessages(partial).last
            #expect(last?.content == "Hello")
            #expect(last?.toolCalls.isEmpty == true)

            await hold.open()
            await expectResendCompletes(history: partial)
        }

        @MainActor @Test
        func cancelMidToolCallDropsCallWhoseArgumentsAreStillStreaming() async throws {
            let hold = CancelHistoryLatch()
            let echo = try makeEchoTool()
            let turn = CancelHistoryTurn(
                deltas: [
                    .content("Checking"),
                    .toolCallStart(index: 0, id: "echo_call", name: "echo", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"message": "hel"#),
                ],
                holdOpen: hold
            )
            let stream = makeStream(turns: [turn], tools: [echo])

            stream.send("Go", history: priorHistory, context: EmptyContext())
            await awaitCondition("tool call start to be observed") {
                stream.toolCalls.count == 1 && stream.content == "Checking"
            }
            stream.cancel()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(partial.starts(with: priorHistory + [.user("Go")]))
            let noToolCalls = assistantMessages(partial).allSatisfy(\.toolCalls.isEmpty)
            #expect(noToolCalls)
            #expect(toolMessages(partial).isEmpty)
            #expect(assistantMessages(partial).last?.content == "Checking")

            await hold.open()
        }

        @MainActor @Test
        func cancelDuringToolExecutionSynthesizesCancelledResult() async throws {
            let toolLatch = CancelHistoryLatch()
            let echo = try makeEchoTool(latch: toolLatch)
            let turn = CancelHistoryTurn(
                deltas: [
                    .toolCallStart(index: 0, id: "echo_call", name: "echo", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
                    .finished(usage: nil),
                ],
                holdOpen: nil
            )
            let stream = makeStream(turns: [turn], tools: [echo])

            stream.send("Go", history: priorHistory, context: EmptyContext())
            await toolLatch.awaitArrival()
            stream.cancel()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(partial.starts(with: priorHistory + [.user("Go")]))

            let results = toolMessages(partial)
            #expect(results.count == 1)
            #expect(results.first?.id == "echo_call")
            #expect(PartialTurnRecorder.cancelledToolResultContent == "Cancelled by user before this tool returned.")
            #expect(results.first?.content == PartialTurnRecorder.cancelledToolResultContent)
            #expect(assistantMessages(partial).contains { call in
                call.toolCalls.contains { $0.id == "echo_call" }
            })

            await toolLatch.open()
            await expectResendCompletes(history: partial, tools: [echo])
        }

        @MainActor @Test
        func cancelAfterFullIterationKeepsCompletedIterationAndPartialSecond() async throws {
            let hold = CancelHistoryLatch()
            let echo = try makeEchoTool()
            let firstTurn = CancelHistoryTurn(
                deltas: [
                    .content("Let me check. "),
                    .toolCallStart(index: 0, id: "echo_1", name: "echo", kind: .function),
                    .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
                    .finished(usage: nil),
                ],
                holdOpen: nil
            )
            let secondTurn = CancelHistoryTurn(deltas: [.content("Partial")], holdOpen: hold)
            let stream = makeStream(turns: [firstTurn, secondTurn], tools: [echo])

            stream.send("Go", history: priorHistory, context: EmptyContext())
            await awaitCondition("second iteration text to be observed") {
                stream.content.contains("Partial")
            }
            stream.cancel()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(partial.starts(with: priorHistory + [.user("Go")]))

            let firstAssistant = partial.dropFirst(priorHistory.count + 1).first
            guard case let .assistant(assistant)? = firstAssistant else {
                Issue.record("Expected the first iteration's assistant message after the user message")
                await hold.open()
                return
            }
            #expect(assistant.toolCalls.map(\.id) == ["echo_1"])

            let results = toolMessages(partial)
            #expect(results.map(\.id) == ["echo_1"])
            #expect(results.first?.content != PartialTurnRecorder.cancelledToolResultContent)

            #expect(assistantMessages(partial).last?.content == "Partial")
            #expect(assistantMessages(partial).last?.toolCalls.isEmpty == true)

            await hold.open()
            await expectResendCompletes(history: partial, tools: [echo])
        }

        @MainActor @Test
        func cancelAfterFinishedTurnLeavesPartialHistoryNil() async {
            let stream = makeStream(turns: [CancelHistoryTurn(deltas: finishDeltas("done"), holdOpen: nil)])

            stream.send("Go", context: EmptyContext())
            await awaitStreamIdle(stream)
            #expect(stream.finishReason == .completed)

            stream.cancel()
            #expect(stream.partialHistory == nil)
        }

        @MainActor @Test
        func cancelRightAfterSendNeverExposesEmptyHistory() {
            let stream = makeStream(turns: [CancelHistoryTurn(deltas: finishDeltas("done"), holdOpen: nil)])

            stream.send("Go", context: EmptyContext())
            stream.cancel()

            // The producer task may already have called `begin` on another thread, which records the user
            // message. Either outcome is valid: nil when nothing was recorded, or the turn's base history.
            // An empty array is never valid, because it would drop the user message on the next send.
            if let partial = stream.partialHistory {
                #expect(!partial.isEmpty)
                #expect(assistantMessages(partial).isEmpty)
            }
            #expect(stream.partialHistory != [])
        }
    }
#endif
