import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct FoldingTests {
    @Test func syncAgesActiveBlocksAndPromotes() {
        var almostOld = block(0, covering: refs(1 ... 2))
        almostOld.survivedCount = 4
        let archived = block(1, covering: refs(3 ... 4), active: false)
        let fresh = block(2, covering: refs(5 ... 6))
        let synced = ContextPipeline.syncBlocks([almostOld, archived, fresh], promotionThreshold: 5)
        #expect(synced.map(\.survivedCount) == [5, 0, 1])
        #expect(synced.map(\.generation) == [.old, .young, .young])
        #expect(synced[1] == archived)
    }

    private let messages = stored([
        .system("sys"), .user("first"), .assistant(AssistantMessage(content: "a3")), .user("u4"),
        .assistant(AssistantMessage(content: "a5")), .user("u6"), .assistant(AssistantMessage(content: "a7")),
    ])

    @Test func activeBlocksReplaceTheirMessages() {
        let active = block(0, covering: refs(3 ... 5))
        let archived = block(1, covering: refs(6 ... 7), active: false)
        #expect(ContextPipeline.fold(messages, blocks: [active, archived]) == [
            .message(messages[0]), .message(messages[1]), .summary(active),
            .message(messages[5]), .message(messages[6]),
        ])
    }

    @Test func tierTwoBlockWithGapIsEmittedOnce() {
        let tierTwo = block(2, tier: 2, covering: [ref(3), ref(4), ref(6)], sources: [0, 1])
        #expect(ContextPipeline.fold(messages, blocks: [tierTwo]) == [
            .message(messages[0]), .message(messages[1]), .summary(tierTwo),
            .message(messages[4]), .message(messages[6]),
        ])
    }

    @Test func firstUserMessageStaysPinnedBeforeItsSummary() {
        let covering = block(0, covering: refs(2 ... 4))
        #expect(ContextPipeline.fold(messages, blocks: [covering]) == [
            .message(messages[0]), .message(messages[1]), .summary(covering),
            .message(messages[4]), .message(messages[5]), .message(messages[6]),
        ])
    }

    @Test func firstUserMessageStaysPinnedInsideABlock() {
        let late = stored([.system("s"), .assistant(AssistantMessage(content: "hi")), .user("first"), .user("u4")])
        let covering = block(0, covering: refs(2 ... 3))
        #expect(ContextPipeline.fold(late, blocks: [covering]) == [
            .message(late[0]), .summary(covering), .message(late[2]), .message(late[3]),
        ])
    }

    private let calls = stored([
        .user("first"),
        assistantCalling(call("kA", "compress")),
        .tool(id: "kA", name: "compress", content: "ok"),
        .assistant(AssistantMessage(content: "x", toolCalls: [call("kB", "compress"), call("c3")])),
        .tool(id: "kB", name: "compress", content: "ok"),
        .tool(id: "c3", name: "bash", content: "out"),
        assistantCalling(call("kC", "compress")),
        .tool(id: "kC", name: "compress", content: "ok"),
    ], tokens: [1, 2, 3, 4, 5, 6, 7, 8])

    @Test func hidesCallsWhoseBlocksAreAllInactive() {
        let blocks = [
            block(0, covering: refs(10 ... 11), active: false, callID: "kA"),
            block(1, covering: refs(12 ... 13), active: false, callID: "kB"),
            block(2, covering: refs(14 ... 15), active: false, callID: "kB"),
            block(3, covering: refs(16 ... 17), callID: "kC"),
        ]
        let summary = block(9, covering: refs(20 ... 21))
        let items = calls.map(RenderItem.message) + [.summary(summary)]
        let trimmed = StoredMessage(
            ref: ref(4), message: .assistant(AssistantMessage(content: "x", toolCalls: [call("c3")])), tokens: 4
        )
        #expect(ContextPipeline.hideCompressionCalls(items, blocks: blocks) == [
            .message(calls[0]), .message(trimmed), .message(calls[5]),
            .message(calls[6]), .message(calls[7]), .summary(summary),
        ])
    }

    @Test func keepsCallsWithAnActiveOrMissingBlock() {
        let blocks = [
            block(1, covering: refs(12 ... 13), active: false, callID: "kB"),
            block(2, covering: refs(14 ... 15), callID: "kB"),
        ]
        let items = calls.map(RenderItem.message)
        #expect(ContextPipeline.hideCompressionCalls(items, blocks: blocks) == items)
    }
}
