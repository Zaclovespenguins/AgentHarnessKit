import AgentHarnessKit
import Foundation

// TASK H5. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// True when `Double(usedTokens) >= nudgeFloor * Double(windowSize)` and either `baseline` is nil or
    /// `usedTokens - baseline >= nudgeGrowthTokens`.
    static func shouldNudge(
        usedTokens: Int,
        windowSize: Int,
        baseline: Int?,
        configuration: ContextConfiguration
    ) -> Bool {
        false
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
        .user("")
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
        items
    }
}
