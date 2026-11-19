@testable import AgentHarnessKit
import Foundation
import Testing

@MainActor
private func awaitStreamCompletion(_ stream: AgentStream<some ToolContext>) async {
    await waitUntil("stream to finish") { !stream.isStreaming }
}

@MainActor
private func waitForBufferedCursor(
    _ stream: AgentStream<some ToolContext>,
    atLeast threshold: UInt64,
    timeout: Duration = .seconds(2)
) async {
    await waitUntil("buffered cursor >= \(threshold)", timeout: timeout) {
        guard let value = await stream.bufferedCursor else { return false }
        return value >= threshold
    }
}

private func collectReplay(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let firstSendDeltas: [StreamDelta] = [
    .content("first"),
    .toolCallStart(index: 0, id: "call_1", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done1"}"#),
    .finished(usage: TokenUsage(input: 10, output: 5)),
]

private let secondSendDeltas: [StreamDelta] = [
    .content("second"),
    .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done2"}"#),
    .finished(usage: TokenUsage(input: 20, output: 10)),
]

@MainActor
private func makeBufferedStream(
    sequences: [[StreamDelta]] = [firstSendDeltas],
    capacity: Int? = 64
) -> AgentStream<EmptyContext> {
    let client = StreamingMockLLMClient(streamSequences: sequences)
    let agent = Agent<EmptyContext>(client: client, tools: [])
    return AgentStream(agent: agent, bufferCapacity: capacity)
}

struct AgentStreamReplayTests {
    @MainActor @Test
    func bufferDisabledReplayThrowsBufferDisabled() async {
        let stream = makeBufferedStream(capacity: nil)
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        do {
            _ = try await collectReplay(stream.replay(from: 0))
            Issue.record("Expected BufferReplayError.bufferDisabled")
        } catch BufferReplayError.bufferDisabled {
        } catch {
            Issue.record("Expected BufferReplayError.bufferDisabled, got \(error)")
        }
    }

    @MainActor @Test(arguments: [TokenUsage(input: 10, output: 5), nil])
    func bufferEnabledReplayYieldsRecordedEvents(usage: TokenUsage?) async throws {
        let stream = makeBufferedStream(sequences: [
            Array(firstSendDeltas.dropLast()) + [.finished(usage: usage)],
        ])
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let originalTotals = stream.tokenUsage
        let events = try await collectReplay(stream.replay(from: 0))
        _ = try await collectReplay(stream.replay(from: 0))
        #expect(stream.tokenUsage == originalTotals)
        let deltaEvent = events.first { event in
            if case .delta("first") = event.kind {
                return true
            }
            return false
        }
        #expect(deltaEvent != nil)

        guard let finishedEvent = events.last(where: { event in
            if case .finished = event.kind {
                return true
            }
            return false
        }), case let .finished(totalUsage, content, _, _) = finishedEvent.kind else {
            Issue.record("Expected .finished event in replay")
            return
        }
        #expect(content == "done1")
        #expect(totalUsage.input == (usage == nil ? 0 : 10))
        #expect(totalUsage.output == (usage == nil ? 0 : 5))
        #expect(totalUsage.coverage == (usage == nil ? .unavailable : .complete))
        #expect(totalUsage.cacheReadCoverage == .unavailable)
        #expect(stream.tokenUsage == totalUsage)
        let iterations = events.filter {
            if case .iterationCompleted = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(iterations.count == 1)
        guard case let .iterationCompleted(replayedUsage, iteration, history) = iterations.first?.kind else {
            Issue.record("Expected iterationCompleted in replay")
            return
        }
        #expect(replayedUsage == usage)
        #expect(iteration == 1)
        #expect(history.first == .user("Hi"))
        #expect(iterations.first?.origin == .live)
        #expect(stream.iterationUsages == [usage])
        #expect(stream.iterationsReplayed == 0)

        let cursor = await stream.bufferedCursor
        #expect(cursor == UInt64(events.count))
    }

    @MainActor @Test
    func cursorBasedReplayPreservesEnvelopeIdentity() async throws {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let allEvents = try await collectReplay(stream.replay(from: 0))
        #expect(allEvents.count >= 2)

        let tail = try await collectReplay(stream.replay(from: 1))
        #expect(tail.count == allEvents.count - 1)
        #expect(tail.first?.id == allEvents[1].id)
    }

    @MainActor @Test
    func backToBackSendsDoNotLeakBufferEvents() async throws {
        let stream = makeBufferedStream(sequences: [firstSendDeltas, secondSendDeltas])

        stream.send("First", context: EmptyContext())
        await awaitStreamCompletion(stream)

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collectReplay(stream.replay(from: 0))
        guard let finishEvent = events.last(where: { event in
            if case .finished = event.kind {
                return true
            }
            return false
        }), case let .finished(_, finishContent, _, _) = finishEvent.kind else {
            Issue.record("Expected finished event in replay")
            return
        }
        #expect(finishContent == "done2")

        for event in events {
            if case let .delta(text) = event.kind {
                #expect(text != "first")
            }
        }
    }

    @MainActor @Test
    func midStreamCancelThenNewSendShowsOnlyNewSendInBuffer() async throws {
        let stream = makeBufferedStream(sequences: [firstSendDeltas, secondSendDeltas])

        stream.send("First", context: EmptyContext())
        await waitForBufferedCursor(stream, atLeast: 1)

        stream.cancel()

        stream.send("Second", context: EmptyContext())
        await awaitStreamCompletion(stream)

        let events = try await collectReplay(stream.replay(from: 0))
        let deltaTexts = events.compactMap { event -> String? in
            if case let .delta(text) = event.kind {
                return text
            }
            return nil
        }
        #expect(!deltaTexts.contains("first"))
        #expect(deltaTexts.contains("second"))
    }

    @MainActor @Test
    func cancelBumpsSendGenerationToInvalidateInFlightTask() async {
        let client = CancellationProbeLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent, bufferCapacity: 32)

        stream.send("Hi", context: EmptyContext())
        await waitUntil("producer to yield deltas") { await client.yieldedCount >= 2 }
        let generationAfterSend = stream.sendGeneration
        stream.cancel()
        #expect(stream.sendGeneration == generationAfterSend &+ 1)
        await waitUntil("producer to observe cancellation") { await client.stoppedProducers == 1 }
    }

    @MainActor @Test
    func cancelPreventsFurtherObservableStateMutations() async {
        let client = CancellationProbeLLMClient()
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let stream = AgentStream(agent: agent, bufferCapacity: 256)

        stream.send("Hi", context: EmptyContext())
        await waitForBufferedCursor(stream, atLeast: 1)
        let contentSnapshot = stream.content
        stream.cancel()
        await waitUntil("producer to observe cancellation") { await client.stoppedProducers == 1 }

        try? await Task.sleep(for: .milliseconds(50))
        let cursorAfterCancel = await stream.bufferedCursor
        try? await Task.sleep(for: .milliseconds(50))

        #expect(stream.content == contentSnapshot)
        #expect(stream.finishReason == nil)
        #expect(await stream.bufferedCursor == cursorAfterCancel)
    }

    @MainActor @Test
    func replayFromTrimmedAndFutureCursorsThrows() async throws {
        let stream = makeBufferedStream(sequences: [firstSendDeltas], capacity: 2)
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)
        let cursor = try #require(await stream.bufferedCursor)

        do {
            _ = try await collectReplay(stream.replay(from: 0))
            Issue.record("Expected BufferReplayError.cursorTrimmed")
        } catch BufferReplayError.cursorTrimmed {
        } catch {
            Issue.record("Expected BufferReplayError.cursorTrimmed, got \(error)")
        }

        do {
            _ = try await collectReplay(stream.replay(from: cursor + 1))
            Issue.record("Expected BufferReplayError.cursorInFuture")
        } catch BufferReplayError.cursorInFuture(currentCursor: cursor) {
        } catch {
            Issue.record("Expected BufferReplayError.cursorInFuture, got \(error)")
        }
    }

    @MainActor @Test
    func replayIterationCanBeAbandonedWithoutResourceLeak() async throws {
        let stream = makeBufferedStream()
        stream.send("Hi", context: EmptyContext())
        await awaitStreamCompletion(stream)

        var firstReplayed: StreamEvent?
        for try await event in stream.replay(from: 0) {
            firstReplayed = event
            break
        }
        #expect(firstReplayed != nil)

        let fullReplay = try await collectReplay(stream.replay(from: 0))
        #expect(fullReplay.count > 1)
        #expect(fullReplay.first?.id == firstReplayed?.id)

        // The abandoned iteration must leave the buffer untouched: a full replay still matches.
        let secondReplay = try await collectReplay(stream.replay(from: 0))
        #expect(secondReplay.map(\.id) == fullReplay.map(\.id))
    }

    @MainActor @Test
    func agentStreamDeallocatesAfterCancel() async {
        weak var weakStream: AgentStream<EmptyContext>?

        // Plain scope instead of the reference's autoreleasepool, which does not exist on Linux.
        do {
            let stream = makeBufferedStream()
            weakStream = stream
            stream.send("Hi", context: EmptyContext())
            stream.cancel()
        }

        await waitUntil("stream to deallocate") { weakStream == nil }
        #expect(weakStream == nil)
    }
}
