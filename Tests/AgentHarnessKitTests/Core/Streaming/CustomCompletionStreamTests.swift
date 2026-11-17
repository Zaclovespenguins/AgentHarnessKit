@testable import AgentHarnessKit
import Foundation
import Testing

private func finalizeDeltas(
    id: String = "call_finalize",
    summary: String,
    usage: TokenUsage? = nil
) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: "finalize", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"summary": "\#(summary)"}"#),
        .finished(usage: usage),
    ]
}

private let lookupBesideFinalizeDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_lookup", name: "lookup", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"query": "spec"}"#),
    .toolCallStart(index: 1, id: "call_finalize_1", name: "finalize", kind: .function),
    .toolCallDelta(index: 1, arguments: #"{"summary": "early"}"#),
    .finished(usage: nil),
]

private let lookupDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_lookup", name: "lookup", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"query": "spec"}"#),
    .finished(usage: nil),
]

private let hallucinatedFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
    .finished(usage: nil),
]

private func makeAgent(
    streamSequences: [[StreamDelta]],
    tools: [any AnyTool<ReportContext>] = [],
    completionTool: any AnyTool<ReportContext>,
    contextWindowSize: Int? = nil,
    configuration: AgentConfiguration = AgentConfiguration()
) -> Agent<ReportContext> {
    Agent<ReportContext>(
        client: StreamingMockLLMClient(
            streamSequences: streamSequences, contextWindowSize: contextWindowSize
        ),
        tools: tools,
        completionTool: completionTool,
        configuration: configuration
    )
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func completedToolResults(_ events: [StreamEvent], name: String) -> [ToolResult] {
    events.compactMap { event in
        guard case let .toolCallCompleted(_, completedName, result) = event.kind, completedName == name else {
            return nil
        }
        return result
    }
}

private func isFinished(_ event: StreamEvent) -> Bool {
    if case .finished = event.kind { return true }
    return false
}

private func startedToolCallIDs(_ events: [StreamEvent]) -> [String] {
    events.compactMap { event in
        guard case let .toolCallStarted(_, id) = event.kind else { return nil }
        return id
    }
}

private func completedToolCallIDs(_ events: [StreamEvent]) -> [String] {
    events.compactMap { event in
        guard case let .toolCallCompleted(id, _, _) = event.kind else { return nil }
        return id
    }
}

private func awaitCollected(
    _ collector: StreamingEventCollector,
    where predicate: @Sendable @escaping (StreamEvent) -> Bool
) async {
    while await !collector.events.contains(where: predicate) {
        await Task.yield()
    }
}

private actor EventSnapshot {
    private(set) var events: [StreamEvent] = []

    func capture(_ events: [StreamEvent]) {
        self.events = events
    }
}

struct CustomCompletionStreamTests {
    @Test
    func theCompletionToolStreamsAsAnOrdinaryCallAndCommitsItsExactResult() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 12, output: 4))],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        #expect(events.contains { $0.kind == .toolCallStarted(name: "finalize", id: "call_finalize") })
        #expect(completedToolResults(events, name: "finalize") == [.success(expected)])
        #expect(await invocations.value == 1)

        guard case let .finished(usage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(usage.input == 12)
        #expect(usage.output == 4)
        #expect(usage.reasoning == 0)
        #expect(usage.coverage == .complete)
        #expect(content == expected)
        #expect(reason == .completed)
        #expect(history.count == 3)
        #expect(toolMessageContents(history) == [expected])
    }

    @Test
    func aThrowingCompletionToolFeedsBackAndCommitsOnTheNextTurn() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            guard params.summary != "draft" else { throw CustomCompletionTestError.draftRejected }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "draft"),
                finalizeDeltas(id: "call_finalize_2", summary: "final"),
            ],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "final")
        let results = completedToolResults(events, name: "finalize")
        #expect(results.count == 2)
        #expect(results.first?.isError == true)
        #expect(results.last == .success(expected))
        #expect(await invocations.value == 2)

        guard case let .finished(_, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)
        #expect(toolMessageContents(history).last == expected)
    }

    @Test
    func aTimedOutCompletionToolFeedsBackAndTheStreamContinues() async throws {
        let finalize = try makeFinalizeTool { params, context in
            if params.summary == "slow" {
                try await Task.sleep(for: .seconds(10))
            }
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "slow"),
                finalizeDeltas(id: "call_finalize_2", summary: "quick"),
            ],
            completionTool: finalize,
            configuration: AgentConfiguration(toolTimeout: .milliseconds(50))
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let results = completedToolResults(events, name: "finalize")
        #expect(results.count == 2)
        #expect(results.first?.isError == true)
        #expect(results.first?.content.contains("timed out") == true)

        guard case let .finished(_, content, _, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(try content == encodedReport(documentID: "doc-1", summary: "quick"))
    }

    @Test
    func aDeniedCompletionEmitsApprovalEventsAndFeedsTheDenialBack() async throws {
        let invocations = ToolInvocationCounter()
        let finalize = try makeFinalizeTool { params, context in
            await invocations.increment()
            return report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [
                finalizeDeltas(id: "call_finalize_1", summary: "first"),
                finalizeDeltas(id: "call_finalize_2", summary: "second"),
            ],
            completionTool: finalize,
            configuration: AgentConfiguration(maxIterations: 2, approvalPolicy: .allTools)
        )
        let approvals = CountingApprovalHandler(decisions: ["finalize": .deny(reason: "Needs review")])

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"),
            approvalHandler: approvals.handler
        ))

        #expect(events.contains { event in
            if case let .toolApprovalRequested(request) = event.kind { return request.toolName == "finalize" }
            return false
        })
        #expect(events.contains { event in
            if case let .toolApprovalResolved(_, decision) = event.kind {
                return decision == .deny(reason: "Needs review")
            }
            return false
        })
        #expect(completedToolResults(events, name: "finalize") == [
            .error("Needs review"), .error("Needs review"),
        ])
        #expect(await invocations.value == 0)
        #expect(await approvals.requestCount == 2)

        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a structural finished event")
            return
        }
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 2))
    }

    @Test
    func aLoneHallucinatedFinishCallBecomesUnknownToolFeedback() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [hallucinatedFinishDeltas, finalizeDeltas(summary: "all done")],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Go", context: ReportContext(documentID: "doc-1")
        ))

        #expect(completedToolResults(events, name: "finish") == [
            .error(AgentError.toolNotFound(name: "finish").feedbackMessage),
        ])

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(content == expected)
        #expect(reason == .completed)
    }

}

struct CustomCompletionStreamBudgetTests {
    @Test
    func aCommittedCompletionOutranksAnExceededTokenBudget() async throws {
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let agent = makeAgent(
            streamSequences: [finalizeDeltas(summary: "all done", usage: TokenUsage(input: 100, output: 100))],
            completionTool: finalize
        )

        let events = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1"), tokenBudget: 50
        ))

        let expected = try encodedReport(documentID: "doc-1", summary: "all done")
        guard case let .finished(usage, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }
        #expect(usage.input == 100)
        #expect(usage.output == 100)
        #expect(usage.reasoning == 0)
        #expect(usage.coverage == .complete)
        #expect(content == expected)
        #expect(reason == .completed)
    }

}

struct CustomCompletionStreamBoundaryTests {
    @Test
    func customModeStreamsTheCallersDefinitionsWithoutTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let finalize = try makeFinalizeTool { params, context in
            report(documentID: context.documentID, summary: params.summary)
        }
        let client = StreamingMockLLMClient(streamSequences: [finalizeDeltas(summary: "all done")])
        let agent = Agent<ReportContext>(client: client, tools: [lookup], completionTool: finalize)

        _ = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), ToolDefinition(finalize)])
    }

    @Test
    func defaultModeStillStreamsTheBuiltInFinishTool() async throws {
        let lookup = try makeLookupTool { _, _ in LookupOutput(matches: 1) }
        let client = StreamingMockLLMClient(streamSequences: [[
            .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
            .finished(usage: nil),
        ]])
        let agent = Agent<ReportContext>(client: client, tools: [lookup])

        _ = try await collect(agent.stream(
            userMessage: "Summarize", context: ReportContext(documentID: "doc-1")
        ))

        let definitions = try #require(await client.allCapturedTools.first)
        #expect(definitions == [ToolDefinition(lookup), reservedFinishToolDefinition])
    }
}

@MainActor
struct CustomCompletionStreamObserverTests {

}
