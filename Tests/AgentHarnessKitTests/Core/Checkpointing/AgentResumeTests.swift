@testable import AgentHarnessKit
import Foundation
import Testing

private let secondFinishDeltas: [StreamDelta] = [
    .toolCallStart(index: 0, id: "call_2", name: "finish", kind: .function),
    .toolCallDelta(index: 0, arguments: #"{"content": "live continuation"}"#),
    .finished(usage: TokenUsage(input: 7, output: 7)),
]

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let terminalOutcome = AgentTerminalOutcome(
    content: #"{"summary":"shipped"}"#, toolName: "finalize"
)

private let terminalMessages: [ChatMessage] = [
    .user("Summarize"),
    .assistant(AssistantMessage(
        content: "",
        toolCalls: [ToolCall(id: "call_finalize", name: "finalize", arguments: "{}")]
    )),
    .tool(id: "call_finalize", name: "finalize", content: #"{"summary":"draft"}"#),
]

private func makeTerminalCheckpoint(
    messages: [ChatMessage] = terminalMessages,
    iteration: Int = 1,
    tokenUsage: TokenUsageTotals = makeTokenUsageTotals(TokenUsage(input: 9, output: 4)),
    iterationUsage: TokenUsage? = TokenUsage(input: 5, output: 2),
    mcpToolBindings: Set<MCPToolBinding> = [],
    sessionID: SessionID = SessionID(),
    checkpointID: CheckpointID = CheckpointID()
) -> AgentCheckpoint {
    AgentCheckpoint(
        messages: messages,
        iteration: iteration,
        tokenUsage: tokenUsage,
        iterationUsage: iterationUsage,
        sessionAllowlist: [],
        sessionID: sessionID,
        runID: RunID(),
        checkpointID: checkpointID,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        mcpToolBindings: mcpToolBindings,
        terminalOutcome: terminalOutcome
    )
}

private func makeFinalizingAgent(
    client: StreamingMockLLMClient,
    invocations: ToolInvocationCounter = ToolInvocationCounter(),
    configuration: AgentConfiguration = AgentConfiguration()
) throws -> Agent<EmptyContext> {
    let finalize = try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: "finalize",
        description: "Return the final answer. Call it alone.",
        executor: { params, _ in
            await invocations.increment()
            return EchoOutput(echoed: params.message)
        }
    )
    return Agent<EmptyContext>(
        client: client, tools: [], completionTool: finalize, configuration: configuration
    )
}

private func resumeExpectingCompletionToolMismatch(
    _ target: AgentCheckpoint,
    agent: Agent<EmptyContext>,
    tokenBudget: Int? = nil
) async {
    let backend = InMemoryCheckpointer()
    do {
        try await backend.save(target)
        _ = try await agent.resume(
            from: target.checkpointID, checkpointer: backend,
            context: EmptyContext(), tokenBudget: tokenBudget
        )
        Issue.record("Expected completionToolMismatch")
    } catch let AgentCheckpointError.completionToolMismatch(checkpointed, live) {
        #expect(checkpointed == "finalize")
        #expect(live == nil)
    } catch {
        Issue.record("Expected completionToolMismatch, got \(error)")
    }
}

struct AgentResumeTests {
    @Test
    func resumeMissingCheckpointThrowsBeforeStream() async {
        let backend = InMemoryCheckpointer()
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        do {
            _ = try await agent.resume(
                from: CheckpointID(), checkpointer: backend, context: EmptyContext()
            )
            Issue.record("Expected notFound")
        } catch AgentCheckpointError.notFound(_) {
        } catch {
            Issue.record("Expected notFound, got \(error)")
        }
    }

    @Test(arguments: [TokenUsage(input: 5, output: 5), nil])
    func resumeReplaysTargetCheckpointAsReplayed(usage: TokenUsage?) async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let runID = RunID()
        let checkpointID = CheckpointID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            iterationUsage: usage,
            sessionID: session, runID: runID, checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let replayed = events.filter { event in
            if case .iterationCompleted = event.kind, case .replayed = event.origin {
                return true
            }
            return false
        }
        #expect(replayed.count == 1)
        #expect(replayed.first?.origin == .replayed(from: checkpointID))
        #expect(replayed.first?.sessionID == session)
        #expect(replayed.first?.runID == runID)
        #expect(replayed.first?.kind == .iterationCompleted(
            usage: usage, iteration: 1, history: checkpoint.messages
        ))
    }

    @Test
    func resumeDoesNotReplaySiblingCheckpointInSameSession() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let siblingID = CheckpointID()
        let targetID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Sibling"), .assistant(AssistantMessage(content: "sibling"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 3, output: 3)),
            iterationUsage: TokenUsage(input: 3, output: 3),
            sessionID: session,
            runID: RunID(),
            checkpointID: siblingID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await backend.save(AgentCheckpoint(
            messages: [.user("Target"), .assistant(AssistantMessage(content: "target"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session,
            runID: RunID(),
            checkpointID: targetID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_001)
        ))

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: targetID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let replayedOrigins = events.compactMap { event -> EventOrigin? in
            if case .iterationCompleted = event.kind, case .replayed = event.origin {
                return event.origin
            }
            return nil
        }
        #expect(replayedOrigins == [.replayed(from: targetID)])
        #expect(!replayedOrigins.contains(.replayed(from: siblingID)))
    }

    @Test
    func resumeContinuesLiveWithFreshRunIDAndSameSessionID() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let originalRun = RunID()
        let checkpointID = CheckpointID()
        let earlier = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            sessionID: session, runID: originalRun, checkpointID: checkpointID
        )
        try await backend.save(earlier)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let liveEvents = events.filter { $0.origin == .live }
        #expect(!liveEvents.isEmpty)
        let liveSessions = Set(liveEvents.compactMap(\.sessionID))
        let liveRuns = Set(liveEvents.compactMap(\.runID))
        #expect(liveSessions == [session])
        #expect(!liveRuns.contains(originalRun))
    }

    @Test
    func resumeAtMaxIterationsDoesNotCallClient() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "done"))],
            iteration: 5,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 1, output: 1)),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [],
            configuration: AgentConfiguration(maxIterations: 5)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let finished = events.last { event in
            if case .finished = event.kind {
                return true
            }
            return false
        }
        guard case let .finished(_, _, reason, _) = finished?.kind else {
            Issue.record("Expected .finished event")
            return
        }
        #expect(reason == .maxIterationsReached(limit: 5))
    }

    @Test
    func resumeOverTokenBudgetReplaysThenFinishesWithoutClientCall() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "done"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 100, output: 100)),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: []
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext(), tokenBudget: 50
        )
        let events = try await collect(stream)
        let replayedIndex = events.firstIndex { event in
            if case .replayed = event.origin, case .iterationCompleted = event.kind {
                return true
            }
            return false
        }
        let finishedIndex = events.firstIndex { event in
            if case .finished = event.kind {
                return true
            }
            return false
        }
        #expect(replayedIndex != nil)
        #expect(finishedIndex != nil)
        if let replayedIndex, let finishedIndex {
            #expect(replayedIndex < finishedIndex)
        }
        guard let finishedIndex, case let .finished(_, _, reason, _) = events[finishedIndex].kind else {
            Issue.record("Expected .finished event")
            return
        }
        if case let .tokenBudgetExceeded(budget, used) = reason {
            #expect(budget == 50)
            #expect(used == 200)
        } else {
            Issue.record("Expected .tokenBudgetExceeded, got \(String(describing: reason))")
        }
    }

    @Test
    func resumeStartsAtNextIteration() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        let session = SessionID()
        let checkpoint = AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 2,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        )
        try await backend.save(checkpoint)

        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]),
            tools: [],
            configuration: AgentConfiguration(maxIterations: 5)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        let events = try await collect(stream)
        let liveIteration = events.last { event in
            if case .iterationCompleted = event.kind, case .live = event.origin {
                return true
            }
            return false
        }
        guard case let .iterationCompleted(_, iterationNumber, _) = liveIteration?.kind else {
            Issue.record("Expected a live .iterationCompleted")
            return
        }
        #expect(iterationNumber == 3)
    }

    @Test
    func resumeRestoresMessagesWithoutRepeatingCompletedTool() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        let toolInvocationCount = ToolInvocationCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo",
            executor: { params, _ in
                await toolInvocationCount.increment()
                return EchoOutput(echoed: params.message)
            }
        )
        let toolResultMessage = ChatMessage.tool(id: "call_echo", name: "echo", content: #"{"echoed":"hi"}"#)
        let assistantCall = AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "call_echo", name: "echo", arguments: #"{"message":"hi"}"#)]
        )
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(assistantCall), toolResultMessage],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondFinishDeltas]),
            tools: [echoTool]
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext()
        )
        _ = try await collect(stream)
        let count = await toolInvocationCount.value
        #expect(count == 0)
    }

    @Test
    func resumeAfterApproveAlwaysDoesNotRequestApprovalAgain() async throws {
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .assistant(AssistantMessage(content: "first"))],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            iterationUsage: TokenUsage(input: 5, output: 5),
            sessionAllowlist: ["echo"],
            sessionID: session, runID: RunID(), checkpointID: checkpointID
        ))
        let approvalRequests = ApprovalCounter()
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echo",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let secondEchoCall: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_echo_2", name: "echo", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"again"}"#),
            .finished(usage: TokenUsage(input: 3, output: 3)),
        ]
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: [secondEchoCall, secondFinishDeltas]),
            tools: [echoTool],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: backend, context: EmptyContext(),
            approvalHandler: { _ in
                await approvalRequests.increment()
                return .approve
            }
        )
        _ = try await collect(stream)
        let count = await approvalRequests.value
        #expect(count == 0)
    }
}

struct LegacyCheckpointResumeTests {
    @Test
    func liveResponseCannotUpgradeLegacyAccounting() async throws {
        let archive = #"""
        {"messages":[{"role":"user","content":"Hi"}],"iteration":1,
         "tokenUsage":{"input":5,"output":5,"reasoning":0,"cacheRead":0},
         "sessionID":"00000000-0000-0000-0000-000000000001",
         "runID":"00000000-0000-0000-0000-000000000002",
         "checkpointID":"00000000-0000-0000-0000-000000000003","timestamp":0}
        """#
        let target = try JSONDecoder().decode(AgentCheckpoint.self, from: Data(archive.utf8))
        let backend = InMemoryCheckpointer()
        try await backend.save(target)
        let client = StreamingMockLLMClient(streamSequences: [secondFinishDeltas])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let events = try await collect(agent.resume(
            from: target.checkpointID, checkpointer: backend, context: EmptyContext()
        ))
        #expect(events.first?.kind == .iterationCompleted(usage: nil, iteration: 1, history: target.messages))
        guard case let .finished(totals, content, reason, _) = events.last?.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(totals.input == 12 && totals.output == 12)
        #expect(totals.coverage == .partial)
        #expect(totals.cacheRead == 0 && totals.cacheReadCoverage == .partial)
        #expect(totals.cacheWrite == nil && totals.cacheWriteCoverage == .unavailable)
        #expect(content == "live continuation" && reason == .completed)
        #expect(await client.allCapturedTools.count == 1)
        let encoded = try JSONEncoder().encode(totals)
        let restored = try JSONDecoder().decode(TokenUsageTotals.self, from: encoded)
        #expect(restored.input == 12 && restored.output == 12 && restored.coverage == .partial)
    }
}

struct AgentTerminalResumeTests {
    @Test
    func terminalCheckpointIsRefusedByABuiltInFinishAgent() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(),
            agent: Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        )
    }

    @Test
    func terminalCheckpointIsRefusedByAnAgentWithADifferentCompletionTool() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint()
        try await backend.save(target)
        let publish = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "publish",
            description: "Publish the final answer. Call it alone.",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []), tools: [], completionTool: publish
        )

        await #expect(throws: AgentCheckpointError.completionToolMismatch(
            checkpointed: "finalize", live: "publish"
        )) {
            _ = try await agent.resume(
                from: target.checkpointID, checkpointer: backend, context: EmptyContext()
            )
        }
    }

    @Test
    func terminalIdentityIsCheckedBeforeMCPBindingValidation() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(
                mcpToolBindings: [MCPToolBinding(serverName: "alpha", toolName: "search")]
            ),
            agent: Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        )
    }

    @Test
    func terminalIdentityIsCheckedWithoutRequiringAnApprovalHandler() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(),
            agent: Agent<EmptyContext>(
                client: StreamingMockLLMClient(streamSequences: []),
                tools: [],
                configuration: AgentConfiguration(approvalPolicy: .allTools)
            )
        )
    }

    @Test
    func terminalIdentityIsCheckedBeforeStructuralPreflight() async {
        await resumeExpectingCompletionToolMismatch(
            makeTerminalCheckpoint(iteration: 9),
            agent: Agent<EmptyContext>(
                client: StreamingMockLLMClient(streamSequences: []),
                tools: [],
                configuration: AgentConfiguration(maxIterations: 2)
            ),
            tokenBudget: 1
        )
    }

    @Test
    func malformedTerminalHistoryIsRejectedBeforeIdentityValidation() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint(messages: [
            .user("Summarize"),
            .tool(id: "orphan", name: "finalize", content: "{}"),
        ])
        try await backend.save(target)
        let agent = Agent<EmptyContext>(client: StreamingMockLLMClient(streamSequences: []), tools: [])
        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            _ = try await agent.resume(
                from: target.checkpointID, checkpointer: backend, context: EmptyContext()
            )
        }
    }

    @Test
    func malformedHistoryThrowsInsteadOfTrappingOnAMissingApprovalHandler() async throws {
        let backend = InMemoryCheckpointer()
        let checkpointID = CheckpointID()
        try await backend.save(AgentCheckpoint(
            messages: [.user("Hi"), .tool(id: "orphan", name: "echo", content: "{}")],
            iteration: 1,
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 5, output: 5)),
            sessionID: SessionID(), runID: RunID(), checkpointID: checkpointID
        ))
        let agent = Agent<EmptyContext>(
            client: StreamingMockLLMClient(streamSequences: []),
            tools: [],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        await #expect(throws: AgentError.malformedHistory(.unexpectedToolResult(id: "orphan"))) {
            _ = try await agent.resume(
                from: checkpointID, checkpointer: backend, context: EmptyContext()
            )
        }
    }

    @Test
    func terminalReplayCommitsTheSavedOutcomeWithoutLiveWork() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint()
        try await backend.save(target)
        let client = StreamingMockLLMClient(streamSequences: [secondFinishDeltas])
        let invocations = ToolInvocationCounter()
        let agent = try makeFinalizingAgent(client: client, invocations: invocations)

        let events = try await collect(agent.resume(
            from: target.checkpointID, checkpointer: backend, context: EmptyContext()
        ))

        #expect(events.count == 2)
        #expect(events.first?.origin == .replayed(from: target.checkpointID))
        guard case let .iterationCompleted(replayedUsage, iteration, replayedHistory) = events.first?.kind else {
            Issue.record("Expected a replayed .iterationCompleted")
            return
        }
        #expect(replayedUsage == TokenUsage(input: 5, output: 2))
        #expect(iteration == 1)
        #expect(replayedHistory == terminalMessages)

        #expect(events.last?.origin == .live)
        guard case let .finished(usage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(usage.input == 9)
        #expect(usage.output == 4)
        #expect(usage.reasoning == 0)
        #expect(usage.total == 13)
        #expect(usage.coverage == .complete)
        #expect(usage.cacheRead == nil && usage.cacheReadCoverage == .unavailable)
        #expect(usage.cacheWrite == nil && usage.cacheWriteCoverage == .unavailable)
        #expect(content == terminalOutcome.content)
        #expect(reason == .completed)
        #expect(history == terminalMessages)

        #expect(await client.allCapturedTools.isEmpty)
        #expect(await invocations.value == 0)
    }

    @Test
    func terminalReplayPreservesMissingIterationUsageWithoutLiveWork() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint(iterationUsage: nil)
        try await backend.save(target)
        let observer = SaveCountingCheckpointer(inner: backend)
        let client = StreamingMockLLMClient(streamSequences: [secondFinishDeltas])
        let invocations = ToolInvocationCounter()
        let agent = try makeFinalizingAgent(client: client, invocations: invocations)

        let events = try await collect(agent.resume(
            from: target.checkpointID, checkpointer: observer, context: EmptyContext()
        ))

        #expect(events.count == 2)
        #expect(events.first?.kind == .iterationCompleted(usage: nil, iteration: 1, history: terminalMessages))
        guard case let .finished(usage, content, reason, history) = events.last?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(usage.input == 9 && usage.output == 4 && usage.reasoning == 0 && usage.total == 13)
        #expect(usage.coverage == .complete)
        #expect(usage.cacheRead == nil && usage.cacheReadCoverage == .unavailable)
        #expect(usage.cacheWrite == nil && usage.cacheWriteCoverage == .unavailable)
        #expect(content == terminalOutcome.content && reason == .completed && history == terminalMessages)
        #expect(events.first?.origin == .replayed(from: target.checkpointID))
        #expect(events.first?.runID == target.runID)
        #expect(events.first?.sessionID == target.sessionID)
        #expect(events.last?.origin == .live)
        #expect(events.last?.sessionID == target.sessionID)
        #expect(await client.allCapturedTools.isEmpty)
        #expect(await invocations.value == 0)
        #expect(await observer.saveCount == 0)
    }

    @Test
    func aMatchingAgentReplaysATerminalCheckpointWithoutPreflight() async throws {
        let backend = InMemoryCheckpointer()
        let target = makeTerminalCheckpoint(
            iteration: 9,
            mcpToolBindings: [MCPToolBinding(serverName: "alpha", toolName: "search")]
        )
        try await backend.save(target)
        let client = StreamingMockLLMClient(streamSequences: [secondFinishDeltas])
        let invocations = ToolInvocationCounter()
        let agent = try makeFinalizingAgent(
            client: client, invocations: invocations,
            configuration: AgentConfiguration(maxIterations: 2, approvalPolicy: .allTools)
        )

        let events = try await collect(agent.resume(
            from: target.checkpointID, checkpointer: backend,
            context: EmptyContext(), tokenBudget: 1
        ))

        #expect(events.count == 2)
        guard case let .finished(_, content, reason, _) = events.last?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(content == terminalOutcome.content)
        #expect(reason == .completed)
        #expect(await client.allCapturedTools.isEmpty)
        #expect(await invocations.value == 0)
    }

    @Test
    func aCommittedStreamingCompletionReplaysThroughTheResumeAPI() async throws {
        let invocations = ToolInvocationCounter()
        let client = StreamingMockLLMClient(streamSequences: [[
            .toolCallStart(index: 0, id: "call_finalize", name: "finalize", kind: .function),
            .toolCallDelta(index: 0, arguments: #"{"message":"shipped"}"#),
            .finished(usage: TokenUsage(input: 5, output: 2)),
        ]])
        let backend = InMemoryCheckpointer()
        let session = SessionID()
        let agent = try makeFinalizingAgent(client: client, invocations: invocations)

        let liveEvents = try await collect(agent.stream(
            userMessage: "Summarize", context: EmptyContext(),
            sessionID: session, checkpointer: backend
        ))
        guard case let .finished(liveUsage, liveContent, _, liveHistory) = liveEvents.last?.kind else {
            Issue.record("Expected a committed finished event")
            return
        }

        let checkpointID = try #require(await backend.list(session: session).first)
        let observer = SaveCountingCheckpointer(inner: backend)
        let replayed = try await collect(agent.resume(
            from: checkpointID, checkpointer: observer, context: EmptyContext()
        ))

        #expect(replayed.count == 2)
        #expect(replayed.first?.origin == .replayed(from: checkpointID))
        guard case let .iterationCompleted(replayedUsage, iteration, replayedHistory) = replayed.first?.kind else {
            Issue.record("Expected a replayed .iterationCompleted")
            return
        }
        #expect(replayedUsage == TokenUsage(input: 5, output: 2))
        #expect(iteration == 1)
        #expect(replayedHistory == liveHistory)

        #expect(replayed.last?.origin == .live)
        guard case let .finished(usage, content, reason, history) = replayed.last?.kind else {
            Issue.record("Expected a live .finished")
            return
        }
        #expect(usage == liveUsage)
        #expect(content == liveContent)
        #expect(reason == .completed)
        #expect(history == liveHistory)

        #expect(await observer.saveCount == 0)
        #expect(await invocations.value == 1)
        #expect(await client.allCapturedTools.count == 1)
    }
}

private actor SaveCountingCheckpointer: AgentCheckpointer {
    private let inner: any AgentCheckpointer
    private(set) var saveCount = 0

    init(inner: any AgentCheckpointer) {
        self.inner = inner
    }

    func save(_ checkpoint: AgentCheckpoint) async throws {
        saveCount += 1
        try await inner.save(checkpoint)
    }

    func load(_ id: CheckpointID) async throws -> AgentCheckpoint {
        try await inner.load(id)
    }

    func list(session: SessionID) async throws -> [CheckpointID] {
        try await inner.list(session: session)
    }
}

private actor ApprovalCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

// v0.2 item 2.5: checkpoint resume does not restore the terminal answer twice.
//
// Finding: the built-in `finish` path writes no checkpoint for the iteration that
// ends with `finish` (`Agent.performStreamIteration` returns before
// `checkpointIfConfigured` when the iteration finishes; only `completionTool` runs
// store a terminal outcome). Checkpoints therefore hold raw, unsanitized messages
// from earlier iterations. Resuming re-runs the final model call, and
// `sanitizedTerminalHistory()` runs exactly once, on the live `.finished` path.
// A checkpoint whose messages already include a restored answer (from an earlier
// turn's history) passes through unchanged, because the restored message has no
// `finish` call left to sanitize.

private let resumeAnswer = "Resumed answer (terminal-answer-marker)."

private func resumeFinishDeltas(id: String, content: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: "finish", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"content": "\#(content)"}"#),
        .finished(usage: TokenUsage(input: 3, output: 3)),
    ]
}

private func resumeEchoDeltas(id: String) -> [StreamDelta] {
    [
        .toolCallStart(index: 0, id: id, name: "echo", kind: .function),
        .toolCallDelta(index: 0, arguments: #"{"message": "hi"}"#),
        .finished(usage: TokenUsage(input: 3, output: 3)),
    ]
}

private func makeEchoAgent(client: some LLMClient) throws -> Agent<EmptyContext> {
    let echo = try Tool<EchoParams, EchoOutput, EmptyContext>(
        name: "echo",
        description: "Echo the message.",
        executor: { params, _ in EchoOutput(echoed: params.message) }
    )
    return Agent<EmptyContext>(client: client, tools: [echo])
}

private func finishedHistory(of events: [StreamEvent]) throws -> [ChatMessage] {
    guard case let .finished(_, _, _, history) = events.last?.kind else {
        throw AgentError.llmError(.other("Expected a finished event"))
    }
    return history
}

private func answerCount(_ needle: String, in messages: [ChatMessage]) -> Int {
    messages.reduce(0) { count, message in
        let text: String = switch message {
        case let .system(text), let .user(text): text
        case let .assistant(assistant): assistant.content + assistant.toolCalls.map(\.arguments).joined()
        case let .tool(_, _, content): content
        case .userMultimodal: ""
        }
        return count + text.components(separatedBy: needle).count - 1
    }
}

struct AgentResumeTerminalAnswerTests {
    @Test
    func finishOnlyRunWritesNoCheckpoint() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [
            resumeFinishDeltas(id: "call_finish", content: resumeAnswer),
        ])
        let agent = try makeEchoAgent(client: client)
        let checkpointer = InMemoryCheckpointer()
        let sessionID = SessionID()

        let events = try await collect(agent.stream(
            userMessage: "Q", context: EmptyContext(),
            sessionID: sessionID, checkpointer: checkpointer
        ))

        #expect(try answerCount(resumeAnswer, in: finishedHistory(of: events)) == 1)
        #expect(try await checkpointer.list(session: sessionID).isEmpty)
    }

    @Test
    func resumeFromLastCheckpointHoldsAnswerOnce() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [
            resumeEchoDeltas(id: "call_echo"),
            resumeFinishDeltas(id: "call_finish", content: resumeAnswer),
            resumeFinishDeltas(id: "call_finish_resumed", content: resumeAnswer),
            [.content("Follow-up reply"), .finished(usage: TokenUsage(input: 3, output: 3))],
        ])
        let agent = try makeEchoAgent(client: client)
        let checkpointer = InMemoryCheckpointer()
        let sessionID = SessionID()

        let original = try await collect(agent.stream(
            userMessage: "Q", context: EmptyContext(),
            sessionID: sessionID, checkpointer: checkpointer
        ))
        #expect(try answerCount(resumeAnswer, in: finishedHistory(of: original)) == 1)

        let checkpointID = try #require(try await checkpointer.list(session: sessionID).last)
        let snapshot = try await checkpointer.load(checkpointID)
        #expect(answerCount(resumeAnswer, in: snapshot.messages) == 0)

        // (a) The resumed run's finished history holds the answer once.
        let resumed = try await collect(agent.resume(
            from: checkpointID, checkpointer: checkpointer, context: EmptyContext()
        ))
        let resumedHistory = try finishedHistory(of: resumed)
        #expect(answerCount(resumeAnswer, in: resumedHistory) == 1)
        guard case let .assistant(last) = resumedHistory.last else {
            Issue.record("Expected the restored answer to end resumed history")
            return
        }
        #expect(last.content == resumeAnswer)
        #expect(last.toolCalls.isEmpty)
        try resumedHistory.validateForAgentHistory()

        // (b) A follow-up turn's request holds it once.
        _ = try await collect(agent.stream(
            userMessage: "Thanks", history: resumedHistory, context: EmptyContext()
        ))
        let followUpRequest = try #require(await client.allCapturedMessages.last)
        #expect(answerCount(resumeAnswer, in: followUpRequest) == 1)
        try followUpRequest.validateForLLMRequest()
    }

    @Test
    func resumeOverRestoredEarlierAnswerDoesNotDuplicateIt() async throws {
        let earlierHistory: [ChatMessage] = [
            .user("Earlier question"),
            .assistant(AssistantMessage(content: resumeAnswer)),
        ]
        let client = CapturingStreamingMockLLMClient(streamSequences: [
            resumeEchoDeltas(id: "call_echo"),
            resumeFinishDeltas(id: "call_finish", content: "Second answer"),
            resumeFinishDeltas(id: "call_finish_resumed", content: "Second answer"),
        ])
        let agent = try makeEchoAgent(client: client)
        let checkpointer = InMemoryCheckpointer()
        let sessionID = SessionID()

        _ = try await collect(agent.stream(
            userMessage: "Next", history: earlierHistory, context: EmptyContext(),
            sessionID: sessionID, checkpointer: checkpointer
        ))
        let checkpointID = try #require(try await checkpointer.list(session: sessionID).last)

        let resumed = try await collect(agent.resume(
            from: checkpointID, checkpointer: checkpointer, context: EmptyContext()
        ))
        let resumedHistory = try finishedHistory(of: resumed)

        #expect(answerCount(resumeAnswer, in: resumedHistory) == 1)
        #expect(answerCount("Second answer", in: resumedHistory) == 1)
        let resumeRequest = try #require(await client.allCapturedMessages.last)
        #expect(answerCount(resumeAnswer, in: resumeRequest) == 1)
    }
}
