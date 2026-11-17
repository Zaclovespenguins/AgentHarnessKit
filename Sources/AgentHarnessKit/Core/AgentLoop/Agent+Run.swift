import Foundation

extension Agent {
    func renderedMessages(_ messages: [ChatMessage], sessionID: SessionID) async throws -> [ChatMessage] {
        try await configuration.contextStore?.render(sessionID: sessionID, messages: messages) ?? messages
    }

    func recordNewMessages(state: inout AgentLoopState, usage: TokenUsage?, sessionID: SessionID) async throws {
        guard let store = configuration.contextStore, state.recordedCount < state.messages.count else { return }
        try await store.record(
            sessionID: sessionID,
            messages: Array(state.messages[state.recordedCount...]),
            usage: usage
        )
        state.recordedCount = state.messages.count
    }

    func executeRunIteration(
        state: inout AgentLoopState,
        totalUsage: inout TokenUsageTotals,
        requestContext: RequestContext?,
        sessionID: SessionID
    ) async throws -> AssistantMessage {
        let requestMessages = try await renderedMessages(state.messages, sessionID: sessionID)
        let response = try await client.generate(
            messages: requestMessages,
            tools: toolDefinitions,
            responseFormat: nil,
            requestContext: requestContext
        )
        totalUsage.record(response.tokenUsage)
        state.messages.append(.assistant(response))
        return response
    }

    func resolveRunIteration(
        response: AssistantMessage,
        context: C,
        iteration: Int,
        totalUsage: TokenUsageTotals,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) async throws -> AgentResult? {
        switch try completionPolicy.classify(response.toolCalls) {
        case let .builtInFinish(finishCall):
            return try parseFinishResult(
                finishCall,
                tokenUsage: totalUsage,
                iterations: iteration,
                history: state.messages
            )

        case let .executableCompletion(call):
            return try await completeRunIteration(
                call: call, context: context, iteration: iteration,
                totalUsage: totalUsage,
                options: options, state: &state
            )

        case let .exclusivityViolation(toolName, calls):
            return try continueRunIteration(
                results: exclusivityFeedbackResults(for: calls, toolName: toolName), iteration: iteration,
                totalUsage: totalUsage,
                options: options, state: &state
            )

        case .none:
            if completionPolicy.allowsContentOnlyTermination,
               shouldTerminateOnContent(toolCalls: response.toolCalls, content: response.content) {
                return try AgentResult(
                    finishReason: .completed,
                    content: response.content,
                    totalTokenUsage: totalUsage,
                    iterations: iteration,
                    history: state.messages.sanitizedTerminalHistory()
                )
            }
            return try await finalizeRunIteration(
                toolCalls: response.toolCalls, context: context, iteration: iteration,
                totalUsage: totalUsage,
                options: options, state: &state
            )
        }
    }

    private func completeRunIteration(
        call: ToolCall,
        context: C,
        iteration: Int,
        totalUsage: TokenUsageTotals,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) async throws -> AgentResult? {
        switch try await executeCompletionCall(
            call, context: context, messages: state.messages,
            options: options, allowlist: &state.sessionAllowlist
        ) {
        case let .completed(outcome):
            state.messages.append(.tool(id: call.id, name: call.name, content: outcome.content))
            try state.messages.validateForAgentHistory()
            return AgentResult(
                finishReason: .completed,
                content: outcome.content,
                totalTokenUsage: totalUsage,
                iterations: iteration,
                history: state.messages
            )

        case let .feedback(result):
            return try continueRunIteration(
                results: [IndexedToolResult(index: 0, call: call, result: result)],
                iteration: iteration, totalUsage: totalUsage,
                options: options, state: &state
            )
        }
    }

    private func finalizeRunIteration(
        toolCalls: [ToolCall],
        context: C,
        iteration: Int,
        totalUsage: TokenUsageTotals,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) async throws -> AgentResult? {
        let results = try await executeResults(
            indexedToolCalls(from: toolCalls),
            context: context,
            messages: state.messages,
            approvalHandler: options.approvalHandler,
            allowlist: &state.sessionAllowlist
        )
        return try continueRunIteration(
            results: results,
            iteration: iteration, totalUsage: totalUsage,
            options: options, state: &state
        )
    }

    private func continueRunIteration(
        results: [IndexedToolResult],
        iteration: Int,
        totalUsage: TokenUsageTotals,
        options: InvocationOptions,
        state: inout AgentLoopState
    ) throws -> AgentResult? {
        appendToolResults(results, messages: &state.messages)
        try state.messages.validateForAgentHistory()

        guard let tokenBudget = options.tokenBudget, totalUsage.total > tokenBudget else {
            return nil
        }
        return makeTerminalResult(
            reason: .tokenBudgetExceeded(budget: tokenBudget, used: totalUsage.total),
            tokenUsage: totalUsage,
            iterations: iteration,
            history: state.messages
        )
    }

    func parseFinishResult(
        _ call: ToolCall,
        tokenUsage: TokenUsageTotals,
        iterations: Int,
        history: [ChatMessage]
    ) throws -> AgentResult {
        let decoded = try decodeFinishArguments(from: call.argumentsData)
        return try AgentResult(
            finishReason: FinishReason(decoded.reason ?? "completed"),
            content: decoded.content,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history.sanitizedTerminalHistory()
        )
    }

    func makeTerminalResult(
        reason: FinishReason,
        tokenUsage: TokenUsageTotals,
        iterations: Int,
        history: [ChatMessage]
    ) -> AgentResult {
        AgentResult(
            finishReason: reason,
            content: nil,
            totalTokenUsage: tokenUsage,
            iterations: iterations,
            history: history
        )
    }
}
