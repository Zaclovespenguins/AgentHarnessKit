import Foundation

/// Configuration for the agent loop.
///
/// For a guide, see <doc:AgentAndChat>.
public struct AgentConfiguration: Sendable {
    public let maxIterations: Int
    public let toolTimeout: Duration
    public let systemPrompt: String?
    public let maxToolResultCharacters: Int?
    public let contextStore: (any ContextStore)?
    public let approvalPolicy: ToolApprovalPolicy
    /// Maximum sub-agent depth at which iteration events carry the history snapshot; nil means no limit.
    public let historyEmissionDepthLimit: Int?
    /// Offers the model the built-in `finish` tool. Off by default: the agent ends when the model replies with
    /// plain text and no tool calls, which streams as `.delta` events. A `finish` answer arrives only in
    /// `.finished`, because tool-call arguments are not streamed. Ignored when the agent has a completion tool.
    public let offersFinishTool: Bool

    public init(
        maxIterations: Int = 10,
        toolTimeout: Duration = .seconds(30),
        systemPrompt: String? = nil,
        maxToolResultCharacters: Int? = nil,
        contextStore: (any ContextStore)? = nil,
        approvalPolicy: ToolApprovalPolicy = .none,
        historyEmissionDepthLimit: Int? = nil,
        offersFinishTool: Bool = false
    ) {
        precondition(maxIterations >= 1, "maxIterations must be at least 1")
        precondition(toolTimeout >= .milliseconds(1), "toolTimeout must be at least 1ms")
        if let maxToolResultCharacters {
            precondition(maxToolResultCharacters >= 1, "maxToolResultCharacters must be at least 1")
        }
        precondition(
            historyEmissionDepthLimit.map { $0 >= 0 } ?? true,
            "historyEmissionDepthLimit must be non-negative"
        )
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.systemPrompt = systemPrompt
        self.maxToolResultCharacters = maxToolResultCharacters
        self.contextStore = contextStore
        self.approvalPolicy = approvalPolicy
        self.historyEmissionDepthLimit = historyEmissionDepthLimit
        self.offersFinishTool = offersFinishTool
    }
}
