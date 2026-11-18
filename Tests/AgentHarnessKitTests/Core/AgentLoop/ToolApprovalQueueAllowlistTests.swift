@testable import AgentHarnessKit
import AgentHarnessKitTesting
import Foundation
import Testing

private struct ToolAParams: Codable, SchemaProviding {
    let note: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["note": .string()], required: ["note"])
    }
}

private struct ToolAOutput: Codable {
    let echoed: String
}

private func makeToolA(counter: ToolInvocationCounter) throws -> Tool<ToolAParams, ToolAOutput, EmptyContext> {
    try Tool(
        name: "tool_a",
        description: "Tool A",
        executor: { params, _ in
            await counter.increment()
            return ToolAOutput(echoed: params.note)
        }
    )
}

private func makeCall(_ id: String, note: String = "x") -> ToolCall {
    ToolCall(id: id, name: "tool_a", arguments: #"{"note":"\#(note)"}"#)
}

private let finishResponse = AssistantMessage(
    content: "",
    toolCalls: [ToolCall(id: "call_f", name: "finish", arguments: #"{"content":"done"}"#)]
)

/// Records every snapshot published by `ToolApprovalQueue.updates`, in order.
private actor SnapshotLog {
    private(set) var snapshots: [[ToolApprovalRequest]] = []

    func record(_ snapshot: [ToolApprovalRequest]) {
        snapshots.append(snapshot)
    }

    var count: Int {
        snapshots.count
    }

    /// Every tool call id that appeared in any snapshot, in publication order (duplicates kept).
    var requestedIDs: [String] {
        snapshots.flatMap { $0.map(\.toolCallId) }
    }

    var largestSnapshot: Int {
        snapshots.map(\.count).max() ?? 0
    }
}

/// Subscribes to `updates` and returns once the subscription is registered (the first snapshot arrived).
private func watchUpdates(_ queue: ToolApprovalQueue) async -> (log: SnapshotLog, watcher: Task<Void, Never>) {
    let log = SnapshotLog()
    let watcher = Task {
        for await snapshot in queue.updates {
            await log.record(snapshot)
        }
    }
    _ = await poll { await log.count >= 1 }
    return (log, watcher)
}

/// Polls a condition for up to about two seconds.
private func poll(_ condition: () async -> Bool) async -> Bool {
    for _ in 0 ..< 1000 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Waits until `queue` holds `count` parked requests and returns them, or nil on timeout.
private func waitForPending(_ queue: ToolApprovalQueue, count: Int) async -> [ToolApprovalRequest]? {
    guard await poll({ await queue.pending().count >= count }) else { return nil }
    return await queue.pending()
}

private func startRun(_ agent: Agent<EmptyContext>, queue: ToolApprovalQueue) -> Task<AgentResult, Error> {
    Task {
        try await agent.run(userMessage: "Go", context: EmptyContext(), approvalHandler: queue.handler)
    }
}

/// Cancels a run that will never finish because the test failed while it was parked.
private func abandon(_ run: Task<AgentResult, Error>, queue: ToolApprovalQueue) async {
    await queue.denyAll(reason: nil)
    run.cancel()
    _ = try? await run.value
}

struct ToolApprovalQueueAllowlistTests {
    @Test
    func approveAlwaysKeepsLaterCallsToToolOutOfTheQueue() async throws {
        let queue = ToolApprovalQueue()
        let (log, watcher) = await watchUpdates(queue)
        defer { watcher.cancel() }
        let counter = ToolInvocationCounter()
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [makeCall("call_1", note: "first")]),
            AssistantMessage(content: "", toolCalls: [makeCall("call_2", note: "second")]),
            finishResponse,
        ])
        let agent = try Agent<EmptyContext>(
            client: client, tools: [makeToolA(counter: counter)],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let run = startRun(agent, queue: queue)

        guard let parked = await waitForPending(queue, count: 1), let first = parked.first else {
            await abandon(run, queue: queue)
            Issue.record("Expected the first tool call to park")
            return
        }
        #expect(first.toolCallId == "call_1")
        #expect(await queue.resolve(id: "call_1", decision: .approveAlways))

        let result = try await run.value
        #expect(try requireContent(result) == "done")
        #expect(await poll { await log.count >= 3 })
        #expect(await log.requestedIDs == ["call_1"])
        #expect(await queue.pending().isEmpty)
        #expect(await counter.value == 2)
    }

    @Test
    func checkpointAllowlistKeepsToolOutOfTheQueueOnResume() async throws {
        let queue = ToolApprovalQueue()
        let (log, watcher) = await watchUpdates(queue)
        defer { watcher.cancel() }
        let counter = ToolInvocationCounter()
        let checkpointer = InMemoryCheckpointer()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Go")],
            iteration: 0,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 0, output: 0)),
            sessionAllowlist: ["tool_a"],
            sessionID: SessionID(),
            runID: RunID(),
            checkpointID: CheckpointID()
        )
        try await checkpointer.save(checkpoint)

        let agent = try Agent<EmptyContext>(
            client: TestLLMClient(callTools: .specific(["tool_a"])),
            tools: [makeToolA(counter: counter)],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let stream = try await agent.resume(
            from: checkpoint.checkpointID, checkpointer: checkpointer,
            context: EmptyContext(), approvalHandler: queue.handler
        )
        var requestedEvents = 0
        var completedToolA = 0
        for try await event in stream {
            switch event.kind {
            case .toolApprovalRequested: requestedEvents += 1
            case let .toolCallCompleted(_, name, _) where name == "tool_a": completedToolA += 1
            default: break
            }
        }

        #expect(requestedEvents == 0)
        #expect(completedToolA == 1)
        #expect(await counter.value == 1)
        #expect(await queue.pending().isEmpty)
        #expect(await log.requestedIDs.isEmpty)
    }

    @Test
    func approveAlwaysOnFirstOfTwoSameToolCallsCoversTheSecond() async throws {
        let queue = ToolApprovalQueue()
        let (log, watcher) = await watchUpdates(queue)
        defer { watcher.cancel() }
        let counter = ToolInvocationCounter()
        // One response carrying two calls to tool_a. TestLLMClient emits one call per tool per turn, so the
        // scripted MockLLMClient is needed here.
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                makeCall("call_1", note: "first"),
                makeCall("call_2", note: "second"),
            ]),
            finishResponse,
        ])
        let agent = try Agent<EmptyContext>(
            client: client, tools: [makeToolA(counter: counter)],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let run = startRun(agent, queue: queue)

        guard let parked = await waitForPending(queue, count: 1), let first = parked.first else {
            await abandon(run, queue: queue)
            Issue.record("Expected the first tool call to park")
            return
        }
        #expect(first.toolCallId == "call_1")
        #expect(await queue.resolve(id: "call_1", decision: .approveAlways))

        let result = try await run.value
        #expect(try requireContent(result) == "done")
        #expect(await poll { await log.count >= 3 })
        #expect(await log.largestSnapshot == 1)
        #expect(await log.requestedIDs == ["call_1"])
        #expect(await queue.pending().isEmpty)
        #expect(await counter.value == 2)
    }

    @Test
    func approveAlwaysInOneRunDoesNotResolveParkedRequestsOfAnotherRun() async throws {
        let queue = ToolApprovalQueue()
        let (log, watcher) = await watchUpdates(queue)
        defer { watcher.cancel() }
        let counter = ToolInvocationCounter()
        let runOneAgent = try Agent<EmptyContext>(
            client: MockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [makeCall("run_one_call")]),
                finishResponse,
            ]),
            tools: [makeToolA(counter: counter)],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let runTwoAgent = try Agent<EmptyContext>(
            client: MockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [makeCall("run_two_call")]),
                finishResponse,
            ]),
            tools: [makeToolA(counter: counter)],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let runOne = startRun(runOneAgent, queue: queue)
        let runTwo = startRun(runTwoAgent, queue: queue)

        guard let parked = await waitForPending(queue, count: 2) else {
            await abandon(runOne, queue: queue)
            await abandon(runTwo, queue: queue)
            Issue.record("Expected both runs to park a tool call")
            return
        }
        #expect(Set(parked.map(\.toolCallId)) == ["run_one_call", "run_two_call"])

        #expect(await queue.resolve(id: "run_one_call", decision: .approveAlways))
        let oneResult = try await runOne.value
        #expect(try requireContent(oneResult) == "done")

        // The run-two request is still parked: approveAlways did not cascade to it.
        #expect(await queue.pending().map(\.toolCallId) == ["run_two_call"])

        #expect(await queue.resolve(id: "run_two_call", decision: .approve))
        let twoResult = try await runTwo.value
        #expect(try requireContent(twoResult) == "done")

        #expect(await queue.pending().isEmpty)
        #expect(await poll { await log.requestedIDs.count >= 2 })
        #expect(await counter.value == 2)
    }
}
