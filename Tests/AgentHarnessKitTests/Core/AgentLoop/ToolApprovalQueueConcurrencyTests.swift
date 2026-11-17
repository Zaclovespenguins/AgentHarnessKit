@testable import AgentHarnessKit
import Foundation
import Testing

private struct ConcurrentEchoParams: Codable, SchemaProviding {
    let message: String
}

private struct ConcurrentEchoOutput: Codable {
    let echoed: String
}

private func makeConcurrentEchoTool(name: String) throws -> Tool<ConcurrentEchoParams, ConcurrentEchoOutput, EmptyContext> {
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
        if condition(snapshot) || ContinuousClock.now >= deadline { return snapshot }
        try? await Task.sleep(for: .milliseconds(5))
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
}
