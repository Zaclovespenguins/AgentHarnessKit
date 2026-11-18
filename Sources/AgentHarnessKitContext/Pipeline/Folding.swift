import AgentHarnessKit
import Foundation

// TASK H4. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// Every active block: `survivedCount += 1`, then `generation = .old` once `survivedCount >= promotionThreshold`.
    /// Inactive blocks are returned unchanged. Order is preserved.
    static func syncBlocks(_ blocks: [ContextBlock], promotionThreshold: Int) -> [ContextBlock] {
        blocks.map { block in
            guard block.active else { return block }
            var synced = block
            synced.survivedCount += 1
            if synced.survivedCount >= promotionThreshold {
                synced.generation = .old
            }
            return synced
        }
    }

    /// Replaces folded messages with their active block. Walk messages in order: an uncovered message becomes
    /// `.message`; a message covered by an active block's `effectiveMessageRefs` is omitted, except that at the
    /// block's first effective ref `.summary(block)` is emitted (once). The first user-role message is always
    /// emitted as `.message` even when covered; if it is also its block's first ref, the message comes first,
    /// then the summary.
    static func fold(_ messages: [StoredMessage], blocks: [ContextBlock]) -> [RenderItem] {
        // First active block covering each ref. Overlapping active blocks should not happen; first wins.
        var owners: [MessageRef: ContextBlock] = [:]
        for block in blocks where block.active {
            for ref in block.effectiveMessageRefs where owners[ref] == nil {
                owners[ref] = block
            }
        }
        let pinnedRef = messages.first { isUserRole($0.message) }?.ref

        var items: [RenderItem] = []
        for stored in messages {
            guard let owner = owners[stored.ref] else {
                items.append(.message(stored))
                continue
            }
            if stored.ref == pinnedRef {
                items.append(.message(stored))
            }
            if owner.effectiveMessageRefs.first == stored.ref {
                items.append(.summary(owner))
            }
        }
        return items
    }

    /// Hides consumed `compress` calls. A call (assistant tool call named `compress`) is consumed when at least
    /// one block has `createdByCallID == call.id` and all such blocks are inactive. Remove consumed calls from
    /// their assistant message (keep its ref, tokens and other fields); drop the item if it is then left with no
    /// tool calls and empty content. Drop `.tool` items whose id is a consumed call's id. Summaries untouched.
    static func hideCompressionCalls(_ items: [RenderItem], blocks: [ContextBlock]) -> [RenderItem] {
        let compressIDs = items.flatMap { item -> [String] in
            guard case let .message(stored) = item else { return [] }
            return compressCalls(in: stored.message).map(\.id)
        }
        let consumed = Set(compressIDs.filter { id in
            let created = blocks.filter { $0.createdByCallID == id }
            return !created.isEmpty && created.allSatisfy { !$0.active }
        })

        var result: [RenderItem] = []
        for item in items {
            guard case let .message(stored) = item else {
                result.append(item)
                continue
            }
            switch stored.message {
            case let .assistant(assistant):
                let kept = assistant.toolCalls.filter { !consumed.contains($0.id) }
                guard kept.count != assistant.toolCalls.count else {
                    result.append(item)
                    continue
                }
                if kept.isEmpty, assistant.content.isEmpty {
                    continue
                }
                let rebuilt = AssistantMessage(
                    content: assistant.content,
                    toolCalls: kept,
                    tokenUsage: assistant.tokenUsage,
                    reasoning: assistant.reasoning,
                    reasoningDetails: assistant.reasoningDetails,
                    continuity: assistant.continuity
                )
                result.append(.message(StoredMessage(
                    ref: stored.ref,
                    message: .assistant(rebuilt),
                    tokens: stored.tokens
                )))
            case let .tool(id, _, _):
                if !consumed.contains(id) {
                    result.append(item)
                }
            default:
                result.append(item)
            }
        }
        return result
    }

    private static func isUserRole(_ message: ChatMessage) -> Bool {
        switch message {
        case .user, .userMultimodal: true
        default: false
        }
    }

    private static func compressCalls(in message: ChatMessage) -> [ToolCall] {
        guard case let .assistant(assistant) = message else { return [] }
        return assistant.toolCalls.filter { $0.name == ContextToolName.compress }
    }
}
