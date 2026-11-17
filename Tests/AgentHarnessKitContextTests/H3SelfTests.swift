import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct H3SelfTests {
    private let config = ContextConfiguration(minSummaryLength: 5)
    private let summary = "summary text long enough"

    private func plain(_ count: Int) -> [StoredMessage] {
        stored((1 ... count).map { ChatMessage.user("u\($0)") })
    }

    @Test func compressFoldsRangeIntoTierOneBlock() {
        let out = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00001", endRef: "m00003", topic: "t", summary: summary)],
            messages: plain(5), blocks: [], protected: [], nextBlockOrdinal: 0, callID: "c1", configuration: config
        )
        #expect(out.errors.isEmpty)
        #expect(out.created == [ContextBlockID("b0")])
        #expect(out.nextBlockOrdinal == 1)
        let block = out.blocks[0]
        #expect(block.tier == 1)
        #expect(block.effectiveMessageRefs == refs(1 ... 3))
        #expect(block.directMessageRefs == refs(1 ... 3))
        #expect(block.createdByCallID == "c1")
    }

    @Test func rejectionsUseFirstFailingCheck() {
        let out = ContextPipeline.applyCompress(
            [
                CompressRange(startRef: "x1", endRef: "m00002", summary: summary),
                CompressRange(startRef: "m00009", endRef: "m00010", summary: summary),
                CompressRange(startRef: "m00003", endRef: "m00002", summary: summary),
                CompressRange(startRef: "m00001", endRef: "m00002", summary: "tiny"),
                CompressRange(startRef: "m00004", endRef: "m00005", summary: summary),
            ],
            messages: plain(5), blocks: [], protected: [ref(5)], nextBlockOrdinal: 0, callID: nil, configuration: config
        )
        #expect(out.errors == [
            "Range x1–m00002: invalid ref",
            "Range m00009–m00010: unknown ref",
            "Range m00003–m00002: start after end",
            "Range m00001–m00002: summary too short",
            "Range m00004–m00005: protected ref m00005",
        ])
        #expect(out.created.isEmpty)
    }

    @Test func nestedCompressionAbsorbsAndRaisesTier() {
        let first = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00001", endRef: "m00002", summary: summary)],
            messages: plain(6), blocks: [], protected: [], nextBlockOrdinal: 0, callID: nil, configuration: config
        )
        let second = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00003", endRef: "m00004", summary: summary)],
            messages: plain(6), blocks: first.blocks, protected: [], nextBlockOrdinal: first.nextBlockOrdinal,
            callID: nil, configuration: config
        )
        let third = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00001", endRef: "m00004", summary: summary)],
            messages: plain(6), blocks: second.blocks, protected: [], nextBlockOrdinal: second.nextBlockOrdinal,
            callID: nil, configuration: config
        )
        #expect(third.errors.isEmpty)
        let parent = third.blocks[2]
        #expect(parent.id == ContextBlockID("b2"))
        #expect(parent.tier == 2)
        #expect(parent.directBlockIDs == [ContextBlockID("b0"), ContextBlockID("b1")])
        #expect(parent.effectiveMessageRefs == refs(1 ... 4))
        #expect(parent.directMessageRefs.isEmpty)
        #expect(third.blocks[0].active == false && third.blocks[1].active == false)
    }

    @Test func splitBlockAndAlreadyFoldedAreRejected() {
        let first = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00002", endRef: "m00003", summary: summary)],
            messages: plain(6), blocks: [], protected: [], nextBlockOrdinal: 0, callID: nil, configuration: config
        )
        let out = ContextPipeline.applyCompress(
            [
                CompressRange(startRef: "m00001", endRef: "m00002", summary: summary),
                CompressRange(startRef: "m00002", endRef: "m00003", summary: summary),
            ],
            messages: plain(6), blocks: first.blocks, protected: [], nextBlockOrdinal: 1, callID: nil,
            configuration: config
        )
        #expect(out.errors == [
            "Range m00001–m00002: splits block b0",
            "Range m00002–m00003: already folded",
        ])
    }

    @Test func splitToolCallIsRejected() {
        let messages = stored([
            .user("u1"),
            assistantCalling(call("c1")),
            .tool(id: "c1", name: "bash", content: "out"),
        ])
        let out = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00002", endRef: "m00002", summary: summary)],
            messages: messages, blocks: [], protected: [], nextBlockOrdinal: 0, callID: nil, configuration: config
        )
        #expect(out.errors == ["Range m00002–m00002: splits tool call c1"])
    }

    @Test func decompressRestoresChildrenOnlyWhenNotFull() throws {
        let first = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00001", endRef: "m00002", summary: summary)],
            messages: plain(4), blocks: [], protected: [], nextBlockOrdinal: 0, callID: nil, configuration: config
        )
        let second = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00003", endRef: "m00004", summary: summary)],
            messages: plain(4), blocks: first.blocks, protected: [], nextBlockOrdinal: 1,
            callID: nil, configuration: config
        )
        let merged = ContextPipeline.applyCompress(
            [CompressRange(startRef: "m00001", endRef: "m00004", summary: summary)],
            messages: plain(4), blocks: second.blocks, protected: [], nextBlockOrdinal: 2,
            callID: nil, configuration: config
        )
        let outer = merged.blocks
        #expect(try ContextPipeline.applyDecompress(blockID: "b2", full: false, blocks: outer)[2].active == false)
        #expect(try ContextPipeline.applyDecompress(blockID: "b2", full: false, blocks: outer)[0].active)
        #expect(try ContextPipeline.applyDecompress(blockID: "b2", full: true, blocks: outer)[0].active == false)
        #expect(throws: ContextToolError.blockInactive("b0")) {
            try ContextPipeline.applyDecompress(blockID: "b0", full: false, blocks: outer)
        }
        #expect(throws: ContextToolError.unknownBlock("b9")) {
            try ContextPipeline.applyDecompress(blockID: "b9", full: false, blocks: outer)
        }
    }

    @Test func originalTextFormatsRolesAndRefs() {
        let messages = stored([
            .system("sys"),
            .assistant(AssistantMessage(content: "hi")),
            .tool(id: "1", name: "bash", content: "out")
        ])
        let text = ContextPipeline.originalText(
            of: block(0, covering: refs(1 ... 3)), messages: messages
        )
        #expect(text == "m00001 [system]\nsys\n\nm00002 [assistant]\nhi\n\nm00003 [tool:bash]\nout")
    }
}
