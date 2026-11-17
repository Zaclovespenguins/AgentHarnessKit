import Foundation

extension Agent {
    func resolveStreamingIteration(
        iteration: StreamIteration,
        iterationNumber: Int,
        totalUsage: TokenUsageTotals,
        iterationContext: StreamIterationContext,
        sessionID: SessionID,
        state: inout AgentLoopState
    ) async throws -> Bool {
        let factory = iterationContext.options.eventFactory
        let continuation = iterationContext.continuation
        switch try completionPolicy.classify(iteration.toolCalls) {
        case let .builtInFinish(finishCall):
            try await recordNewMessages(state: &state, usage: iteration.usage, sessionID: sessionID)
            try finishStreaming(
                continuation: continuation,
                event: parseFinishEvent(
                    from: finishCall, tokenUsage: totalUsage,
                    history: state.messages, eventFactory: factory
                )
            )
            return true

        case let .executableCompletion(call):
            return try await completeStreamingIteration(
                call: call, iteration: iteration, iterationNumber: iterationNumber,
                totalUsage: totalUsage, iterationContext: iterationContext,
                sessionID: sessionID, state: &state
            )

        case let .exclusivityViolation(toolName, calls):
            let emit = StreamEmitter(factory: factory, continuation: continuation)
            let results = exclusivityFeedbackResults(for: calls, toolName: toolName)
            for entry in results {
                emit.yield(.toolCallCompleted(
                    id: entry.call.id, name: entry.call.name, result: entry.result
                ))
            }
            try continueStreamingIteration(results: results, state: &state)
            return false

        case .none:
            if completionPolicy.allowsContentOnlyTermination,
               shouldTerminateOnContent(toolCalls: iteration.toolCalls, content: iteration.effectiveContent) {
                try await recordNewMessages(state: &state, usage: iteration.usage, sessionID: sessionID)
                try finishStreaming(
                    continuation: continuation,
                    event: makeFinishedEvent(
                        tokenUsage: totalUsage,
                        content: iteration.effectiveContent,
                        reason: .completed,
                        history: state.messages.sanitizedTerminalHistory(),
                        eventFactory: factory
                    )
                )
                return true
            }
            try await finalizeStreamingIteration(
                toolCalls: iteration.toolCalls, context: iterationContext.context,
                options: iterationContext.options,
                continuation: continuation, state: &state
            )
            return false
        }
    }

    private func completeStreamingIteration(
        call: ToolCall,
        iteration: StreamIteration,
        iterationNumber: Int,
        totalUsage: TokenUsageTotals,
        iterationContext: StreamIterationContext,
        sessionID: SessionID,
        state: inout AgentLoopState
    ) async throws -> Bool {
        let options = iterationContext.options
        let continuation = iterationContext.continuation
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)
        switch try await executeStreamingCompletionCall(
            call, context: iterationContext.context, messages: state.messages,
            options: options, emit: emit, allowlist: &state.sessionAllowlist
        ) {
        case let .completed(outcome):
            state.messages.append(.tool(id: call.id, name: call.name, content: outcome.content))
            try state.messages.validateForAgentHistory()
            try await recordNewMessages(state: &state, usage: iteration.usage, sessionID: sessionID)
            try await checkpointIfConfigured(
                iterationNumber: iterationNumber, state: state,
                totalUsage: totalUsage, iterationUsage: iteration.usage,
                eventFactory: options.eventFactory, checkpointer: options.checkpointer,
                terminalOutcome: outcome
            )
            finishStreaming(
                continuation: continuation,
                event: makeFinishedEvent(
                    tokenUsage: totalUsage, content: outcome.content, reason: .completed,
                    history: state.messages, eventFactory: options.eventFactory
                )
            )
            return true

        case let .feedback(result):
            try continueStreamingIteration(
                results: [IndexedToolResult(index: 0, call: call, result: result)],
                state: &state
            )
            return false
        }
    }

    private func finalizeStreamingIteration(
        toolCalls: [ToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        state: inout AgentLoopState
    ) async throws {
        let results = try await executeStreamingResults(
            indexedToolCalls(from: toolCalls),
            context: context,
            messages: state.messages,
            options: options,
            continuation: continuation,
            allowlist: &state.sessionAllowlist
        )
        try continueStreamingIteration(results: results, state: &state)
    }

    private func continueStreamingIteration(
        results: [IndexedToolResult],
        state: inout AgentLoopState
    ) throws {
        appendToolResults(results, messages: &state.messages)
        try state.messages.validateForAgentHistory()
    }

    func generateStreamingResponse(
        processor: StreamProcessor,
        messages: [ChatMessage],
        totalUsage: inout TokenUsageTotals,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        options: InvocationOptions
    ) async throws -> StreamIteration {
        var emittedOutput = false
        return try await processor.process(
            messages: messages,
            totalUsage: &totalUsage,
            emittedOutput: &emittedOutput,
            continuation: continuation,
            requestContext: options.requestContext
        )
    }
}
