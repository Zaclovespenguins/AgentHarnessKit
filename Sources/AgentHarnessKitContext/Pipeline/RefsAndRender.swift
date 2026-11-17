import AgentHarnessKit
import Foundation

// TASK H1. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// Mints refs for messages appended after `existingCount` already-recorded messages: the first new message
    /// gets `MessageRef(existingCount + 1)`, then consecutive. `tokens` is `ContextTokens.estimate(message)`.
    static func assignRefs(_ newMessages: [ChatMessage], existingCount: Int) -> [StoredMessage] {
        newMessages.enumerated().map { index, message in
            StoredMessage(
                ref: MessageRef(existingCount + index + 1),
                message: message,
                tokens: ContextTokens.estimate(message)
            )
        }
    }

    /// Token label used in tags: below 1000 the integer (`"999"`); below 10000 one decimal, truncated, then `K`
    /// (`1234 -> "1.2K"`, `9999 -> "9.9K"`, `1000 -> "1.0K"`); otherwise whole thousands, truncated (`12345 -> "12K"`).
    static func tokenLabel(_ tokens: Int) -> String {
        if tokens < 1000 { return String(tokens) }
        if tokens < 10000 { return "\(tokens / 1000).\(tokens % 1000 / 100)K" }
        return "\(tokens / 1000)K"
    }

    /// `<acp tokens="LABEL" type="TYPE">mNNNNN</acp>` for user, multimodal user (type `text`) and tool messages
    /// (type = the tool name). nil for system and assistant messages, which are never tagged.
    static func tag(for stored: StoredMessage) -> String? {
        let type: String
        switch stored.message {
        case .system, .assistant:
            return nil
        case .user, .userMultimodal:
            type = "text"
        case let .tool(_, name, _):
            type = name
        }
        return "<acp tokens=\"\(tokenLabel(stored.tokens))\" type=\"\(type)\">\(stored.ref.description)</acp>"
    }

    /// Turns pipeline items into the messages sent to the model.
    /// - `.message`: system and assistant unchanged. `.user(text)` -> `.user(tag + "\n" + text)`.
    ///   `.userMultimodal(parts)` -> `.userMultimodal([.text(tag)] + parts)`.
    ///   `.tool(id, name, content)` -> `.tool(id: id, name: name, content: tag + "\n" + content)`.
    /// - `.summary(block)` -> `.user(header + "\n" + body)` where header is
    ///   `[Compressed conversation section bN: mFIRST–mLAST]` (en dash U+2013; first/last of
    ///   `effectiveMessageRefs`), and body is `"Topic: <topic>\n<summary>"`, or just `<summary>` when topic is empty.
    static func render(_ items: [RenderItem]) -> [ChatMessage] {
        items.map { item -> ChatMessage in
            switch item {
            case let .summary(block):
                let first = block.effectiveMessageRefs.first?.description ?? ""
                let last = block.effectiveMessageRefs.last?.description ?? ""
                let header = "[Compressed conversation section \(block.id.rawValue): \(first)\u{2013}\(last)]"
                let body = block.topic.isEmpty ? block.summary : "Topic: \(block.topic)\n\(block.summary)"
                return .user(header + "\n" + body)
            case let .message(stored):
                switch stored.message {
                case let .user(text):
                    return .user((tag(for: stored) ?? "") + "\n" + text)
                case let .userMultimodal(parts):
                    return .userMultimodal([.text(tag(for: stored) ?? "")] + parts)
                case let .tool(id, name, content):
                    return .tool(id: id, name: name, content: (tag(for: stored) ?? "") + "\n" + content)
                case .system, .assistant:
                    return stored.message
                }
            }
        }
    }
}
