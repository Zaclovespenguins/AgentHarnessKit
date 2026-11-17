import AgentHarnessKit
import Foundation

public extension ContextPipeline {
    /// True when `Double(usedTokens) >= nudgeFloor * Double(windowSize)` and either `baseline` is nil or
    /// `usedTokens - baseline >= nudgeGrowthTokens`.
    static func shouldNudge(
        usedTokens: Int,
        windowSize: Int,
        baseline: Int?,
        configuration: ContextConfiguration
    ) -> Bool {
        guard Double(usedTokens) >= configuration.nudgeFloor * Double(windowSize) else { return false }
        guard let baseline else { return true }
        return usedTokens - baseline >= configuration.nudgeGrowthTokens
    }

    /// `.user` message: `configuration.nudgeText`, a blank line, then either
    /// `"Compressible ranges (N, oldest first):"` followed by one line per range
    /// `"mSTART–mEND  <count> msgs  <tokens> tokens"` (en dash; count and token sum over messages in the range),
    /// or `"No compressible ranges right now."` when `ranges` is empty.
    static func nudgeMessage(
        ranges: [ClosedRange<MessageRef>],
        messages: [StoredMessage],
        configuration: ContextConfiguration
    ) -> ChatMessage {
        let body: [String]
        if ranges.isEmpty {
            body = ["No compressible ranges right now."]
        } else {
            body = ["Compressible ranges (\(ranges.count), oldest first):"] + ranges.map { range in
                let inRange = messages.filter { range.contains($0.ref) }
                let tokens = inRange.reduce(0) { $0 + $1.tokens }
                return "\(range.lowerBound)\u{2013}\(range.upperBound)  \(inRange.count) msgs  \(tokens) tokens"
            }
        }
        return .user(([configuration.nudgeText, ""] + body).joined(separator: "\n"))
    }

    /// Last resort when the sum of `RenderItem.tokens` exceeds `Int(Double(windowSize) * emergencyThreshold)`;
    /// otherwise returns `items` unchanged. Never touches `.summary` items or refs in `protected`.
    /// Phase 1, oldest first: replace the content of each `.tool` message with more than 64 tokens by
    /// `"[Output truncated to fit the context window: <tokens> tokens. Original kept as <ref>; use search_context to find it.]"`,
    /// setting tokens to the estimate of the new content; stop as soon as the total fits.
    /// Phase 2, oldest first: drop whole groups until the total fits. A group is an assistant message with tool
    /// calls plus the `.tool` messages that follow it, or any other single message. A group is skipped if any
    /// of its messages is `.system`, protected, or the first user-role message.
    /// If it still does not fit, return what is left.
    static func emergencyTruncate(
        _ items: [RenderItem],
        windowSize: Int,
        protected: Set<MessageRef>,
        configuration: ContextConfiguration
    ) -> [RenderItem] {
        let limit = Int(Double(windowSize) * configuration.emergencyThreshold)
        func total(_ items: [RenderItem]) -> Int {
            items.reduce(0) { $0 + $1.tokens }
        }
        guard total(items) > limit else { return items }

        var result = items
        for index in result.indices {
            if total(result) <= limit { return result }
            guard case let .message(stored) = result[index], !protected.contains(stored.ref),
                  case let .tool(id, name, _) = stored.message, stored.tokens > 64 else { continue }
            let text = "[Output truncated to fit the context window: \(stored.tokens) tokens. "
                + "Original kept as \(stored.ref); use search_context to find it.]"
            let message = ChatMessage.tool(id: id, name: name, content: text)
            result[index] = .message(StoredMessage(
                ref: stored.ref,
                message: message,
                tokens: ContextTokens.estimate(text)
            ))
        }
        if total(result) <= limit { return result }

        let firstUser = result.firstIndex { item in
            guard case let .message(stored) = item else { return false }
            return isUserRole(stored.message)
        }
        func droppable(_ index: Int) -> Bool {
            guard case let .message(stored) = result[index] else { return false }
            if case .system = stored.message { return false }
            return !protected.contains(stored.ref) && index != firstUser
        }

        var dropped = Set<Int>()
        var used = total(result)
        var start = 0
        while used > limit, start < result.count {
            var end = start + 1
            if case let .message(stored) = result[start], case let .assistant(assistant) = stored.message,
               !assistant.toolCalls.isEmpty {
                while end < result.count, case let .message(next) = result[end], case .tool = next.message {
                    end += 1
                }
            }
            let group = start ..< end
            if group.allSatisfy(droppable) {
                dropped.formUnion(group)
                used -= total(group.map { result[$0] })
            }
            start = end
        }
        return result.indices.filter { !dropped.contains($0) }.map { result[$0] }
    }
}

private func isUserRole(_ message: ChatMessage) -> Bool {
    switch message {
    case .user, .userMultimodal: true
    default: false
    }
}
