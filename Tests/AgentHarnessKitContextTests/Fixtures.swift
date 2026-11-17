import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

/// Builds StoredMessages with refs m00001... and explicit token counts (default 10).
func stored(_ messages: [ChatMessage], tokens: [Int]? = nil) -> [StoredMessage] {
    messages.enumerated().map { index, message in
        StoredMessage(ref: MessageRef(index + 1), message: message, tokens: tokens?[index] ?? 10)
    }
}

func ref(_ ordinal: Int) -> MessageRef {
    MessageRef(ordinal)
}

func refs(_ range: ClosedRange<Int>) -> [MessageRef] {
    range.map(MessageRef.init)
}

func call(_ id: String, _ name: String = "bash", _ arguments: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}

func assistantCalling(_ calls: ToolCall..., content: String = "") -> ChatMessage {
    .assistant(AssistantMessage(content: content, toolCalls: calls))
}

func block(
    _ ordinal: Int,
    tier: Int = 1,
    covering effective: [MessageRef],
    direct: [MessageRef]? = nil,
    sources: [Int] = [],
    active: Bool = true,
    topic: String = "",
    summary: String = String(repeating: "s", count: 60),
    callID: String? = nil
) -> ContextBlock {
    ContextBlock(
        id: ContextBlockID("b\(ordinal)"),
        tier: tier,
        topic: topic,
        summary: summary,
        directMessageRefs: direct ?? (sources.isEmpty ? effective : []),
        directBlockIDs: sources.map { ContextBlockID("b\($0)") },
        effectiveMessageRefs: effective,
        active: active,
        createdByCallID: callID
    )
}
