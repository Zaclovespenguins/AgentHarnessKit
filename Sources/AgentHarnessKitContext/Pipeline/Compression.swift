import AgentHarnessKit
import Foundation

// TASK H3. Stubs return placeholder values; replace the bodies, keep the signatures.

/// One range of a `compress` call, as the model sends it: `{"ranges":[{"startRef","endRef","topic","summary"}]}`.
public struct CompressRange: Sendable, Equatable, Codable {
    public let startRef: String
    public let endRef: String
    public let topic: String?
    public let summary: String

    public init(startRef: String, endRef: String, topic: String? = nil, summary: String) {
        self.startRef = startRef
        self.endRef = endRef
        self.topic = topic
        self.summary = summary
    }
}

public struct CompressOutcome: Sendable, Equatable {
    /// All blocks after the call: existing ones (absorbed ones now inactive) followed by new ones in range order.
    public let blocks: [ContextBlock]
    /// Ids of blocks created, in range order.
    public let created: [ContextBlockID]
    public let nextBlockOrdinal: Int
    /// One message per rejected range, `"Range <startRef>–<endRef>: <reason>"`.
    public let errors: [String]

    public init(blocks: [ContextBlock], created: [ContextBlockID], nextBlockOrdinal: Int, errors: [String]) {
        self.blocks = blocks
        self.created = created
        self.nextBlockOrdinal = nextBlockOrdinal
        self.errors = errors
    }
}

public extension ContextPipeline {
    /// Applies each range in order; a rejected range adds one error and is skipped, later ranges see the
    /// blocks created by earlier ones. A message is "unfolded" when no active block's
    /// `effectiveMessageRefs` contains it. Checks, first failure wins, reason text must contain the quoted phrase:
    /// 1. either ref does not parse as `MessageRef` -> "invalid ref";
    /// 2. either ordinal > `messages.count` -> "unknown ref";
    /// 3. start > end -> "start after end";
    /// 4. `summary.count < configuration.minSummaryLength` -> "summary too short";
    /// 5. any ref in the range is in `protected` -> "protected" (name the first protected ref);
    /// 6. an active block covers some refs inside and some outside the range -> "splits block bN";
    /// 7. an assistant in range has a call whose `.tool` result is outside it, or a `.tool` in range answers an
    ///    assistant outside it -> "splits tool call <callID>";
    /// 8. the range has no unfolded message and contains at most one active block -> "already folded".
    /// On success a block `b<nextBlockOrdinal>` is appended (ordinal then increments): tier 1 if it absorbs no
    /// block, else min(3, max absorbed tier + 1); `directMessageRefs` = unfolded refs in range;
    /// `directBlockIDs` = active blocks fully inside the range, ascending ordinal; `effectiveMessageRefs` =
    /// sorted union of those; topic = `topic ?? ""`; `createdByCallID = callID`; active, young, survived 0.
    /// Absorbed blocks become inactive.
    static func applyCompress(
        _ ranges: [CompressRange],
        messages: [StoredMessage],
        blocks: [ContextBlock],
        protected: Set<MessageRef>,
        nextBlockOrdinal: Int,
        callID: String?,
        configuration: ContextConfiguration
    ) -> CompressOutcome {
        CompressOutcome(blocks: blocks, created: [], nextBlockOrdinal: nextBlockOrdinal, errors: [])
    }

    /// Deactivates block `blockID`. Not `full`: its `directBlockIDs` become active again (one tier down);
    /// `full`: they stay inactive so the original messages render. Throws `.unknownBlock(blockID)` for an
    /// unknown id and `.blockInactive(blockID)` for an inactive block.
    static func applyDecompress(
        blockID: String,
        full: Bool,
        blocks: [ContextBlock]
    ) throws(ContextToolError) -> [ContextBlock] {
        blocks
    }

    /// Original text of every message the block covers: for each effective ref, `"<ref> [<role>]\n<text>"`
    /// joined by `"\n\n"`, where role is `system`, `user`, `assistant` or `tool:<name>` and text is
    /// `ContextTokens.text(of:)`.
    static func originalText(of block: ContextBlock, messages: [StoredMessage]) -> String {
        ""
    }
}
