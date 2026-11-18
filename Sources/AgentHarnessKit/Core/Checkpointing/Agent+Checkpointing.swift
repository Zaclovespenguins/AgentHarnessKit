import Foundation

extension Agent {
    @discardableResult
    func checkpointIfConfigured(
        iterationNumber: Int,
        state: AgentLoopState,
        totalUsage: TokenUsageTotals,
        iterationUsage: TokenUsage?,
        eventFactory: StreamEventFactory,
        checkpointer: (any AgentCheckpointer)?,
        terminalOutcome: AgentTerminalOutcome? = nil
    ) async throws -> CheckpointID? {
        guard let checkpointer,
              let sessionID = eventFactory.sessionID,
              let runID = eventFactory.runID
        else { return nil }
        let contextStateVersion = try await configuration.contextStore?.stateVersion(sessionID: sessionID)
        let checkpoint = AgentCheckpoint(
            messages: state.messages,
            iteration: iterationNumber,
            tokenUsage: totalUsage,
            iterationUsage: iterationUsage,
            sessionAllowlist: state.sessionAllowlist,
            sessionID: sessionID,
            runID: runID,
            checkpointID: CheckpointID(),
            timestamp: Date(),
            mcpToolBindings: mcpToolBindings(in: state.messages),
            terminalOutcome: terminalOutcome,
            contextStateVersion: contextStateVersion
        )
        try await checkpointer.save(checkpoint)
        return checkpoint.checkpointID
    }

    func mcpToolBindings(in messages: [ChatMessage]) -> Set<MCPToolBinding> {
        let participatingNames = Set(messages.flatMap { message -> [String] in
            switch message {
            case let .assistant(assistant): assistant.toolCalls.map(\.name)
            case let .tool(_, name, _): [name]
            default: []
            }
        })
        return Set(tools.compactMap { tool in
            guard participatingNames.contains(tool.name) else { return nil }
            return (tool as? any MCPBindingProviding)?.mcpToolBinding
        })
    }
}
