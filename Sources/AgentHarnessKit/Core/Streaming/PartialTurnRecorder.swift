import Foundation

/// Records the in-flight turn so that `AgentStream` can expose it as valid history after Cancel.
///
/// The streaming loop writes into the recorder as it goes: `begin` with the history at the start of the
/// turn, `appendText` for assistant text deltas, `commitAssistant` once an assistant message is fully
/// drained, `appendToolResult` for each tool result, and `markIterationComplete` with the loop's validated
/// messages. `AgentStream` reads `snapshot()` on cancel. The same pattern as `SaveObservingCheckpointer`.
///
/// All mutable state sits behind an `NSLock`. `Synchronization.Mutex` is not used because the package
/// targets macOS 14 / iOS 17.
package final class PartialTurnRecorder: @unchecked Sendable {
    private let lock = NSLock()

    /// Messages that are complete: base history, committed assistant messages, and their tool results.
    private var committedMessages: [ChatMessage] = []
    /// Assistant text received for the in-flight response that has not been committed yet.
    private var uncommittedText = ""
    /// Tool calls of the most recently committed assistant message, in the order the model issued them.
    private var lastAssistantToolCalls: [ToolCall] = []
    /// Ids of tool calls that already have a `.tool` result in `committedMessages`.
    private var answeredCallIDs: Set<String> = []

    package init() {}

    /// Starts a turn. `baseHistory` is the history as of the start of the turn: system, prior history, and the user message.
    package func begin(baseHistory: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages = baseHistory
        uncommittedText = ""
        lastAssistantToolCalls = []
        answeredCallIDs = []
    }

    /// Appends an assistant text delta for the in-flight response.
    package func appendText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        uncommittedText += text
    }

    /// Commits the fully drained assistant message. Clears the uncommitted text buffer.
    package func commitAssistant(_ message: AssistantMessage) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages.append(.assistant(message))
        uncommittedText = ""
        lastAssistantToolCalls = message.toolCalls
    }

    /// Records a tool result as it is appended to the loop's messages.
    package func appendToolResult(id: String, name: String, result: ToolResult) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages.append(.tool(id: id, name: name, content: result.content))
        answeredCallIDs.insert(id)
    }

    /// Replaces the recorded state with the loop's validated messages at the end of an iteration.
    package func markIterationComplete(messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages = messages
        uncommittedText = ""
        lastAssistantToolCalls = messages.reversed().lazy
            .compactMap { message -> [ToolCall]? in
                guard case let .assistant(assistant) = message else { return nil }
                return assistant.toolCalls
            }
            .first ?? []
        answeredCallIDs = Set(messages.compactMap { message -> String? in
            guard case let .tool(id, _, _) = message else { return nil }
            return id
        })
    }

    /// The history of the turn so far.
    ///
    /// Placeholder: returns committed messages plus any uncommitted text as an assistant message.
    /// Task 1.2 replaces this with the sealing rules (synthetic results for dangling calls, dropping empty assistants).
    package func snapshot() -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        var result = committedMessages
        if !uncommittedText.isEmpty {
            result.append(.assistant(AssistantMessage(content: uncommittedText)))
        }
        return result
    }
}
