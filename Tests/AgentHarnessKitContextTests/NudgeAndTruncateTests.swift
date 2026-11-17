import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct NudgeAndTruncateTests {
    @Test(arguments: [
        (44999, nil, false), (45000, nil, true), (60000, 45000, false), (65000, 45000, true), (90000, 80000, false),
    ] as [(Int, Int?, Bool)])
    func nudgeNeedsFloorAndGrowth(used: Int, baseline: Int?, expected: Bool) {
        let result = ContextPipeline.shouldNudge(
            usedTokens: used, windowSize: 100_000, baseline: baseline, configuration: ContextConfiguration()
        )
        #expect(result == expected)
    }

    @Test func nudgeThresholdsAreConfigurable() {
        let config = ContextConfiguration(nudgeFloor: 0.5, nudgeGrowthTokens: 10)
        #expect(!ContextPipeline.shouldNudge(usedTokens: 49, windowSize: 100, baseline: nil, configuration: config))
        #expect(ContextPipeline.shouldNudge(usedTokens: 60, windowSize: 100, baseline: 50, configuration: config))
        #expect(!ContextPipeline.shouldNudge(usedTokens: 59, windowSize: 100, baseline: 50, configuration: config))
    }

    @Test func nudgeListsRanges() {
        let messages = stored(Array(repeating: .user("x"), count: 7), tokens: [10, 10, 100, 200, 10, 10, 50])
        let config = ContextConfiguration(nudgeText: "NUDGE")
        let nudge = ContextPipeline.nudgeMessage(
            ranges: [ref(3) ... ref(4), ref(7) ... ref(7)], messages: messages, configuration: config
        )
        #expect(nudge == .user("""
        NUDGE

        Compressible ranges (2, oldest first):
        m00003\u{2013}m00004  2 msgs  300 tokens
        m00007\u{2013}m00007  1 msgs  50 tokens
        """))
        #expect(ContextPipeline.nudgeMessage(ranges: [], messages: messages, configuration: config) ==
            .user("NUDGE\n\nNo compressible ranges right now."))
    }

    private func truncate(_ items: [RenderItem], protected: [Int]) -> [RenderItem] {
        ContextPipeline.emergencyTruncate(
            items, windowSize: 1000, protected: Set(protected.map(ref)), configuration: ContextConfiguration()
        )
    }

    private func total(_ items: [RenderItem]) -> Int {
        items.reduce(0) { $0 + $1.tokens }
    }

    /// 1 system, 2 first user, 3 asst->c1, 4 tool c1, 5 asst->c2, 6 tool c2, 7 user, 8 asst.
    private func toolHeavy(_ tokens: [Int]) -> [StoredMessage] {
        stored([
            .system("s"), .user("first"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "big"),
            assistantCalling(call("c2")), .tool(id: "c2", name: "bash", content: "big2"), .user("u7"),
            .assistant(AssistantMessage(content: "a8")),
        ], tokens: tokens)
    }

    @Test func underBudgetIsUnchanged() {
        let items = toolHeavy([10, 10, 10, 500, 10, 400, 0, 0]).map(RenderItem.message)
        #expect(truncate(items, protected: [7, 8]) == items)
    }

    @Test func truncatesOldestToolOutputFirstAndStops() {
        let messages = toolHeavy([10, 10, 10, 600, 10, 400, 10, 10])
        let result = truncate(messages.map(RenderItem.message), protected: [7, 8])
        let placeholder = "[Output truncated to fit the context window: 600 tokens. Original kept as m00004; "
            + "use search_context to find it.]"
        var expected = messages.map(RenderItem.message)
        expected[3] = .message(StoredMessage(
            ref: ref(4), message: .tool(id: "c1", name: "bash", content: placeholder),
            tokens: ContextTokens.estimate(placeholder)
        ))
        #expect(result == expected)
        #expect(total(result) <= 950)
    }

    @Test func protectedToolOutputIsNotTruncated() {
        let messages = toolHeavy([10, 10, 10, 600, 10, 400, 10, 10])
        let result = truncate(messages.map(RenderItem.message), protected: [4, 7, 8])
        #expect(result[3] == .message(messages[3]))
        #expect(result[5] != .message(messages[5]))
        #expect(total(result) <= 950)
    }

    @Test func dropsWholeGroupsOldestFirst() {
        let messages = stored([
            .system("s"), .user("first"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "x"),
            .user("u5"), .assistant(AssistantMessage(content: "a6")), .user("u7"),
            .assistant(AssistantMessage(content: "a8")),
        ], tokens: [10, 300, 10, 50, 500, 200, 10, 10])
        let result = truncate(messages.map(RenderItem.message), protected: [7, 8])
        #expect(result == [0, 1, 5, 6, 7].map { .message(messages[$0]) })
    }

    @Test func groupWithAProtectedMemberIsKept() {
        let messages = stored([
            .system("s"), .user("first"), assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "x"),
            .user("u5"), .assistant(AssistantMessage(content: "a6")),
        ], tokens: [10, 10, 600, 60, 500, 10])
        let result = truncate(messages.map(RenderItem.message), protected: [4, 6])
        #expect(result == [0, 1, 2, 3, 5].map { .message(messages[$0]) })
    }

    @Test func summariesAndPinnedMessagesSurviveEvenOverBudget() {
        let messages = stored([.system("s"), .user("first"), .user("recent")], tokens: [10, 10, 10])
        let huge = block(0, covering: refs(4 ... 5), summary: String(repeating: "z", count: 4000))
        let items: [RenderItem] = [.message(messages[0]), .summary(huge), .message(messages[1]), .message(messages[2])]
        #expect(truncate(items, protected: [3]) == items)
    }
}
