@testable import AgentHarnessKit
import Foundation
import Testing

private func makeRequest(_ id: String, tool: String = "shell") -> ToolApprovalRequest {
    ToolApprovalRequest(toolCallId: id, toolName: tool, arguments: "{}", toolDescription: "Test tool")
}

/// Polls `pending()` until it holds at least `count` requests, so tests do not depend on scheduling.
private func waitForPending(_ queue: ToolApprovalQueue, count: Int) async -> [ToolApprovalRequest] {
    for _ in 0..<500 {
        let pending = await queue.pending()
        if pending.count >= count { return pending }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await queue.pending()
}

/// Starts a handler call in its own task and waits until it is parked, so calls enqueue in a known order.
private func park(
    _ queue: ToolApprovalQueue, _ request: ToolApprovalRequest, expecting count: Int
) async -> Task<ToolApprovalDecision, Never> {
    let task = Task { await queue.handler(request) }
    _ = await waitForPending(queue, count: count)
    return task
}

@Suite("ToolApprovalQueue")
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

    @Test func denyAllResumesEveryHandlerAndEmptiesQueue() async {
        let queue = ToolApprovalQueue()
        let first = await park(queue, makeRequest("a"), expecting: 1)
        let second = await park(queue, makeRequest("b"), expecting: 2)
        let third = await park(queue, makeRequest("c"), expecting: 3)

        await queue.denyAll(reason: "Stopped")

        #expect(await first.value == .deny(reason: "Stopped"))
        #expect(await second.value == .deny(reason: "Stopped"))
        #expect(await third.value == .deny(reason: "Stopped"))
        #expect(await queue.pending().isEmpty)
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
}
