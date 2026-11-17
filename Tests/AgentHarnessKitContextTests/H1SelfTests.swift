import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct H1SelfTests {
    @Test func tokenLabelTruncates() {
        #expect(ContextPipeline.tokenLabel(999) == "999")
        #expect(ContextPipeline.tokenLabel(1000) == "1.0K")
        #expect(ContextPipeline.tokenLabel(1234) == "1.2K")
        #expect(ContextPipeline.tokenLabel(9999) == "9.9K")
        #expect(ContextPipeline.tokenLabel(12345) == "12K")
    }

    @Test func assignRefsContinuesAfterExisting() {
        let minted = ContextPipeline.assignRefs([.user("hi"), .user("there")], existingCount: 41)
        #expect(minted.map(\.ref) == [MessageRef(42), MessageRef(43)])
        #expect(minted.map(\.tokens) == [1, 2])
    }

    @Test func tagsUserAndToolOnly() throws {
        let system = try #require(stored([.system("s")]).first)
        let assistant = try #require(stored([.assistant(AssistantMessage(content: "x", toolCalls: []))]).first)
        #expect(ContextPipeline.tag(for: system) == nil)
        #expect(ContextPipeline.tag(for: assistant) == nil)

        let user = try #require(stored([.user("hi")], tokens: [1234]).first)
        #expect(ContextPipeline.tag(for: user) == "<acp tokens=\"1.2K\" type=\"text\">m00001</acp>")

        let tool = try #require(stored([.tool(id: "1", name: "bash", content: "out")], tokens: [7]).first)
        #expect(ContextPipeline.tag(for: tool) == "<acp tokens=\"7\" type=\"bash\">m00001</acp>")
    }

    @Test func renderTagsAndSummarizes() throws {
        let user = try #require(stored([.user("hi")], tokens: [1234]).first)
        let rendered = ContextPipeline.render([.message(user)])
        #expect(rendered == [.user("<acp tokens=\"1.2K\" type=\"text\">m00001</acp>\nhi")])

        let summary = block(1, covering: refs(2 ... 4), topic: "", summary: "sum")
        #expect(ContextPipeline
            .render([.summary(summary)]) == [.user("[Compressed conversation section b1: m00002\u{2013}m00004]\nsum")])

        let topical = block(2, covering: refs(5 ... 6), topic: "Build", summary: "sum")
        #expect(ContextPipeline
            .render([.summary(topical)]) ==
            [.user("[Compressed conversation section b2: m00005\u{2013}m00006]\nTopic: Build\nsum")])
    }
}
