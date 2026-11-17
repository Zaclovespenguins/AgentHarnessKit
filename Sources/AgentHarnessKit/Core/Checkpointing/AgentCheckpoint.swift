import Foundation

/// A tool backed by an MCP server. Checkpoints record its binding when it took part in the run,
/// and resume fails unless the resuming agent has a tool with the same binding.
public protocol MCPBindingProviding {
    var mcpToolBinding: MCPToolBinding { get }
}

/// Identifies a live MCP tool binding required to resume a checkpoint.
public struct MCPToolBinding: Sendable, Codable, Hashable {
    public let serverName: String
    public let toolName: String

    public init(serverName: String, toolName: String) {
        precondition(!serverName.isEmpty, "serverName must be non-empty")
        precondition(!toolName.isEmpty, "toolName must be non-empty")
        self.serverName = serverName
        self.toolName = toolName
    }

    private enum CodingKeys: String, CodingKey { case serverName, toolName }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverName = try container.decode(String.self, forKey: .serverName)
        let toolName = try container.decode(String.self, forKey: .toolName)
        guard !serverName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .serverName, in: container,
                debugDescription: "MCPToolBinding.serverName must be non-empty"
            )
        }
        guard !toolName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .toolName, in: container,
                debugDescription: "MCPToolBinding.toolName must be non-empty"
            )
        }
        self.init(serverName: serverName, toolName: toolName)
    }
}

/// Serializable snapshot of agent loop state captured at a full iteration boundary.
public struct AgentCheckpoint: Sendable, Codable, Identifiable {
    public let messages: [ChatMessage]
    public let iteration: Int
    public let tokenUsage: TokenUsageTotals
    public let iterationUsage: TokenUsage?
    public let sessionAllowlist: Set<String>
    public let sessionID: SessionID
    public let runID: RunID
    public let checkpointID: CheckpointID
    public let timestamp: Date
    public let mcpToolBindings: Set<MCPToolBinding>
    public let terminalOutcome: AgentTerminalOutcome?
    /// The context store's `stateVersion` when the checkpoint was taken; nil without a store or when it keeps no state.
    public let contextStateVersion: String?

    public var id: CheckpointID {
        checkpointID
    }

    public init(
        messages: [ChatMessage],
        iteration: Int,
        tokenUsage: TokenUsageTotals,
        iterationUsage: TokenUsage? = nil,
        sessionAllowlist: Set<String> = [],
        sessionID: SessionID,
        runID: RunID,
        checkpointID: CheckpointID = CheckpointID(),
        timestamp: Date = Date(),
        mcpToolBindings: Set<MCPToolBinding> = [],
        contextStateVersion: String? = nil
    ) {
        self.init(
            messages: messages,
            iteration: iteration,
            tokenUsage: tokenUsage,
            iterationUsage: iterationUsage,
            sessionAllowlist: sessionAllowlist,
            sessionID: sessionID,
            runID: runID,
            checkpointID: checkpointID,
            timestamp: timestamp,
            mcpToolBindings: mcpToolBindings,
            terminalOutcome: nil,
            contextStateVersion: contextStateVersion
        )
    }

    init(
        messages: [ChatMessage],
        iteration: Int,
        tokenUsage: TokenUsageTotals,
        iterationUsage: TokenUsage?,
        sessionAllowlist: Set<String>,
        sessionID: SessionID,
        runID: RunID,
        checkpointID: CheckpointID,
        timestamp: Date,
        mcpToolBindings: Set<MCPToolBinding>,
        terminalOutcome: AgentTerminalOutcome?,
        contextStateVersion: String? = nil
    ) {
        precondition(iteration >= 0, "iteration must be non-negative")
        self.messages = messages
        self.iteration = iteration
        self.tokenUsage = tokenUsage
        self.iterationUsage = iterationUsage
        self.sessionAllowlist = sessionAllowlist
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointID = checkpointID
        self.timestamp = timestamp
        self.mcpToolBindings = mcpToolBindings
        self.terminalOutcome = terminalOutcome
        self.contextStateVersion = contextStateVersion
    }

    private enum CodingKeys: String, CodingKey {
        case messages, iteration, tokenUsage, iterationUsage, sessionAllowlist
        case sessionID, runID, checkpointID, timestamp, mcpToolBindings, terminalOutcome
        case contextStateVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let iteration = try container.decode(Int.self, forKey: .iteration)
        guard iteration >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .iteration, in: container,
                debugDescription: "AgentCheckpoint.iteration must be non-negative, got \(iteration)"
            )
        }
        try self.init(
            messages: container.decode([ChatMessage].self, forKey: .messages),
            iteration: iteration,
            tokenUsage: container.decode(TokenUsageTotals.self, forKey: .tokenUsage),
            iterationUsage: container.decodeIfPresent(TokenUsage.self, forKey: .iterationUsage),
            sessionAllowlist: Set(container.decodeIfPresent([String].self, forKey: .sessionAllowlist) ?? []),
            sessionID: container.decode(SessionID.self, forKey: .sessionID),
            runID: container.decode(RunID.self, forKey: .runID),
            checkpointID: container.decode(CheckpointID.self, forKey: .checkpointID),
            timestamp: container.decode(Date.self, forKey: .timestamp),
            mcpToolBindings: Set(container.decodeIfPresent(
                [MCPToolBinding].self, forKey: .mcpToolBindings
            ) ?? []),
            terminalOutcome: container.decodeIfPresent(
                AgentTerminalOutcome.self, forKey: .terminalOutcome
            ),
            contextStateVersion: container.decodeIfPresent(String.self, forKey: .contextStateVersion)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messages, forKey: .messages)
        try container.encode(iteration, forKey: .iteration)
        try container.encode(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(iterationUsage, forKey: .iterationUsage)
        if !sessionAllowlist.isEmpty {
            try container.encode(sessionAllowlist.sorted(), forKey: .sessionAllowlist)
        }
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(runID, forKey: .runID)
        try container.encode(checkpointID, forKey: .checkpointID)
        try container.encode(timestamp, forKey: .timestamp)
        if !mcpToolBindings.isEmpty {
            try container.encode(
                mcpToolBindings.sorted { ($0.serverName, $0.toolName) < ($1.serverName, $1.toolName) },
                forKey: .mcpToolBindings
            )
        }
        try container.encodeIfPresent(terminalOutcome, forKey: .terminalOutcome)
        try container.encodeIfPresent(contextStateVersion, forKey: .contextStateVersion)
    }
}

/// Errors thrown by `AgentCheckpointer` backends and `Agent.resume`.
public enum AgentCheckpointError: Error, Sendable, Equatable, LocalizedError {
    case notFound(CheckpointID)
    case fileSystem(String)
    case mcpBindingMismatch([MCPToolBinding])
    case completionToolMismatch(checkpointed: String, live: String?)
    case contextStateMismatch(expected: String, actual: String?)

    public var errorDescription: String? {
        switch self {
        case let .notFound(id):
            return "Checkpoint not found: \(id.rawValue.uuidString)"
        case let .fileSystem(reason):
            return "Checkpoint file system error: \(reason)"
        case let .mcpBindingMismatch(missing):
            let names = missing.map { "\($0.serverName)::\($0.toolName)" }.joined(separator: ", ")
            return "Missing MCP tool bindings on resume: \(names)"
        case let .completionToolMismatch(checkpointed, live):
            return """
            Terminal checkpoint completed through \(checkpointed), \
            but the resuming agent completes through \(live ?? "the built-in finish tool")
            """
        case let .contextStateMismatch(expected, actual):
            return """
            Checkpoint context state \(expected) does not match \
            the resuming context store state \(actual ?? "(none)")
            """
        }
    }
}
