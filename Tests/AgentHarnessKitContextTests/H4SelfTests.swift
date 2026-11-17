import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct H4SelfTests {
    @Test func syncPromotesAfterThresholdAndSkipsInactive() {
        let active = block(1, covering: refs(1 ... 2))
        var inactive = block(2, covering: refs(3 ... 4), active: false)
        inactive.survivedCount = 9
        let synced = ContextPipeline.syncBlocks([active, inactive], promotionThreshold: 1)
        #expect(synced[0].survivedCount == 1)
        #expect(synced[0].generation == .old)
        #expect(synced[1] == inactive)
    }

    @Test func foldEmitsSummaryAtFirstRefAndPinsFirstUser() {
        let messages = stored([
            .user("first"), .assistant(AssistantMessage(content: "a")), .user("second"),
            .assistant(AssistantMessage(content: "b")),
        ])
        let items = ContextPipeline.fold(messages, blocks: [block(1, covering: refs(1 ... 3))])
        // m1 is pinned (first user) and first ref: message then summary; m2 omitted; m3 omitted; m4 kept.
        #expect(items.count == 3)
        #expect(items[0] == .message(messages[0]))
        if case let .summary(summary) = items[1] {
            #expect(summary.id.rawValue == "b1")
        } else {
            Issue.record("expected summary")
        }
        #expect(items[2] == .message(messages[3]))
    }

    @Test func foldPinnedFirstUserCoveredNotFirstRefStaysAsMessage() {
        let messages = stored([
            .system("sys"), .user("u"), .assistant(AssistantMessage(content: "a")),
        ])
        let items = ContextPipeline.fold(messages, blocks: [block(1, covering: refs(2 ... 3))])
        #expect(items == [.message(messages[0]), .message(messages[1]), .summary(block(1, covering: refs(2 ... 3)))])
    }

    @Test func hideRemovesConsumedCompressCallOnly() {
        let compress = call("c1", ContextToolName.compress)
        let bash = call("c2", "bash")
        let assistant = AssistantMessage(content: "", toolCalls: [compress, bash], tokenUsage: nil)
        let items: [RenderItem] = [
            .message(StoredMessage(ref: ref(1), message: .assistant(assistant), tokens: 7)),
            .message(StoredMessage(ref: ref(2), message: .tool(id: "c1", name: "compress", content: "ok"), tokens: 3)),
            .message(StoredMessage(
                ref: ref(3),
                message: .assistant(AssistantMessage(content: "", toolCalls: [compress])),
                tokens: 4
            )),
        ]
        let hidden = ContextPipeline.hideCompressionCalls(
            items,
            blocks: [block(1, covering: refs(4 ... 5), active: false, callID: "c1")]
        )
        #expect(hidden.count == 1)
        guard case let .message(kept) = hidden[0], case let .assistant(message) = kept.message else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.toolCalls == [bash])
        #expect(kept.ref == ref(1))
        #expect(kept.tokens == 7)
    }

    @Test func compressCallWithActiveBlockIsNotHidden() {
        let items: [RenderItem] = [
            .message(StoredMessage(
                ref: ref(1),
                message: assistantCalling(call("c1", ContextToolName.compress)),
                tokens: 1
            )),
        ]
        let kept = ContextPipeline.hideCompressionCalls(
            items,
            blocks: [block(1, covering: refs(2 ... 3), callID: "c1")]
        )
        #expect(kept == items)
    }
}
