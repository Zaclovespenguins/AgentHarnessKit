@testable import AgentHarnessKit
import Foundation
import Testing

private struct ConcurrentEchoParams: Codable, SchemaProviding {
    let message: String
}

private struct ConcurrentEchoOutput: Codable {
    let echoed: String
}

private func makeConcurrentEchoTool(
    name: String
) throws -> Tool<ConcurrentEchoParams, ConcurrentEchoOutput, EmptyContext> {
    try Tool(
        name: name,
        description: "Echoes \(name)",
        executor: { params, _ in ConcurrentEchoOutput(echoed: "\(name) ran: \(params.message)") }
    )
}

private func finishResponse() -> AssistantMessage {
    AssistantMessage(content: "", toolCalls: [
        ToolCall(id: "call_finish", name: "finish", arguments: #"{"content":"done"}"#),
    ])
}

private func toolContents(_ history: [ChatMessage]) -> [(id: String, content: String)] {
    history.compactMap { message in
        guard case let .tool(id, _, content) = message else { return nil }
        return (id, content)
    }
}

/// Polls `queue.pending()` until `condition` holds for the snapshot or the timeout expires, then returns the snapshot.
private func awaitPending(
    in queue: ToolApprovalQueue,
    timeout: Duration = .seconds(5),
    until condition: ([ToolApprovalRequest]) -> Bool
) async -> [ToolApprovalRequest] {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        let snapshot = await queue.pending()
        if condition(snapshot) || ContinuousClock.now >= deadline {
            return snapshot
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private actor RanLog {
    private(set) var messages: [String] = []

    func add(_ message: String) {
        messages.append(message)
    }
}

struct ToolApprovalQueueConcurrencyTests {
    /// Three independent runs share one queue. All three requests park at once, and they are resolved in the
    /// order 3, 1, 2 with different decisions. Each run's result must match its own decision.
    @Test
    func parkedRequestsFromSeparateRunsResolveIndependently() async throws {
        let alpha = try makeConcurrentEchoTool(name: "alpha")
        let beta = try makeConcurrentEchoTool(name: "beta")
        let gamma = try makeConcurrentEchoTool(name: "gamma")
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let queue = ToolApprovalQueue()

        func makeRun(tool: String, callID: String, message: String) -> Task<AgentResult, Error> {
            let client = MockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: callID, name: tool, arguments: #"{"message":"\#(message)"}"#),
                ]),
                finishResponse(),
            ])
            let tools: [any AnyTool<EmptyContext>] = tool == "alpha" ? [alpha] : tool == "beta" ? [beta] : [gamma]
            let agent = Agent<EmptyContext>(client: client, tools: tools, configuration: config)
            return Task {
                try await agent.run(userMessage: "Go", context: EmptyContext(), approvalHandler: queue.handler)
            }
        }

        let alphaRun = makeRun(tool: "alpha", callID: "run_alpha", message: "from-alpha")
        let betaRun = makeRun(tool: "beta", callID: "run_beta", message: "from-beta")
        let gammaRun = makeRun(tool: "gamma", callID: "run_gamma", message: "from-gamma")

        let parked = await awaitPending(in: queue) { $0.count == 3 }
        #expect(Set(parked.map(\.toolCallId)) == ["run_alpha", "run_beta", "run_gamma"])

        #expect(await queue.resolve(id: "run_gamma", decision: .approve))
        #expect(await queue.resolve(id: "run_alpha", decision: .deny(reason: "no alpha")))
        #expect(await queue.resolve(id: "run_beta", decision: .approveWithModifiedArguments(#"{"message":"edited"}"#)))

        let alphaResult = try await alphaRun.value
        let betaResult = try await betaRun.value
        let gammaResult = try await gammaRun.value

        let alphaTool = toolContents(alphaResult.history)
        #expect(alphaTool.map(\.id) == ["run_alpha"])
        #expect(alphaTool.first?.content == "no alpha")

        let betaTool = toolContents(betaResult.history)
        #expect(betaTool.map(\.id) == ["run_beta"])
        #expect(betaTool.first?.content.contains("beta ran: edited") == true)
        #expect(betaTool.first?.content.contains("from-beta") == false)

        let gammaTool = toolContents(gammaResult.history)
        #expect(gammaTool.map(\.id) == ["run_gamma"])
        #expect(gammaTool.first?.content.contains("gamma ran: from-gamma") == true)

        #expect(await queue.pending().isEmpty)
    }

    /// One run with three calls in one response. The loop asks one approval at a time, so the queue never holds
    /// more than the request being decided. Each request is resolved as it appears, and history keeps call order.
    @Test
    func singleRunApprovalsAreAskedOneAtATimeInCallOrder() async throws {
        let alpha = try makeConcurrentEchoTool(name: "alpha")
        let beta = try makeConcurrentEchoTool(name: "beta")
        let gamma = try makeConcurrentEchoTool(name: "gamma")
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "call_1", name: "alpha", arguments: #"{"message":"from-alpha"}"#),
                ToolCall(id: "call_2", name: "beta", arguments: #"{"message":"from-beta"}"#),
                ToolCall(id: "call_3", name: "gamma", arguments: #"{"message":"from-gamma"}"#),
            ]),
            finishResponse(),
        ])
        let config = AgentConfiguration(approvalPolicy: .allTools)
        let agent = Agent<EmptyContext>(client: client, tools: [alpha, beta, gamma], configuration: config)
        let queue = ToolApprovalQueue()

        let runTask = Task {
            try await agent.run(userMessage: "Go", context: EmptyContext(), approvalHandler: queue.handler)
        }

        let decisions: [(id: String, decision: ToolApprovalDecision)] = [
            ("call_1", .deny(reason: "no alpha")),
            ("call_2", .approveWithModifiedArguments(#"{"message":"edited"}"#)),
            ("call_3", .approve),
        ]
        for (id, decision) in decisions {
            let snapshot = await awaitPending(in: queue) { $0.contains { $0.toolCallId == id } }
            #expect(snapshot.map(\.toolCallId) == [id])
            #expect(await queue.resolve(id: id, decision: decision))
        }

        let result = try await runTask.value
        #expect(try requireContent(result) == "done")

        let tools = toolContents(result.history)
        #expect(tools.map(\.id) == ["call_1", "call_2", "call_3"])
        #expect(tools[0].content == "no alpha")
        #expect(tools[1].content.contains("beta ran: edited"))
        #expect(tools[1].content.contains("from-beta") == false)
        #expect(tools[2].content.contains("gamma ran: from-gamma"))
    }

    /// 6.11: two concurrency-safe sub-agents run in one wave and both park on the parent's shared queue. They are
    /// resolved out of order with different decisions, and each child acts on its own decision.
    @Test
    func parallelSubAgentsParkOnSharedQueueAndResolveOutOfOrder() async throws {
        let ran = RanLog()
        func makeChild(_ label: String) throws -> Agent<SubAgentContext<EmptyContext>> {
            let echo = try Tool<ConcurrentEchoParams, ConcurrentEchoOutput, SubAgentContext<EmptyContext>>(
                name: "echo",
                description: "Echoes",
                executor: { params, _ in
                    await ran.add(params.message)
                    return ConcurrentEchoOutput(echoed: params.message)
                }
            )
            let client = MockLLMClient(responses: [
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "child_\(label)", name: "echo", arguments: #"{"message":"\#(label)"}"#),
                ]),
                AssistantMessage(content: "", toolCalls: [
                    ToolCall(id: "child_finish", name: "finish", arguments: #"{"content":"\#(label) done"}"#),
                ]),
            ])
            return Agent(client: client, tools: [echo], configuration: AgentConfiguration(approvalPolicy: .allTools))
        }
        let first = try SubAgentTool<ConcurrentEchoParams, EmptyContext>(
            name: "first", description: "First child", agent: makeChild("a"), isConcurrencySafe: true
        ) { $0.message }
        let second = try SubAgentTool<ConcurrentEchoParams, EmptyContext>(
            name: "second", description: "Second child", agent: makeChild("b"), isConcurrencySafe: true
        ) { $0.message }
        let parentClient = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "parent_1", name: "first", arguments: #"{"message":"go a"}"#),
                ToolCall(id: "parent_2", name: "second", arguments: #"{"message":"go b"}"#),
            ]),
            finishResponse(),
        ])
        let parent = Agent<SubAgentContext<EmptyContext>>(client: parentClient, tools: [first, second])
        let queue = ToolApprovalQueue()

        let run = Task {
            try await parent.run(
                userMessage: "Go",
                context: SubAgentContext(inner: EmptyContext(), maxDepth: 3),
                approvalHandler: queue.handler
            )
        }

        let parked = await awaitPending(in: queue) { $0.count == 2 }
        #expect(Set(parked.map(\.toolCallId)) == ["child_a", "child_b"])
        #expect(await queue.resolve(id: "child_b", decision: .deny(reason: "no b")))
        #expect(await queue.resolve(id: "child_a", decision: .approve))

        let result = try await run.value
        #expect(try requireContent(result) == "done")
        #expect(await ran.messages == ["a"])
        let tools = toolContents(result.history)
        #expect(tools.map(\.id) == ["parent_1", "parent_2"])
        #expect(tools.map(\.content) == ["a done", "b done"])
        #expect(await queue.pending().isEmpty)
    }
}
