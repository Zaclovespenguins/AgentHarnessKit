import AgentHarnessKit
import Foundation

public extension ContextPipeline {
    /// Refs the model may not compress. Union of:
    /// 1. every `.system` message;
    /// 2. the first and the last user-role message (`.user` or `.userMultimodal`);
    /// 3. the recent zone: the last `k` messages, where `k` is the larger of
    ///    `configuration.protectedRecentMessages` and the smallest suffix length whose token sum is
    ///    >= `configuration.protectedRecentTokens` (all messages if never reached). If the zone then starts
    ///    with `.tool` messages, extend it backwards to include the assistant message that issued those calls;
    /// 4. every assistant message with a call whose name is in `ContextToolName.all`, and every `.tool`
    ///    message whose name is in `ContextToolName.all`.
    static func protectedRefs(_ messages: [StoredMessage], configuration: ContextConfiguration) -> Set<MessageRef> {
        var protected = Set<MessageRef>()
        for stored in messages {
            switch stored.message {
            case .system:
                protected.insert(stored.ref)
            case let .tool(_, name, _):
                if ContextToolName.all.contains(name) {
                    protected.insert(stored.ref)
                }
            case let .assistant(assistant):
                if assistant.toolCalls.contains(where: { ContextToolName.all.contains($0.name) }) {
                    protected.insert(stored.ref)
                }
            default:
                break
            }
        }

        let userRefs = messages.filter { isUser($0.message) }.map(\.ref)
        if let first = userRefs.first {
            protected.insert(first)
        }
        if let last = userRefs.last {
            protected.insert(last)
        }

        var start = messages.count - recentCount(messages, configuration: configuration)
        while start > 0, start < messages.count, isTool(messages[start].message) {
            start -= 1
        }
        for stored in messages[start...] {
            protected.insert(stored.ref)
        }
        return protected
    }

    /// Maximal runs of consecutive refs that are neither protected nor in the `effectiveMessageRefs` of an
    /// active block, ascending. Each run is then trimmed so it does not start with a `.tool` message and does
    /// not end with an assistant message that has tool calls (repeat until stable); empty runs are dropped.
    static func compressibleRanges(
        _ messages: [StoredMessage],
        blocks: [ContextBlock],
        protected: Set<MessageRef>
    ) -> [ClosedRange<MessageRef>] {
        let covered = Set(blocks.filter(\.active).flatMap(\.effectiveMessageRefs))

        var runs: [[StoredMessage]] = []
        var current: [StoredMessage] = []
        for stored in messages {
            if protected.contains(stored.ref) || covered.contains(stored.ref) {
                runs.append(current)
                current = []
                continue
            }
            if let last = current.last, last.ref.ordinal + 1 != stored.ref.ordinal {
                runs.append(current)
                current = []
            }
            current.append(stored)
        }
        runs.append(current)

        var ranges: [ClosedRange<MessageRef>] = []
        for run in runs {
            var trimmed = run[...]
            var changed = true
            while changed {
                changed = false
                if let first = trimmed.first, isTool(first.message) {
                    trimmed = trimmed.dropFirst()
                    changed = true
                }
                if let last = trimmed.last, hasToolCalls(last.message) {
                    trimmed = trimmed.dropLast()
                    changed = true
                }
            }
            if let first = trimmed.first, let last = trimmed.last {
                ranges.append(first.ref ... last.ref)
            }
        }
        return ranges
    }
}

/// Number of trailing messages in the recent zone (before the tool-result extension).
private func recentCount(_ messages: [StoredMessage], configuration: ContextConfiguration) -> Int {
    // Smallest suffix length whose token sum reaches the threshold; all messages if never reached.
    var tokenCount = messages.count
    var sum = 0
    for length in 0 ... messages.count {
        if sum >= configuration.protectedRecentTokens {
            tokenCount = length
            break
        }
        if length < messages.count {
            sum += messages[messages.count - 1 - length].tokens
        }
    }
    return min(max(configuration.protectedRecentMessages, tokenCount), messages.count)
}

private func isUser(_ message: ChatMessage) -> Bool {
    switch message {
    case .user, .userMultimodal: true
    default: false
    }
}

private func isTool(_ message: ChatMessage) -> Bool {
    if case .tool = message {
        return true
    }
    return false
}

private func hasToolCalls(_ message: ChatMessage) -> Bool {
    if case let .assistant(assistant) = message {
        return !assistant.toolCalls.isEmpty
    }
    return false
}
