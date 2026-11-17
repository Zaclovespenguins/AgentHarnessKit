import AgentHarnessKit
import Foundation

// TASK H4. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// Every active block: `survivedCount += 1`, then `generation = .old` once `survivedCount >= promotionThreshold`.
    /// Inactive blocks are returned unchanged. Order is preserved.
    static func syncBlocks(_ blocks: [ContextBlock], promotionThreshold: Int) -> [ContextBlock] {
        blocks
    }

    /// Replaces folded messages with their active block. Walk messages in order: an uncovered message becomes
    /// `.message`; a message covered by an active block's `effectiveMessageRefs` is omitted, except that at the
    /// block's first effective ref `.summary(block)` is emitted (once). The first user-role message is always
    /// emitted as `.message` even when covered; if it is also its block's first ref, the message comes first,
    /// then the summary.
    static func fold(_ messages: [StoredMessage], blocks: [ContextBlock]) -> [RenderItem] {
        []
    }

    /// Hides consumed `compress` calls. A call (assistant tool call named `compress`) is consumed when at least
    /// one block has `createdByCallID == call.id` and all such blocks are inactive. Remove consumed calls from
    /// their assistant message (keep its ref, tokens and other fields); drop the item if it is then left with no
    /// tool calls and empty content. Drop `.tool` items whose id is a consumed call's id. Summaries untouched.
    static func hideCompressionCalls(_ items: [RenderItem], blocks: [ContextBlock]) -> [RenderItem] {
        items
    }
}
