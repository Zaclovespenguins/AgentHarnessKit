import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct H2SelfTests {
    private func config(recentMessages: Int, recentTokens: Int) -> ContextConfiguration {
        ContextConfiguration(protectedRecentMessages: recentMessages, protectedRecentTokens: recentTokens)
    }

    @Test func systemAndFirstLastUserAreProtected() {
        let messages = stored([
            .system("sys"), .user("a"), .assistant(AssistantMessage(content: "x")),
            .user("b"), .assistant(AssistantMessage(content: "y")), .assistant(AssistantMessage(content: "z")),
        ])
        let protected = ContextPipeline.protectedRefs(messages, configuration: config(recentMessages: 0, recentTokens: 0))
        #expect(protected == Set([ref(1), ref(2), ref(4)]))
    }

    @Test func recentZoneUsesCountWhenLarger() {
        let messages = stored([.user("a"), .assistant(AssistantMessage(content: "x")), .user("b"),
                               .assistant(AssistantMessage(content: "y")), .user("c")])
        let protected = ContextPipeline.protectedRefs(messages, configuration: config(recentMessages: 2, recentTokens: 0))
        #expect(protected == Set([ref(1), ref(4), ref(5)]))
    }

    @Test func recentZoneUsesTokensWhenLarger() {
        let messages = stored((1 ... 5).map { .user("\($0)") })
        // Smallest suffix with sum >= 25 at 10 tokens each is 3 messages; that beats the count of 1.
        let protected = ContextPipeline.protectedRefs(messages, configuration: config(recentMessages: 1, recentTokens: 25))
        #expect(protected == Set([ref(1), ref(3), ref(4), ref(5)]))
    }

    @Test func recentZoneExtendsBackOverToolResults() {
        let messages = stored([
            .user("a"), assistantCalling(call("a")), .tool(id: "a", name: "bash", content: ""),
            assistantCalling(call("b")), .tool(id: "b", name: "bash", content: ""),
            .assistant(AssistantMessage(content: "done")), .user("c"),
        ])
        let protected = ContextPipeline.protectedRefs(messages, configuration: config(recentMessages: 3, recentTokens: 0))
        #expect(protected == Set([ref(1), ref(4), ref(5), ref(6), ref(7)]))
    }

    @Test func compressCallsAndResultsAreProtected() {
        let messages = stored([
            .user("a"), assistantCalling(call("c", ContextToolName.compress)),
            .tool(id: "c", name: ContextToolName.compress, content: ""),
            assistantCalling(call("b")), .tool(id: "b", name: "bash", content: ""),
            .assistant(AssistantMessage(content: "x")), .user("z"),
        ])
        let protected = ContextPipeline.protectedRefs(messages, configuration: config(recentMessages: 0, recentTokens: 0))
        #expect(protected == Set([ref(1), ref(2), ref(3), ref(7)]))
    }

    @Test func compressibleRangesSkipProtectedAndCovered() {
        let messages = stored((1 ... 8).map { .user("\($0)") })
        let ranges = ContextPipeline.compressibleRanges(
            messages,
            blocks: [block(1, covering: [ref(4), ref(5)])],
            protected: [ref(1), ref(8)]
        )
        #expect(ranges == [ref(2) ... ref(3), ref(6) ... ref(7)])
    }

    @Test func compressibleRangesTrimToolEdges() {
        let messages = stored([
            .user("a"), .tool(id: "x", name: "bash", content: ""), assistantCalling(call("y")),
            .tool(id: "y", name: "bash", content: ""), assistantCalling(call("z")), .user("b"),
        ])
        let ranges = ContextPipeline.compressibleRanges(messages, blocks: [], protected: [ref(1), ref(6)])
        #expect(ranges == [ref(3) ... ref(4)])
    }
}
