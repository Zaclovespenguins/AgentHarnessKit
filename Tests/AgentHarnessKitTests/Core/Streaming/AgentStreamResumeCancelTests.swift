#if canImport(Observation)
    @testable import AgentHarnessKit
    import Foundation
    import Testing

    // v0.2 Phase 6 (6.7, 6.8): `partialHistory` after `cancel()` during `AgentStream.resume(from:)`.

    /// Parks every caller until `open()`.
    private actor ResumeGate {
        private var isOpen = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = parked
            parked = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Streams `text`, then holds the response open at `hold`. Counts requests.
    private actor HoldingTextClient: LLMClient {
        nonisolated let providerIdentifier: ProviderIdentifier = .custom("HoldingTextClient")
        private let text: String
        private let hold: ResumeGate
        private(set) var requestCount = 0

        init(text: String, hold: ResumeGate) {
            self.text = text
            self.hold = hold
        }

        func generate(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            responseFormat _: ResponseFormat?,
            requestContext _: RequestContext?
        ) async throws -> AssistantMessage {
            throw AgentError.llmError(.other("generate is not used"))
        }

        private func countRequest() {
            requestCount += 1
        }

        nonisolated func stream(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            requestContext _: RequestContext?
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    await self.countRequest()
                    continuation.yield(.content(self.text))
                    await self.hold.wait()
                    continuation.finish()
                }
            }
        }
    }

    private func saveCheckpoint(
        _ messages: [ChatMessage],
        to checkpointer: some AgentCheckpointer
    ) async throws -> CheckpointID {
        let checkpointID = CheckpointID()
        try await checkpointer.save(AgentCheckpoint(
            messages: messages,
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 1, output: 1)),
            iterationUsage: nil,
            sessionID: SessionID(), runID: RunID(), checkpointID: checkpointID
        ))
        return checkpointID
    }

    @MainActor
    private func awaitCondition(_ description: String, _ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private let echoCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message":"hi"}"#)

    struct AgentStreamResumeCancelTests {
        /// 6.7: a cancel while the checkpoint is still loading leaves `partialHistory` nil, and the resume that
        /// was in flight stops without starting the turn.
        @MainActor @Test
        func cancelBeforeCheckpointLoadsLeavesPartialHistoryNil() async throws {
            let checkpointID = CheckpointID()
            let checkpointer = GatedCheckpointer(gating: .load, loadResult: AgentCheckpoint(
                messages: [.user("Go"), .assistant(AssistantMessage(content: "", toolCalls: [echoCall])),
                           .tool(id: "call_1", name: "echo", content: "hi")],
                iteration: 1,
                tokenUsage: makeTokenUsageTotals(TokenUsage(input: 1, output: 1)),
                iterationUsage: nil,
                sessionID: SessionID(), runID: RunID(), checkpointID: checkpointID
            ))
            let client = HoldingTextClient(text: "unused", hold: ResumeGate())
            let stream = AgentStream(agent: Agent<EmptyContext>(client: client, tools: []))

            let resuming = Task { @MainActor in
                try await stream.resume(from: checkpointID, checkpointer: checkpointer, context: EmptyContext())
            }
            await checkpointer.awaitGateEntered()
            stream.cancel()
            #expect(stream.partialHistory == nil)

            await checkpointer.release()
            try await resuming.value
            #expect(!stream.isStreaming)
            #expect(stream.history.isEmpty)
            #expect(stream.partialHistory == nil)
            #expect(await client.requestCount == 0)
        }

        /// 6.7: a cancel mid-iteration after resume gives the checkpointed messages plus the in-flight text.
        @MainActor @Test
        func cancelMidIterationAfterResumeKeepsCheckpointAndInFlightText() async throws {
            let checkpointer = InMemoryCheckpointer()
            let checkpointed: [ChatMessage] = [
                .user("Go"),
                .assistant(AssistantMessage(content: "", toolCalls: [echoCall])),
                .tool(id: "call_1", name: "echo", content: "hi"),
            ]
            let checkpointID = try await saveCheckpoint(checkpointed, to: checkpointer)
            let hold = ResumeGate()
            let client = HoldingTextClient(text: "In flight", hold: hold)
            let stream = AgentStream(agent: Agent<EmptyContext>(client: client, tools: []))

            try await stream.resume(from: checkpointID, checkpointer: checkpointer, context: EmptyContext())
            await awaitCondition("resumed text to stream") { stream.content == "In flight" }
            stream.cancel()
            await hold.open()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(partial == checkpointed + [.assistant(AssistantMessage(content: "In flight"))])
        }

        /// 6.8: a checkpoint whose history ends with a tool call that has no result is rejected by `resume`
        /// before the turn starts, so there is nothing to snapshot: `partialHistory` stays nil after a cancel.
        @MainActor @Test
        func checkpointEndingWithUnansweredCallIsRejectedAndLeavesNoPartialHistory() async throws {
            let checkpointer = InMemoryCheckpointer()
            let checkpointID = try await saveCheckpoint(
                [.user("Go"), .assistant(AssistantMessage(content: "", toolCalls: [echoCall]))],
                to: checkpointer
            )
            let client = HoldingTextClient(text: "unused", hold: ResumeGate())
            let stream = AgentStream(agent: Agent<EmptyContext>(client: client, tools: []))

            do {
                try await stream.resume(from: checkpointID, checkpointer: checkpointer, context: EmptyContext())
                Issue.record("Expected resume to reject the unanswered tool call")
            } catch let AgentError.malformedHistory(reason) {
                #expect(reason == .unfinishedToolCallBatch(ids: ["call_1"]))
            }
            stream.cancel()
            #expect(stream.partialHistory == nil)
            #expect(!stream.isStreaming)
            #expect(await client.requestCount == 0)
        }

        /// 6.5: the same resume through the public `Agent.resume(partialTurnRecorder:)`, without `AgentStream`.
        @Test
        func agentResumeRecordsIntoCallerRecorder() async throws {
            let checkpointer = InMemoryCheckpointer()
            let checkpointed: [ChatMessage] = [
                .user("Go"),
                .assistant(AssistantMessage(content: "", toolCalls: [echoCall])),
                .tool(id: "call_1", name: "echo", content: "hi"),
            ]
            let checkpointID = try await saveCheckpoint(checkpointed, to: checkpointer)
            let hold = ResumeGate()
            let agent = Agent<EmptyContext>(client: HoldingTextClient(text: "In flight", hold: hold), tools: [])
            let recorder = PartialTurnRecorder()

            let events = try await agent.resume(
                from: checkpointID, checkpointer: checkpointer, context: EmptyContext(),
                partialTurnRecorder: recorder
            )
            let consumer = Task {
                for try await _ in events {}
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while recorder.snapshot().count < checkpointed.count + 1, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            let snapshot = recorder.snapshot()
            consumer.cancel()
            await hold.open()
            _ = await consumer.result

            try snapshot.validateForLLMRequest()
            #expect(snapshot == checkpointed + [.assistant(AssistantMessage(content: "In flight"))])
        }
    }
#endif
