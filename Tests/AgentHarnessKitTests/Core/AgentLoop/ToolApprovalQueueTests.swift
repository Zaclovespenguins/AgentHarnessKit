@testable import AgentHarnessKit
import AgentHarnessKitTesting
import Foundation
import Testing

private struct QueueEchoParams: Codable, SchemaProviding {
    let message: String
}

private struct QueueEchoOutput: Codable {
    let echoed: String
}

private func makeRequest(_ id: String, tool: String = "shell") -> ToolApprovalRequest {
    ToolApprovalRequest(toolCallId: id, toolName: tool, arguments: "{}", toolDescription: "Test tool")
}

/// Polls `pending()` until it holds at least `count` requests, so tests do not depend on scheduling.
private func waitForPending(_ queue: ToolApprovalQueue, count: Int) async -> [ToolApprovalRequest] {
    for _ in 0 ..< 500 {
        let pending = await queue.pending()
        if pending.count >= count {
            return pending
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await queue.pending()
}

/// Polls `pending()` until it is empty, bounded to about one second.
private func waitForEmptyPending(_ queue: ToolApprovalQueue) async -> Bool {
    for _ in 0 ..< 500 {
        if await queue.pending().isEmpty {
            return true
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await queue.pending().isEmpty
}

/// Starts a handler call in its own task and waits until it is parked, so calls enqueue in a known order.
private func park(
    _ queue: ToolApprovalQueue, _ request: ToolApprovalRequest, expecting count: Int
) async -> Task<ToolApprovalDecision, Never> {
    let task = Task { await queue.handler(request) }
    _ = await waitForPending(queue, count: count)
    return task
}

struct ToolApprovalQueueTests {
    @Test func parkedRequestsListInCallOrder() async {
        let queue = ToolApprovalQueue()
        let first = await park(queue, makeRequest("a"), expecting: 1)
        let second = await park(queue, makeRequest("b"), expecting: 2)
        let third = await park(queue, makeRequest("c"), expecting: 3)

        let pending = await queue.pending()
        #expect(pending.map(\.toolCallId) == ["a", "b", "c"])

        _ = await queue.resolve(id: "a", decision: .approve)
        _ = await queue.resolve(id: "b", decision: .approve)
        _ = await queue.resolve(id: "c", decision: .approve)
        _ = await first.value
        _ = await second.value
        _ = await third.value
    }

    @Test func resolveOutOfOrderReturnsDecisionAndKeepsOrder() async {
        let queue = ToolApprovalQueue()
        let first = await park(queue, makeRequest("a"), expecting: 1)
        let middle = await park(queue, makeRequest("b"), expecting: 2)
        let last = await park(queue, makeRequest("c"), expecting: 3)

        let resolved = await queue.resolve(id: "b", decision: .deny(reason: "nope"))
        #expect(resolved)
        #expect(await middle.value == .deny(reason: "nope"))

        let pending = await queue.pending()
        #expect(pending.map(\.toolCallId) == ["a", "c"])

        _ = await queue.resolve(id: "a", decision: .approve)
        _ = await queue.resolve(id: "c", decision: .approve)
        #expect(await first.value == .approve)
        #expect(await last.value == .approve)
    }

    /// 6.10: `denyAll` over three parked requests resumes all three with the deny, and subscribers see exactly one
    /// empty snapshot for it.
    @Test func denyAllWithThreeParkedPublishesOneEmptySnapshot() async {
        let queue = ToolApprovalQueue()
        var updates = queue.updates.makeAsyncIterator()
        #expect(await updates.next() == [])

        let first = await park(queue, makeRequest("a"), expecting: 1)
        let second = await park(queue, makeRequest("b"), expecting: 2)
        let third = await park(queue, makeRequest("c"), expecting: 3)
        for expected in [["a"], ["a", "b"], ["a", "b", "c"]] {
            #expect(await updates.next()?.map(\.toolCallId) == expected)
        }

        await queue.denyAll(reason: "Stopped")
        #expect(await updates.next() == [])
        #expect(await first.value == .deny(reason: "Stopped"))
        #expect(await second.value == .deny(reason: "Stopped"))
        #expect(await third.value == .deny(reason: "Stopped"))
        #expect(await queue.pending().isEmpty)

        // 6.18: nothing is parked now, so a second denyAll publishes nothing. The next emission is the next change.
        await queue.denyAll(reason: "Again")
        let next = await park(queue, makeRequest("d"), expecting: 1)
        #expect(await updates.next()?.map(\.toolCallId) == ["d"])
        _ = await queue.resolve(id: "d", decision: .approve)
        _ = await next.value
    }

    @Test func resolveUnknownIdReturnsFalse() async {
        let queue = ToolApprovalQueue()
        let parked = await park(queue, makeRequest("a"), expecting: 1)

        #expect(await queue.resolve(id: "missing", decision: .approve) == false)
        #expect(await queue.pending().map(\.toolCallId) == ["a"])

        _ = await queue.resolve(id: "a", decision: .approve)
        _ = await parked.value
    }

    @Test func updatesEmitsSnapshotsAfterEnqueueResolveAndDenyAll() async {
        let queue = ToolApprovalQueue()
        var updates = queue.updates.makeAsyncIterator()

        #expect(await updates.next() == [])

        let first = await park(queue, makeRequest("a"), expecting: 1)
        #expect(await updates.next()?.map(\.toolCallId) == ["a"])

        let second = await park(queue, makeRequest("b"), expecting: 2)
        #expect(await updates.next()?.map(\.toolCallId) == ["a", "b"])

        _ = await queue.resolve(id: "a", decision: .approve)
        #expect(await updates.next()?.map(\.toolCallId) == ["b"])

        await queue.denyAll(reason: nil)
        #expect(await updates.next() == [])

        _ = await first.value
        _ = await second.value
    }

    @Test func cancelledHandlerCallDeniesAndLeavesNothingParked() async {
        let queue = ToolApprovalQueue()
        let task = Task { await queue.handler(makeRequest("a")) }
        #expect(await waitForPending(queue, count: 1).map(\.toolCallId) == ["a"])

        task.cancel()

        #expect(await task.value == .deny(reason: "Cancelled"))
        #expect(await queue.pending().isEmpty)
    }

    @Test func cancelledConsumerLeavesNoRequestParkedInLoop() async throws {
        let queue = ToolApprovalQueue()
        let echoTool = try Tool<QueueEchoParams, QueueEchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in QueueEchoOutput(echoed: params.message) }
        )
        let agent = Agent<EmptyContext>(
            client: TestLLMClient(seed: 1),
            tools: [echoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let (requested, requestedContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await event in agent.stream(
                userMessage: "Go", context: EmptyContext(), approvalHandler: queue.handler
            ) {
                if case .toolApprovalRequested = event.kind {
                    requestedContinuation.yield()
                }
            }
        }

        // A request is parked only after its event is emitted, so a non-empty queue means the event is on its way.
        let parked = await waitForPending(queue, count: 1)
        if !parked.isEmpty {
            var signals = requested.makeAsyncIterator()
            _ = await signals.next()
        }
        #expect(parked.count == 1)

        consumer.cancel()
        _ = try? await consumer.value

        #expect(await waitForEmptyPending(queue))
    }
}
