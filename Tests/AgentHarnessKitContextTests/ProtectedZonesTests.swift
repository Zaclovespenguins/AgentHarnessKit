import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct ProtectedZonesTests {
    private func config(messages: Int, tokens: Int) -> ContextConfiguration {
        ContextConfiguration(protectedRecentMessages: messages, protectedRecentTokens: tokens)
    }

    private let alternating: [ChatMessage] = [
        .system("sys"), .user("first"), .assistant(AssistantMessage(content: "a3")), .user("u4"),
        .assistant(AssistantMessage(content: "a5")), .user("u6"), .assistant(AssistantMessage(content: "a7")),
        .user("last"), .assistant(AssistantMessage(content: "a9")),
    ]

    @Test func systemFirstLastUserAndMessageCountZone() {
        let result = ContextPipeline.protectedRefs(stored(alternating), configuration: config(messages: 2, tokens: 15))
        #expect(result == Set([1, 2, 8, 9].map(ref)))
    }

    @Test func tokenZoneWinsWhenLarger() {
        let result = ContextPipeline.protectedRefs(stored(alternating), configuration: config(messages: 1, tokens: 25))
        #expect(result == Set([1, 2, 7, 8, 9].map(ref)))
    }

    @Test func messageCountZoneWinsWhenLarger() {
        let result = ContextPipeline.protectedRefs(stored(alternating), configuration: config(messages: 4, tokens: 1))
        #expect(result == Set([1, 2, 6, 7, 8, 9].map(ref)))
    }

    @Test func tokenZoneNeverReachedProtectsEverything() {
        let messages = stored(alternating)
        let result = ContextPipeline.protectedRefs(messages, configuration: config(messages: 1, tokens: 5000))
        #expect(result == Set(messages.map(\.ref)))
    }

    @Test func zoneStartingAtToolResultsExtendsToIssuingAssistant() {
        let messages = stored([
            .user("task"), .assistant(AssistantMessage(content: "thinking")),
            assistantCalling(call("c1"), call("c2")),
            .tool(id: "c1", name: "bash", content: "one"), .tool(id: "c2", name: "bash", content: "two"),
            .assistant(AssistantMessage(content: "done")),
        ])
        let result = ContextPipeline.protectedRefs(messages, configuration: config(messages: 2, tokens: 1))
        #expect(result == Set([1, 3, 4, 5, 6].map(ref)))
    }

    @Test func contextToolCallsAndResultsAreProtected() {
        let messages = stored([
            .user("first"), assistantCalling(call("k1", "compress")),
            .tool(id: "k1", name: "compress", content: "ok"), .user("u4"),
            assistantCalling(call("k2", "context_status")), .tool(id: "k2", name: "context_status", content: "s"),
            .assistant(AssistantMessage(content: "a7")), .user("last"), .assistant(AssistantMessage(content: "a9")),
        ])
        let result = ContextPipeline.protectedRefs(messages, configuration: config(messages: 1, tokens: 1))
        #expect(result == Set([1, 2, 3, 5, 6, 8, 9].map(ref)))
    }

    @Test func rangesSkipProtectedAndActivelyFoldedMessages() {
        let messages = stored([
            .system("s"), .user("first"), .assistant(AssistantMessage(content: "a3")), .user("u4"),
            assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "x"), .user("u7"),
            .assistant(AssistantMessage(content: "a8")), .user("u9"), assistantCalling(call("c2")),
            .tool(id: "c2", name: "bash", content: "y"), .user("u12"), .assistant(AssistantMessage(content: "a13")),
            .user("last"), .assistant(AssistantMessage(content: "a15")),
        ])
        let blocks = [block(0, covering: refs(7 ... 8)), block(1, covering: refs(3 ... 4), active: false)]
        let ranges = ContextPipeline.compressibleRanges(messages, blocks: blocks, protected: Set([1, 2, 14, 15].map(ref)))
        #expect(ranges == [ref(3) ... ref(6), ref(9) ... ref(13)])
    }

    @Test func rangesAreTrimmedAtToolPairEdges() {
        let messages = stored([
            .user("first"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "x"),
            assistantCalling(call("c2")), .tool(id: "c2", name: "bash", content: "y"), .user("last"),
        ])
        let endTrimmed = ContextPipeline.compressibleRanges(messages, blocks: [], protected: Set([1, 5, 6].map(ref)))
        #expect(endTrimmed == [ref(2) ... ref(3)])
        let startTrimmed = ContextPipeline.compressibleRanges(messages, blocks: [], protected: Set([1, 2, 6].map(ref)))
        #expect(startTrimmed == [ref(4) ... ref(5)])
        let gone = ContextPipeline.compressibleRanges(messages, blocks: [], protected: Set([1, 2, 5, 6].map(ref)))
        #expect(gone.isEmpty)
    }
}
