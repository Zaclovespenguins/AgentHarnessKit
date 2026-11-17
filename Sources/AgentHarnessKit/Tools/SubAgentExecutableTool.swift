import Foundation

/// Loop-facing entry points for tools that run a child agent. The loop dispatches these instead of `execute`
/// so it can forward approvals and, when streaming, wrap child events as `subAgentEvent`.
///
/// The child always runs under its own freshly minted `SessionID` (docs/ARCHITECTURE.md §5), so no parent
/// session id is passed in.
protocol SubAgentExecutableTool<Context>: AnyTool {
    func executeSubAgent(
        arguments: Data,
        context: Context,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult

    func executeSubAgentStreaming(
        arguments: Data,
        context: Context,
        eventHandler: @Sendable (StreamEvent) -> Void,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> ToolResult
}
