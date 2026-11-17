import Foundation

/// A FIFO queue of parked tool approval requests, usable as a ``ToolApprovalHandler`` provider.
///
/// Create one queue, pass ``handler`` to `Agent`, `Chat` or `AgentStream`, and resolve parked requests from UI
/// code. Requests resolve independently and in any order. Cancelling the awaiting task removes the request and
/// resolves it as `.deny(reason: "Cancelled")`.
///
/// ```swift
/// let queue = ToolApprovalQueue()
/// let stream = agent.stream(userMessage: text, approvalHandler: queue.handler)
///
/// // Approve from the UI, in any order:
/// await queue.resolve(id: request.toolCallId, decision: .approve)
///
/// // Stop button: deny everything still parked, then cancel the stream.
/// await queue.denyAll(reason: nil)
/// stream.cancel()
/// ```
public final class ToolApprovalQueue: Sendable {
    private let store = ToolApprovalQueueStore()

    public init() {}

    /// A handler that parks each request in this queue until it is resolved, denied or cancelled.
    public var handler: ToolApprovalHandler {
        let store = store
        return { request in
            let ticket = UUID()
            return await withTaskCancellationHandler {
                await store.park(request, ticket: ticket)
            } onCancel: {
                Task { await store.cancel(ticket: ticket) }
            }
        }
    }

    /// Resolves the parked request with `toolCallId == id`. Returns `false` if no request has that id.
    ///
    /// `.approveAlways` also approves every other parked request for the same tool name with `.approve`.
    public func resolve(id: String, decision: ToolApprovalDecision) async -> Bool {
        await store.resolve(id: id, decision: decision)
    }

    /// Resumes every parked request with `.deny(reason: reason)` in FIFO order and empties the queue.
    public func denyAll(reason: String?) async {
        await store.denyAll(reason: reason)
    }

    /// The parked requests, oldest first.
    public func pending() async -> [ToolApprovalRequest] {
        await store.snapshot()
    }

    /// Emits the FIFO snapshot of parked requests after every change. Each subscriber receives the current
    /// snapshot first.
    public var updates: AsyncStream<[ToolApprovalRequest]> {
        let store = store
        return AsyncStream { continuation in
            let subscriberID = UUID()
            continuation.onTermination = { _ in
                Task { await store.removeSubscriber(subscriberID) }
            }
            Task { await store.addSubscriber(subscriberID, continuation) }
        }
    }
}

private actor ToolApprovalQueueStore {
    private struct Entry {
        let ticket: UUID
        let request: ToolApprovalRequest
        let continuation: CheckedContinuation<ToolApprovalDecision, Never>
    }

    private var entries: [Entry] = []
    private var subscribers: [UUID: AsyncStream<[ToolApprovalRequest]>.Continuation] = [:]

    func park(_ request: ToolApprovalRequest, ticket: UUID) async -> ToolApprovalDecision {
        await withCheckedContinuation { continuation in
            // A cancel that ran before this point has already set the task's cancellation flag, so checking it
            // here keeps a cancelled request from being parked where nothing would remove it.
            guard !Task.isCancelled else {
                continuation.resume(returning: .deny(reason: "Cancelled"))
                return
            }
            entries.append(Entry(ticket: ticket, request: request, continuation: continuation))
            publish()
        }
    }

    func cancel(ticket: UUID) {
        // Not found means the request was already resolved, or it has not parked yet. In the second case the
        // task's cancellation flag is set, so park() resumes it itself.
        guard let index = entries.firstIndex(where: { $0.ticket == ticket }) else { return }
        let entry = entries.remove(at: index)
        publish()
        entry.continuation.resume(returning: .deny(reason: "Cancelled"))
    }

    func resolve(id: String, decision: ToolApprovalDecision) -> Bool {
        guard let index = entries.firstIndex(where: { $0.request.toolCallId == id }) else { return false }
        let entry = entries.remove(at: index)
        var others: [Entry] = []
        if decision == .approveAlways {
            let toolName = entry.request.toolName
            others = entries.filter { $0.request.toolName == toolName }
            entries.removeAll { $0.request.toolName == toolName }
        }
        publish()
        entry.continuation.resume(returning: decision)
        for other in others {
            other.continuation.resume(returning: .approve)
        }
        return true
    }

    func denyAll(reason: String?) {
        let all = entries
        entries.removeAll()
        publish()
        for entry in all {
            entry.continuation.resume(returning: .deny(reason: reason))
        }
    }

    func snapshot() -> [ToolApprovalRequest] {
        entries.map(\.request)
    }

    func addSubscriber(_ id: UUID, _ continuation: AsyncStream<[ToolApprovalRequest]>.Continuation) {
        if case .terminated = continuation.yield(snapshot()) { return }
        subscribers[id] = continuation
    }

    func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish() {
        let current = snapshot()
        for (id, subscriber) in subscribers {
            if case .terminated = subscriber.yield(current) {
                subscribers[id] = nil
            }
        }
    }
}
