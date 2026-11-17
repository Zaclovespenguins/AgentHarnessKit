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
            terminalOutcome: terminalOutcome
        )
        try await checkpointer.save(checkpoint)
        return checkpoint.checkpointID
    }

    func mcpToolBindings(in messages: [ChatMessage]) -> Set<MCPToolBinding> {
        // shortcut: no MCPTool type until Phase 6, so no bindings are recorded; derive them from MCPTool there.
        return []
    }
}
