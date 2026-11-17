import AgentHarnessKit
import Foundation

// TASK H1. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// Mints refs for messages appended after `existingCount` already-recorded messages: the first new message
    /// gets `MessageRef(existingCount + 1)`, then consecutive. `tokens` is `ContextTokens.estimate(message)`.
    static func assignRefs(_ newMessages: [ChatMessage], existingCount: Int) -> [StoredMessage] {
        []
    }

    /// Token label used in tags: below 1000 the integer (`"999"`); below 10000 one decimal, truncated, then `K`
    /// (`1234 -> "1.2K"`, `9999 -> "9.9K"`, `1000 -> "1.0K"`); otherwise whole thousands, truncated (`12345 -> "12K"`).
    static func tokenLabel(_ tokens: Int) -> String {
        ""
    }

    /// `<acp tokens="LABEL" type="TYPE">mNNNNN</acp>` for user, multimodal user (type `text`) and tool messages
    /// (type = the tool name). nil for system and assistant messages, which are never tagged.
    static func tag(for stored: StoredMessage) -> String? {
        nil
    }

    /// Turns pipeline items into the messages sent to the model.
    /// - `.message`: system and assistant unchanged. `.user(text)` -> `.user(tag + "\n" + text)`.
    ///   `.userMultimodal(parts)` -> `.userMultimodal([.text(tag)] + parts)`.
    ///   `.tool(id, name, content)` -> `.tool(id: id, name: name, content: tag + "\n" + content)`.
    /// - `.summary(block)` -> `.user(header + "\n" + body)` where header is
    ///   `[Compressed conversation section bN: mFIRST–mLAST]` (en dash U+2013; first/last of
    ///   `effectiveMessageRefs`), and body is `"Topic: <topic>\n<summary>"`, or just `<summary>` when topic is empty.
    static func render(_ items: [RenderItem]) -> [ChatMessage] {
        []
    }
}
