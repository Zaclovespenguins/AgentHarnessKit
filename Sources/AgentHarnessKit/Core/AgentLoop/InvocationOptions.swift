import Foundation

struct InvocationOptions {
    let tokenBudget: Int?
    let requestContext: RequestContext?
    let systemPromptOverride: String?
    let approvalHandler: ToolApprovalHandler?
    let sessionID: SessionID?
    let runID: RunID?
    let checkpointer: (any AgentCheckpointer)?
    let eventFactory: StreamEventFactory
    /// When set, the streaming loop records the in-flight turn so `AgentStream` can expose it after cancel.
    package var partialTurnRecorder: PartialTurnRecorder? = nil

    init(
        tokenBudget: Int?,
        requestContext: RequestContext?,
        systemPromptOverride: String?,
        approvalHandler: ToolApprovalHandler?,
        sessionID: SessionID? = nil,
        runID: RunID? = nil,
        checkpointer: (any AgentCheckpointer)? = nil
    ) {
        self.tokenBudget = tokenBudget
        self.requestContext = requestContext
        self.systemPromptOverride = systemPromptOverride
        self.approvalHandler = approvalHandler
        self.sessionID = sessionID
        self.runID = runID
        self.checkpointer = checkpointer
        eventFactory = StreamEventFactory(sessionID: sessionID, runID: runID, origin: .live)
    }
}
