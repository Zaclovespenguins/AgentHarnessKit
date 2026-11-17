import Foundation

extension Agent {
    /// Resumes a previously checkpointed run, replaying iteration history before continuing live.
    public func resume(
        from checkpointID: CheckpointID,
        checkpointer: any AgentCheckpointer,
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let target = try await checkpointer.load(checkpointID)
        return try await resume(
            target: target, checkpointer: checkpointer, context: context,
            tokenBudget: tokenBudget, requestContext: requestContext,
            approvalHandler: approvalHandler
        )
    }

    func resume(
        target: AgentCheckpoint,
        checkpointer: any AgentCheckpointer,
        context: C,
        tokenBudget: Int? = nil,
        requestContext: RequestContext? = nil,
        approvalHandler: ToolApprovalHandler? = nil
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let options = InvocationOptions(
            tokenBudget: tokenBudget, requestContext: requestContext,
            systemPromptOverride: nil, approvalHandler: approvalHandler,
            sessionID: target.sessionID, runID: RunID(),
            checkpointer: checkpointer
        )
        if let expected = target.contextStateVersion {
            let actual = try await configuration.contextStore?.stateVersion(sessionID: target.sessionID)
            guard actual == expected else {
                throw AgentCheckpointError.contextStateMismatch(expected: expected, actual: actual)
            }
        }
        try target.messages.validateForAgentHistory()
        if let terminalOutcome = target.terminalOutcome {
            try completionPolicy.validateIdentity(of: terminalOutcome)
            return replayTerminalOutcome(
                terminalOutcome, target: target, eventFactory: options.eventFactory
            )
        }
        validateInvocation(options)
        try validateMCPBindings(target.mcpToolBindings)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await replayAndContinueResume(
                        target: target, context: context,
                        options: options, continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func replayTerminalOutcome(
        _ outcome: AgentTerminalOutcome,
        target: AgentCheckpoint,
        eventFactory: StreamEventFactory
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(replayedIterationEvent(target: target))
            finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: target.tokenUsage,
                    content: outcome.content,
                    reason: .completed,
                    history: target.messages,
                    eventFactory: eventFactory
                )
            )
        }
    }

    private func replayedIterationEvent(target: AgentCheckpoint) -> StreamEvent {
        StreamEventFactory(
            sessionID: target.sessionID,
            runID: target.runID,
            origin: .replayed(from: target.checkpointID)
        ).make(.iterationCompleted(
            usage: target.iterationUsage,
            iteration: target.iteration,
            history: target.messages
        ))
    }

    private func validateMCPBindings(_ checkpointed: Set<MCPToolBinding>) throws {
        guard !checkpointed.isEmpty else { return }
        let liveBindings = Set(tools.compactMap { ($0 as? any MCPBindingProviding)?.mcpToolBinding })
        let missing = checkpointed.subtracting(liveBindings)
        guard missing.isEmpty else {
            throw AgentCheckpointError.mcpBindingMismatch(
                missing.sorted { ($0.serverName, $0.toolName) < ($1.serverName, $1.toolName) }
            )
        }
    }

    private func replayAndContinueResume(
        target: AgentCheckpoint,
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        continuation.yield(replayedIterationEvent(target: target))
        var state = AgentLoopState(
            messages: target.messages,
            sessionAllowlist: target.sessionAllowlist,
            recordedCount: target.messages.count
        )
        if let earlyFinish = earlyFinishEvent(target: target, options: options) {
            finishStreaming(continuation: continuation, event: earlyFinish)
            return
        }
        try await performStreamLoop(
            state: &state, startIteration: target.iteration + 1,
            totalUsage: target.tokenUsage,
            context: context, options: options,
            continuation: continuation
        )
    }

    private func earlyFinishEvent(target: AgentCheckpoint, options: InvocationOptions) -> StreamEvent? {
        if let tokenBudget = options.tokenBudget, target.tokenUsage.total > tokenBudget {
            return makeFinishedEvent(
                tokenUsage: target.tokenUsage, content: nil,
                reason: .tokenBudgetExceeded(budget: tokenBudget, used: target.tokenUsage.total),
                history: target.messages, eventFactory: options.eventFactory
            )
        }
        if target.iteration >= configuration.maxIterations {
            return makeFinishedEvent(
                tokenUsage: target.tokenUsage, content: nil,
                reason: .maxIterationsReached(limit: configuration.maxIterations),
                history: target.messages, eventFactory: options.eventFactory
            )
        }
        return nil
    }
}
