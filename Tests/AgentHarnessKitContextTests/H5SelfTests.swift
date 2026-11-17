import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

@Suite struct H5SelfTests {
    let config = ContextConfiguration()

    @Test func nudgeNeedsFloorAndGrowth() {
        #expect(!ContextPipeline.shouldNudge(usedTokens: 44, windowSize: 100, baseline: nil, configuration: config))
        #expect(ContextPipeline.shouldNudge(usedTokens: 45, windowSize: 100, baseline: nil, configuration: config))
        #expect(!ContextPipeline.shouldNudge(usedTokens: 50_000, windowSize: 100_000, baseline: 40_000, configuration: config))
        #expect(ContextPipeline.shouldNudge(usedTokens: 60_000, windowSize: 100_000, baseline: 40_000, configuration: config))
    }

    @Test func nudgeMessageListsRanges() {
        let messages = stored([.user("a"), .user("b"), .user("c")], tokens: [3, 5, 7])
        let message = ContextPipeline.nudgeMessage(
            ranges: [ref(1) ... ref(2)], messages: messages, configuration: config
        )
        let expected = config.nudgeText + "\n\nCompressible ranges (1, oldest first):\nm00001\u{2013}m00002  2 msgs  8 tokens"
        #expect(message == .user(expected))
    }

    @Test func nudgeMessageWithoutRanges() {
        let message = ContextPipeline.nudgeMessage(ranges: [], messages: [], configuration: config)
        #expect(message == .user(config.nudgeText + "\n\nNo compressible ranges right now."))
    }

    @Test func truncatesLargeToolOutputFirst() {
        let messages = stored([.user("u"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "x")],
                              tokens: [10, 10, 100])
        let items = messages.map(RenderItem.message)
        let result = ContextPipeline.emergencyTruncate(items, windowSize: 100, protected: [], configuration: config)
        #expect(result.count == 3)
        guard case let .message(stored) = result[2], case let .tool(_, _, content) = stored.message else {
            Issue.record("expected tool message")
            return
        }
        #expect(content.hasPrefix("[Output truncated to fit the context window: 100 tokens. Original kept as m00003"))
        #expect(stored.tokens == ContextTokens.estimate(content))
        #expect(stored.ref == ref(3))
    }

    @Test func dropsWholeToolGroupsAndKeepsFirstUser() {
        let messages = stored([
            .user("first"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: ""),
            .user("second"), .assistant(AssistantMessage(content: "reply")),
        ], tokens: [10, 10, 10, 10, 10])
        let items = messages.map(RenderItem.message)
        let result = ContextPipeline.emergencyTruncate(items, windowSize: 30, protected: [], configuration: config)
        // Limit is 28: dropping the tool group (20 tokens) and the second user message (10) leaves 20 <= 28.
        #expect(result == [items[0], items[4]])
    }
}
