import AgentHarnessKit
@testable import AgentHarnessKitContext
import Testing

struct CompressionTests {
    private static let summary = String(repeating: "summary ", count: 8)

    /// 1 system, 2 first user, 3 asst, 4 user, 5 asst->c1, 6 tool c1, 7 asst, 8 user, 9 asst, 10 user,
    /// 11 asst, 12 user, 13 asst->c2, 14 tool c2, 15 last user, 16 asst.
    private let messages = stored([
        .system("sys"), .user("task"), .assistant(AssistantMessage(content: "plan")), .user("go"),
        assistantCalling(call("c1")), .tool(id: "c1", name: "bash", content: "out1"),
        .assistant(AssistantMessage(content: "a7")), .user("u8"), .assistant(AssistantMessage(content: "a9")),
        .user("u10"), .assistant(AssistantMessage(content: "a11")), .user("u12"), assistantCalling(call("c2")),
        .tool(id: "c2", name: "bash", content: "out2"), .user("last"), .assistant(AssistantMessage(content: "a16")),
    ])
    private let protected = Set([1, 2, 15, 16].map(ref))

    private func compress(
        _ ranges: [CompressRange],
        blocks: [ContextBlock] = [],
        next: Int = 0
    ) -> CompressOutcome {
        ContextPipeline.applyCompress(
            ranges, messages: messages, blocks: blocks, protected: protected,
            nextBlockOrdinal: next, callID: "call-1", configuration: ContextConfiguration()
        )
    }

    private func range(_ start: String, _ end: String, topic: String? = nil, summary: String = summary) -> CompressRange {
        CompressRange(startRef: start, endRef: end, topic: topic, summary: summary)
    }

    @Test func foldsTierOneBlock() {
        let outcome = compress([range("m00003", "m00006", topic: "setup")], next: 4)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.created == [ContextBlockID("b4")])
        #expect(outcome.nextBlockOrdinal == 5)
        #expect(outcome.blocks == [ContextBlock(
            id: ContextBlockID("b4"), tier: 1, topic: "setup", summary: Self.summary,
            directMessageRefs: refs(3 ... 6), effectiveMessageRefs: refs(3 ... 6), createdByCallID: "call-1"
        )])
    }

    @Test(arguments: [
        ("x3", "m00006", "invalid ref"),
        ("m00003", "m00099", "unknown ref"),
        ("m00006", "m00003", "start after end"),
        ("m00002", "m00004", "protected"),
        ("m00003", "m00005", "splits tool call c1"),
        ("m00006", "m00008", "splits tool call c1"),
    ])
    func rejectsInvalidRanges(start: String, end: String, reason: String) {
        let outcome = compress([range(start, end)])
        #expect(outcome.created.isEmpty)
        #expect(outcome.blocks.isEmpty)
        #expect(outcome.nextBlockOrdinal == 0)
        #expect(outcome.errors.count == 1)
        #expect(outcome.errors.first?.hasPrefix("Range \(start)\u{2013}\(end): ") == true)
        #expect(outcome.errors.first?.contains(reason) == true)
    }

    @Test func protectedErrorNamesTheRef() {
        #expect(compress([range("m00012", "m00015")]).errors.first?.contains("m00015") == true)
    }

    @Test func rejectsShortSummary() {
        let outcome = compress([range("m00003", "m00004", summary: "too short")])
        #expect(outcome.errors.first?.contains("summary too short") == true)
    }

    @Test func rejectsRangeSplittingABlock() {
        let existing = [block(0, covering: refs(3 ... 6))]
        let outcome = compress([range("m00005", "m00008")], blocks: existing, next: 1)
        #expect(outcome.errors.first?.contains("splits block b0") == true)
        #expect(outcome.blocks == existing)
    }

    @Test func rejectsAlreadyFoldedRange() {
        let existing = [block(0, covering: refs(3 ... 6))]
        #expect(compress([range("m00003", "m00006")], blocks: existing, next: 1).errors.first?
            .contains("already folded") == true)
    }

    @Test func inactiveBlocksDoNotCount() {
        let existing = [block(0, covering: refs(3 ... 6), active: false)]
        let outcome = compress([range("m00003", "m00006")], blocks: existing, next: 1)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.blocks.last?.tier == 1)
        #expect(outcome.blocks.last?.directBlockIDs == [])
    }

    @Test func absorbsBlocksIntoTierTwoWithLineage() throws {
        let existing = [block(0, covering: refs(3 ... 6)), block(1, covering: refs(7 ... 9))]
        let outcome = compress([range("m00003", "m00011")], blocks: existing, next: 2)
        #expect(outcome.errors.isEmpty)
        let created = try #require(outcome.blocks.last)
        #expect(created.id == ContextBlockID("b2"))
        #expect(created.tier == 2)
        #expect(created.directMessageRefs == refs(10 ... 11))
        #expect(created.directBlockIDs == [ContextBlockID("b0"), ContextBlockID("b1")])
        #expect(created.effectiveMessageRefs == refs(3 ... 11))
        #expect(outcome.blocks.prefix(2).allSatisfy { !$0.active })
    }

    @Test func twoBlocksAloneMayBeFolded() {
        let existing = [block(0, covering: refs(3 ... 6)), block(1, covering: refs(7 ... 9))]
        let outcome = compress([range("m00003", "m00009")], blocks: existing, next: 2)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.blocks.last?.directMessageRefs == [])
        #expect(outcome.blocks.last?.tier == 2)
    }

    @Test func tierIsCappedAtThree() {
        let existing = [block(0, tier: 3, covering: refs(3 ... 6), sources: [9])]
        let outcome = compress([range("m00003", "m00008")], blocks: existing, next: 1)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.blocks.last?.tier == 3)
    }

    @Test func rangesApplyInOrderAndFailIndependently() {
        let outcome = compress(
            [range("m00003", "m00006"), range("m00002", "m00003"), range("m00003", "m00009")],
            next: 5
        )
        #expect(outcome.created == [ContextBlockID("b5"), ContextBlockID("b6")])
        #expect(outcome.nextBlockOrdinal == 7)
        #expect(outcome.errors.count == 1)
        #expect(outcome.errors.first?.contains("protected") == true)
        #expect(outcome.blocks.first?.active == false)
        #expect(outcome.blocks.last?.tier == 2)
        #expect(outcome.blocks.last?.directBlockIDs == [ContextBlockID("b5")])
        #expect(outcome.blocks.last?.effectiveMessageRefs == refs(3 ... 9))
    }

    private let tiered = [
        block(0, covering: refs(3 ... 6), active: false),
        block(1, covering: refs(7 ... 9), active: false),
        block(2, tier: 2, covering: refs(3 ... 9), sources: [0, 1]),
    ]

    @Test func decompressRestoresOneTierDown() throws {
        let blocks = try ContextPipeline.applyDecompress(blockID: "b2", full: false, blocks: tiered)
        #expect(blocks.map(\.active) == [true, true, false])
    }

    @Test func fullDecompressRestoresOriginals() throws {
        let blocks = try ContextPipeline.applyDecompress(blockID: "b2", full: true, blocks: tiered)
        #expect(blocks.map(\.active) == [false, false, false])
    }

    @Test func decompressErrors() {
        #expect(throws: ContextToolError.unknownBlock("b9")) {
            try ContextPipeline.applyDecompress(blockID: "b9", full: false, blocks: tiered)
        }
        #expect(throws: ContextToolError.blockInactive("b0")) {
            try ContextPipeline.applyDecompress(blockID: "b0", full: false, blocks: tiered)
        }
    }

    @Test func originalTextListsEveryCoveredMessage() {
        let covered = block(0, covering: [ref(3), ref(5), ref(6)])
        #expect(ContextPipeline.originalText(of: covered, messages: messages) ==
            "m00003 [assistant]\nplan\n\nm00005 [assistant]\nbash {}\n\nm00006 [tool:bash]\nout1")
    }
}
