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
    /// Content of the synthetic `.tool` result given to a tool call that was cancelled before it returned.
    package static let cancelledToolResultContent = "Cancelled by user before this tool returned."

    private let lock = NSLock()

    /// Messages that are complete: base history, committed assistant messages, and their tool results.
    private var committedMessages: [ChatMessage] = []
    /// Assistant text received for the in-flight response that has not been committed yet.
    private var uncommittedText = ""

    package init() {}

    /// Starts a turn. `baseHistory` is the history as of the start of the turn: system, prior history, and the user message.
    package func begin(baseHistory: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages = baseHistory
        uncommittedText = ""
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
    }

    /// Records a tool result as it is appended to the loop's messages.
    package func appendToolResult(id: String, name: String, result: ToolResult) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages.append(.tool(id: id, name: name, content: result.content))
    }

    /// Replaces the recorded state with the loop's validated messages at the end of an iteration.
    package func markIterationComplete(messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        committedMessages = messages
        uncommittedText = ""
    }

    /// The history of the turn so far, sealed so that it passes `validateForLLMRequest()`.
    ///
    /// Non-mutating: the stored state is left as it is, so calling this more than once returns the same result
    /// and the synthetic results never reach the committed messages.
    ///
    /// - Empty assistant messages (no content, no tool calls, no reasoning) are dropped. This includes the empty
    ///   `.response` that `.stop` leaves behind.
    /// - Tool calls of the most recent assistant message that have no `.tool` result get a synthetic result,
    ///   `cancelledToolResultContent`, in call order, placed directly after that assistant's existing results.
    /// - Uncommitted text is appended as an assistant message with no tool calls, after any synthetic results.
    package func snapshot() -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }

        var result = committedMessages.filter { !Self.isEmptyAssistant($0) }

        if let assistantIndex = result.lastIndex(where: Self.isAssistant) {
            var insertionIndex = assistantIndex + 1
            var answeredIDs: Set<String> = []
            while insertionIndex < result.count, case let .tool(id, _, _) = result[insertionIndex] {
                answeredIDs.insert(id)
                insertionIndex += 1
            }
            let syntheticResults = result[assistantIndex].toolCalls
                .filter { !answeredIDs.contains($0.id) }
                .map { call -> ChatMessage in
                    .tool(id: call.id, name: call.name, content: Self.cancelledToolResultContent)
                }
            result.insert(contentsOf: syntheticResults, at: insertionIndex)
        }

        if !uncommittedText.isEmpty {
            result.append(.assistant(AssistantMessage(content: uncommittedText)))
        }
        return result
    }

    private static func isAssistant(_ message: ChatMessage) -> Bool {
        guard case .assistant = message else { return false }
        return true
    }

    /// Same emptiness rule as the terminal-finish sanitizer in `ChatMessageHistory.swift`.
    private static func isEmptyAssistant(_ message: ChatMessage) -> Bool {
        guard case let .assistant(assistant) = message else { return false }
        return assistant.content.isEmpty
            && assistant.toolCalls.isEmpty
            && assistant.reasoning == nil
            && (assistant.reasoningDetails?.isEmpty ?? true)
    }
}
