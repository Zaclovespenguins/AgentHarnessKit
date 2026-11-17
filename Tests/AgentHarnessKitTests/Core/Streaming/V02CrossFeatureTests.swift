#if canImport(Observation)
    @testable import AgentHarnessKit
    import Foundation
    import Testing

    // v0.2 release tests (task 5.x): the interactions between partial history after cancel (item 1),
    // the terminal answer kept in history (item 2) and `ToolApprovalQueue` (item 4). Each feature has its
    // own suite; these cover the seams between them.

    private struct CrossEchoParams: Codable, SchemaProviding {
        let message: String

        static var jsonSchema: JSONSchema {
            .object(properties: ["message": .string()], required: ["message"])
        }
    }

    private struct CrossEchoOutput: Codable {
        let echoed: String
    }

    /// Parks every caller until `open()`. Used to hold a scripted LLM response open so a test can cancel there.
    private actor CrossGate {
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

    private struct CrossTurn {
        let deltas: [StreamDelta]
        var holdOpen: CrossGate?
    }

    /// Streams scripted turns in order and records every request's messages.
    private actor CrossScriptedClient: LLMClient, ToolCallSurfacingClient {
        nonisolated let providerIdentifier: ProviderIdentifier = .custom("CrossScriptedClient")
        private let turns: [CrossTurn]
        private var turnIndex = 0
        private(set) var requests: [[ChatMessage]] = []

        init(turns: [CrossTurn]) {
            self.turns = turns
        }

        func generate(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            responseFormat _: ResponseFormat?,
            requestContext _: RequestContext?
        ) async throws -> AssistantMessage {
            throw AgentError.llmError(.other("generate is not used by the cross-feature tests"))
        }

        func nextTurn(recording messages: [ChatMessage]) -> CrossTurn? {
            requests.append(messages)
            defer { turnIndex += 1 }
            return turnIndex < turns.count ? turns[turnIndex] : nil
        }

        nonisolated func stream(
            messages: [ChatMessage],
            tools _: [ToolDefinition],
            requestContext _: RequestContext?
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    let turn = await self.nextTurn(recording: messages)
                    for delta in turn?.deltas ?? [] {
                        continuation.yield(delta)
                    }
                    if let gate = turn?.holdOpen {
                        await gate.wait()
                    }
                    continuation.finish()
                }
            }
        }
    }

    /// Streams some text, then fails.
    private struct FailingAfterTextClient: LLMClient {
        let providerIdentifier: ProviderIdentifier = .custom("FailingAfterTextClient")

        func generate(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            responseFormat _: ResponseFormat?,
            requestContext _: RequestContext?
        ) async throws -> AssistantMessage {
            throw AgentError.llmError(.other("generate is not used"))
        }

        func stream(
            messages _: [ChatMessage],
            tools _: [ToolDefinition],
            requestContext _: RequestContext?
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.content("Half an answer"))
                continuation.finish(throwing: AgentError.llmError(.other("boom")))
            }
        }
    }

    private func echoCallDeltas(id: String, message: String = "hi") -> [StreamDelta] {
        [
            .toolCallStart(index: 0, id: id, name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message": "\#(message)"}"#),
            .finished(usage: nil),
        ]
    }

    private func finishDeltas(_ content: String, id: String = "finish_call") -> [StreamDelta] {
        [
            .toolCallStart(index: 0, id: id, name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "\#(content)"}"#),
            .finished(usage: TokenUsage(input: 1, output: 1)),
        ]
    }

    private func makeEcho() throws -> Tool<CrossEchoParams, CrossEchoOutput, EmptyContext> {
        try Tool(
            name: "echo",
            description: "Echoes the message",
            executor: { params, _ in CrossEchoOutput(echoed: params.message) }
        )
    }

    @MainActor
    private func makeApprovalStream(
        client: CrossScriptedClient,
        requireApproval: Bool = true
    ) throws -> AgentStream<EmptyContext> {
        let agent = try Agent<EmptyContext>(
            client: client,
            tools: [makeEcho()],
            configuration: AgentConfiguration(approvalPolicy: requireApproval ? .allTools : .none)
        )
        return AgentStream(agent: agent)
    }

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

    private func waitForPending(_ queue: ToolApprovalQueue, count: Int) async -> [ToolApprovalRequest] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let pending = await queue.pending()
            if pending.count >= count { return pending }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await queue.pending()
    }

    private func waitForEmptyPending(_ queue: ToolApprovalQueue) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await queue.pending().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await queue.pending().isEmpty
    }

    private func toolResults(_ messages: [ChatMessage]) -> [(id: String, content: String)] {
        messages.compactMap { message in
            if case let .tool(id, _, content) = message { return (id: id, content: content) }
            return nil
        }
    }

    private func assistants(_ messages: [ChatMessage]) -> [AssistantMessage] {
        messages.compactMap { message in
            if case let .assistant(assistant) = message { return assistant }
            return nil
        }
    }

    private func request(_ id: String, tool: String = "echo") -> ToolApprovalRequest {
        ToolApprovalRequest(toolCallId: id, toolName: tool, arguments: "{}", toolDescription: "Test tool")
    }

    struct V02CrossFeatureTests {
        // MARK: Item 1 x item 4: cancel while parked in a ToolApprovalQueue

        /// The parked request is removed from the queue and `partialHistory` holds the recorder's synthetic
        /// result, not the queue's `"Cancelled"` deny reason: `cancel()` snapshots before the task is cancelled.
        @MainActor @Test
        func cancelWhileParkedInQueueSynthesizesCancelledResultAndDrainsQueue() async throws {
            let queue = ToolApprovalQueue()
            let client = CrossScriptedClient(turns: [CrossTurn(deltas: echoCallDeltas(id: "echo_1"))])
            let stream = try makeApprovalStream(client: client)

            stream.send("Go", context: EmptyContext(), approvalHandler: queue.handler)
            let parked = await waitForPending(queue, count: 1)
            #expect(parked.map(\.toolCallId) == ["echo_1"])

            stream.cancel()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            let results = toolResults(partial)
            #expect(results.map(\.id) == ["echo_1"])
            #expect(results.first?.content == PartialTurnRecorder.cancelledToolResultContent)
            #expect(await waitForEmptyPending(queue))
        }

        /// After a cancel while parked, the same queue serves the next send, which is built from
        /// `partialHistory`. The new request parks, resolves, and the turn completes.
        @MainActor @Test
        func queueIsReusableForResendFromPartialHistory() async throws {
            let queue = ToolApprovalQueue()
            let first = CrossScriptedClient(turns: [CrossTurn(deltas: echoCallDeltas(id: "echo_1"))])
            let firstStream = try makeApprovalStream(client: first)
            firstStream.send("Go", context: EmptyContext(), approvalHandler: queue.handler)
            _ = await waitForPending(queue, count: 1)
            firstStream.cancel()
            let partial = try #require(firstStream.partialHistory)
            #expect(await waitForEmptyPending(queue))

            let second = CrossScriptedClient(turns: [
                CrossTurn(deltas: echoCallDeltas(id: "echo_2", message: "again")),
                CrossTurn(deltas: finishDeltas("done")),
            ])
            let secondStream = try makeApprovalStream(client: second)
            secondStream.send("Retry", history: partial, context: EmptyContext(), approvalHandler: queue.handler)
            let parked = await waitForPending(queue, count: 1)
            #expect(parked.map(\.toolCallId) == ["echo_2"])
            #expect(await queue.resolve(id: "echo_2", decision: .approve))

            await awaitCondition("resend to finish") { !secondStream.isStreaming }
            #expect(secondStream.error == nil)
            #expect(secondStream.finishReason == .completed)
            #expect(secondStream.partialHistory == nil)
            // The resend's first request carried the synthetic cancelled result exactly once.
            let sent = try #require(await second.requests.first)
            let cancelled = toolResults(sent).count(where: {
                $0.content == PartialTurnRecorder.cancelledToolResultContent
            })
            #expect(cancelled == 1)
        }

        /// The documented Stop flow: `cancel()` first, then `denyAll`. The snapshot is taken while the call is
        /// parked, so it holds the synthetic cancelled result and never the deny reason.
        @MainActor @Test
        func cancelWhileParkedThenDenyAllKeepsTheSyntheticResult() async throws {
            let queue = ToolApprovalQueue()
            let client = CrossScriptedClient(turns: [CrossTurn(deltas: echoCallDeltas(id: "echo_1"))])
            let stream = try makeApprovalStream(client: client)

            stream.send("Go", context: EmptyContext(), approvalHandler: queue.handler)
            _ = await waitForPending(queue, count: 1)
            stream.cancel()
            await queue.denyAll(reason: "Stopped")

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            let results = toolResults(partial)
            #expect(results.map(\.id) == ["echo_1"])
            #expect(results.first?.content == PartialTurnRecorder.cancelledToolResultContent)
            #expect(!results.contains { $0.content.contains("Stopped") })
            #expect(await queue.pending().isEmpty)
        }

        /// The slow path of Stop: `denyAll` first, then `cancel()`. The loop has already recorded the deny
        /// result, so `partialHistory` keeps that result and does not add a synthetic one.
        @MainActor @Test
        func denyAllThenCancelKeepsTheDenyResult() async throws {
            let queue = ToolApprovalQueue()
            let hold = CrossGate()
            let client = CrossScriptedClient(turns: [
                CrossTurn(deltas: echoCallDeltas(id: "echo_1")),
                CrossTurn(deltas: [.content("Thinking")], holdOpen: hold),
            ])
            let stream = try makeApprovalStream(client: client)

            stream.send("Go", context: EmptyContext(), approvalHandler: queue.handler)
            _ = await waitForPending(queue, count: 1)
            await queue.denyAll(reason: "Stopped")
            await awaitCondition("second response to start") { stream.content.contains("Thinking") }
            stream.cancel()
            await hold.open()

            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            let results = toolResults(partial)
            #expect(results.map(\.id) == ["echo_1"])
            #expect(results.first?.content != PartialTurnRecorder.cancelledToolResultContent)
            #expect(results.first?.content.contains("Stopped") == true)
            #expect(assistants(partial).last?.content == "Thinking")
            #expect(await queue.pending().isEmpty)
        }

        /// Pins the 6.3 decision: the recorder survives an error, so a later `cancel()` exposes the failed turn.
        @MainActor @Test
        func cancelAfterErrorExposesFailedTurnAsPartialHistory() async throws {
            let agent = try Agent<EmptyContext>(client: FailingAfterTextClient(), tools: [makeEcho()])
            let stream = AgentStream(agent: agent)

            stream.send("Go", context: EmptyContext())
            await awaitCondition("stream to fail") { !stream.isStreaming }
            #expect(stream.error != nil)

            stream.cancel()
            let partial = try #require(stream.partialHistory)
            try partial.validateForLLMRequest()
            #expect(assistants(partial).last?.content == "Half an answer")
        }

        // MARK: Item 1 x item 2: cancel around a finish call

        /// A cancel that lands after the `finish` call is committed but before `.finished` is handled. The
        /// recorder treats `finish` like any other unanswered call, so the snapshot must still be valid history
        /// that a following run accepts.
        @Test
        func snapshotWithCommittedFinishCallIsValidHistory() throws {
            let recorder = PartialTurnRecorder()
            recorder.begin(baseHistory: [.user("Go")])
            let finishCall = ToolCall(id: "finish_call", name: "finish", arguments: #"{"content":"done"}"#)
            recorder.commitAssistant(AssistantMessage(content: "", toolCalls: [finishCall]))

            let snapshot = recorder.snapshot()
            try snapshot.validateForLLMRequest()
            #expect(toolResults(snapshot).isEmpty)
            #expect(assistants(snapshot).last?.content == "done")
            #expect(assistants(snapshot).last?.toolCalls.isEmpty == true)
        }

        @MainActor @Test
        func resendAfterCancelAtFinishIterationCompletes() async throws {
            let recorder = PartialTurnRecorder()
            recorder.begin(baseHistory: [.user("Go")])
            let finishCall = ToolCall(id: "finish_call", name: "finish", arguments: #"{"content":"done"}"#)
            recorder.commitAssistant(AssistantMessage(content: "", toolCalls: [finishCall]))
            let partial = recorder.snapshot()

            let client = CrossScriptedClient(turns: [CrossTurn(deltas: finishDeltas("second", id: "finish_2"))])
            let stream = try makeApprovalStream(client: client, requireApproval: false)
            stream.send("Again", history: partial, context: EmptyContext())
            await awaitCondition("resend to finish") { !stream.isStreaming }

            #expect(stream.error == nil)
            #expect(stream.finishReason == .completed)
            #expect(assistants(stream.history).last?.content == "second")
        }

        // MARK: Item 2 x AgentStream

        /// A finish-only turn through `AgentStream`: `history` ends with the restored answer, `partialHistory`
        /// stays nil, and sending `history` back puts the answer in the next request exactly once.
        @MainActor @Test
        func finishOnlyTurnThroughAgentStreamRestoresAnswerOnce() async throws {
            let answer = "The answer is 42 (cross-feature-marker)."
            let client = CrossScriptedClient(turns: [
                CrossTurn(deltas: finishDeltas(answer)),
                CrossTurn(deltas: finishDeltas("ok", id: "finish_2")),
            ])
            let stream = try makeApprovalStream(client: client, requireApproval: false)

            stream.send("Question", context: EmptyContext())
            await awaitCondition("first turn to finish") { !stream.isStreaming }
            #expect(stream.partialHistory == nil)
            let last = try #require(assistants(stream.history).last)
            #expect(last.content == answer)
            #expect(last.toolCalls.isEmpty)
            stream.cancel()
            #expect(stream.partialHistory == nil)

            let history = stream.history
            stream.send("Follow-up", history: history, context: EmptyContext())
            await awaitCondition("second turn to finish") { !stream.isStreaming }
            #expect(stream.error == nil)

            let requests = await client.requests
            #expect(requests.count == 2)
            let secondRequest = try #require(requests.last)
            let occurrences = assistants(secondRequest).count(where: { $0.content.contains(answer) })
            #expect(occurrences == 1)
            #expect(assistants(secondRequest).allSatisfy { !$0.toolCalls.contains { $0.name == "finish" } })
        }

        // MARK: Queue edge cases

        /// Runs that share a queue can produce the same `toolCallId` (providers number calls per response).
        /// `resolve` takes the oldest entry, so two resolves with the same id clear both in FIFO order.
        @Test
        func duplicateToolCallIdsResolveOldestFirst() async {
            let queue = ToolApprovalQueue()
            let first = Task { await queue.handler(request("call_1", tool: "a")) }
            _ = await waitForPending(queue, count: 1)
            let second = Task { await queue.handler(request("call_1", tool: "b")) }
            let pending = await waitForPending(queue, count: 2)
            #expect(pending.map(\.toolName) == ["a", "b"])

            #expect(await queue.resolve(id: "call_1", decision: .approve))
            #expect(await first.value == .approve)
            #expect(await queue.pending().map(\.toolName) == ["b"])

            #expect(await queue.resolve(id: "call_1", decision: .deny(reason: "no")))
            #expect(await second.value == .deny(reason: "no"))
            #expect(await queue.resolve(id: "call_1", decision: .approve) == false)
        }

        /// `denyAll` only affects requests waiting at the time; a request that arrives afterwards parks.
        @Test
        func requestArrivingAfterDenyAllStillParks() async {
            let queue = ToolApprovalQueue()
            await queue.denyAll(reason: "Stopped")
            let late = Task { await queue.handler(request("late")) }
            #expect(await waitForPending(queue, count: 1).map(\.toolCallId) == ["late"])
            late.cancel()
            #expect(await late.value == .deny(reason: "Cancelled"))
            #expect(await queue.pending().isEmpty)
        }

        /// A handler call whose task is already cancelled never parks.
        @Test
        func alreadyCancelledTaskNeverParks() async {
            let queue = ToolApprovalQueue()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await queue.handler(request("pre"))
            }
            #expect(await task.value == .deny(reason: "Cancelled"))
            #expect(await queue.pending().isEmpty)
        }

        /// A subscriber that stops iterating is dropped, and later changes still reach other subscribers.
        @Test
        func terminatedSubscriberDoesNotBlockOthers() async {
            let queue = ToolApprovalQueue()
            do {
                var dropped = queue.updates.makeAsyncIterator()
                #expect(await dropped.next() == [])
            }
            var live = queue.updates.makeAsyncIterator()
            #expect(await live.next() == [])

            let task = Task { await queue.handler(request("x")) }
            #expect(await live.next()?.map(\.toolCallId) == ["x"])
            #expect(await queue.resolve(id: "x", decision: .approve))
            #expect(await live.next() == [])
            #expect(await task.value == .approve)
        }
    }
#endif
