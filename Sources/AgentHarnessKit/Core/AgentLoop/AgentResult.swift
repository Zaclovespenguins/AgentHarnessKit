import Foundation

public struct AgentResult: Sendable, Equatable {
    public let finishReason: FinishReason
    public let content: String?
    public let totalTokenUsage: TokenUsageTotals
    public let iterations: Int
    public let history: [ChatMessage]

    public init(
        finishReason: FinishReason,
        content: String?,
        totalTokenUsage: TokenUsageTotals,
        iterations: Int,
        history: [ChatMessage] = []
    ) {
        self.finishReason = finishReason
        self.content = content
        self.totalTokenUsage = totalTokenUsage
        self.iterations = iterations
        self.history = history
    }
}
