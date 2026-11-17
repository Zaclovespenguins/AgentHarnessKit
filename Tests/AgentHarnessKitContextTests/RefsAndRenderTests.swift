import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct RefsAndRenderTests {
    @Test func refFormatAndParsing() {
        #expect(MessageRef(42).description == "m00042")
        #expect(MessageRef(123_456).description == "m123456")
        #expect(MessageRef("m00042") == MessageRef(42))
        #expect(MessageRef("x1") == nil)
        #expect(MessageRef("m0") == nil)
    }

    @Test func assignRefsContinuesAfterExistingAndIsStable() {
        let messages: [ChatMessage] = [.user("hello world"), .tool(id: "c1", name: "bash", content: "12345678")]
        let first = ContextPipeline.assignRefs(messages, existingCount: 7)
        #expect(first.map(\.ref) == [ref(8), ref(9)])
        #expect(first.map(\.message) == messages)
        #expect(first.map(\.tokens) == messages.map(ContextTokens.estimate))
        #expect(ContextPipeline.assignRefs(messages, existingCount: 7) == first)
        #expect(ContextPipeline.assignRefs([], existingCount: 3).isEmpty)
    }

    @Test(arguments: [
        (0, "0"), (999, "999"), (1000, "1.0K"), (1234, "1.2K"), (1299, "1.2K"), (9999, "9.9K"),
        (10000, "10K"), (12345, "12K"), (999_999, "999K"),
    ])
    func tokenLabel(tokens: Int, expected: String) {
        #expect(ContextPipeline.tokenLabel(tokens) == expected)
    }

    @Test func tagsOnlyUserAndToolMessages() {
        let user = StoredMessage(ref: ref(3), message: .user("hi"), tokens: 1234)
        let multimodal = StoredMessage(ref: ref(4), message: .userMultimodal([.text("a")]), tokens: 5)
        let tool = StoredMessage(ref: ref(5), message: .tool(id: "c", name: "bash", content: "x"), tokens: 20000)
        #expect(ContextPipeline.tag(for: user) == #"<acp tokens="1.2K" type="text">m00003</acp>"#)
        #expect(ContextPipeline.tag(for: multimodal) == #"<acp tokens="5" type="text">m00004</acp>"#)
        #expect(ContextPipeline.tag(for: tool) == #"<acp tokens="20K" type="bash">m00005</acp>"#)
        #expect(ContextPipeline.tag(for: StoredMessage(ref: ref(1), message: .system("s"), tokens: 1)) == nil)
        let assistant = StoredMessage(ref: ref(2), message: .assistant(AssistantMessage(content: "a")), tokens: 1)
        #expect(ContextPipeline.tag(for: assistant) == nil)
    }

    @Test func renderMessages() {
        let assistant = ChatMessage.assistant(AssistantMessage(content: "ok", toolCalls: [call("c1")]))
        let items: [RenderItem] = [
            .message(StoredMessage(ref: ref(1), message: .system("sys"), tokens: 1)),
            .message(StoredMessage(ref: ref(2), message: .user("do it"), tokens: 2)),
            .message(StoredMessage(ref: ref(3), message: assistant, tokens: 3)),
            .message(StoredMessage(ref: ref(4), message: .tool(id: "c1", name: "bash", content: "out"), tokens: 4)),
            .message(StoredMessage(ref: ref(5), message: .userMultimodal([.imageURL("u")]), tokens: 256)),
        ]
        #expect(ContextPipeline.render(items) == [
            .system("sys"),
            .user("<acp tokens=\"2\" type=\"text\">m00002</acp>\ndo it"),
            assistant,
            .tool(id: "c1", name: "bash", content: "<acp tokens=\"4\" type=\"bash\">m00004</acp>\nout"),
            .userMultimodal([.text("<acp tokens=\"256\" type=\"text\">m00005</acp>"), .imageURL("u")]),
        ])
    }

    @Test func renderSummaryBlocks() {
        let withTopic = block(4, covering: refs(3 ... 9), topic: "setup", summary: "did setup")
        let noTopic = block(5, covering: refs(10 ... 12), summary: "more")
        #expect(ContextPipeline.render([.summary(withTopic), .summary(noTopic)]) == [
            .user("[Compressed conversation section b4: m00003\u{2013}m00009]\nTopic: setup\ndid setup"),
            .user("[Compressed conversation section b5: m00010\u{2013}m00012]\nmore"),
        ])
    }
}
