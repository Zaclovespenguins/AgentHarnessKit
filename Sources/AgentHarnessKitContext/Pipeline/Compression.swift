import AgentHarnessKit
import Foundation

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
    static func applyCompress( // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ ranges: [CompressRange],
        messages: [StoredMessage],
        blocks: [ContextBlock],
        protected: Set<MessageRef>,
        nextBlockOrdinal: Int,
        callID: String?,
        configuration: ContextConfiguration
    ) -> CompressOutcome {
        var blocks = blocks
        var nextOrdinal = nextBlockOrdinal
        var created: [ContextBlockID] = []
        var errors: [String] = []
        // Call and result owners never change during one compress call.
        var callOwner: [String: MessageRef] = [:]
        var resultOwner: [String: MessageRef] = [:]
        for stored in messages {
            switch stored.message {
            case let .assistant(assistant):
                for call in assistant.toolCalls {
                    callOwner[call.id] = stored.ref
                }
            case let .tool(id, _, _):
                resultOwner[id] = stored.ref
            default:
                break
            }
        }

        for range in ranges {
            let label = "Range \(range.startRef)–\(range.endRef): "
            guard let start = MessageRef(range.startRef), let end = MessageRef(range.endRef) else {
                errors.append(label + "invalid ref")
                continue
            }
            guard max(start.ordinal, end.ordinal) <= messages.count else {
                errors.append(label + "unknown ref")
                continue
            }
            guard start <= end else {
                errors.append(label + "start after end")
                continue
            }
            guard range.summary.count >= configuration.minSummaryLength else {
                errors.append(label + "summary too short")
                continue
            }
            let span = start.ordinal ... end.ordinal
            let refsIn = messages.map(\.ref).filter { span.contains($0.ordinal) }
            if let first = refsIn.first(where: { protected.contains($0) }) {
                errors.append(label + "protected ref \(first)")
                continue
            }
            let active = blocks.filter(\.active)
            let splitBlock = active.first { block in
                let hits = block.effectiveMessageRefs.count(where: { span.contains($0.ordinal) })
                return hits > 0 && hits < block.effectiveMessageRefs.count
            }
            if let splitBlock {
                errors.append(label + "splits block \(splitBlock.id.rawValue)")
                continue
            }
            let absorbed = active
                .filter { $0.effectiveMessageRefs.allSatisfy { span.contains($0.ordinal) } }
                .sorted { ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
            let unfolded = refsIn.filter { ref in !active.contains { $0.effectiveMessageRefs.contains(ref) } }
            let splitCall = messages.filter { span.contains($0.ref.ordinal) }.lazy.compactMap { stored -> String? in
                switch stored.message {
                case let .assistant(assistant):
                    return assistant.toolCalls.map(\.id).first { id in
                        resultOwner[id].map { !span.contains($0.ordinal) } ?? false
                    }
                case let .tool(id, _, _):
                    return callOwner[id].map { !span.contains($0.ordinal) } == true ? id : nil
                default:
                    return nil
                }
            }.first
            if let splitCall {
                errors.append(label + "splits tool call \(splitCall)")
                continue
            }
            if unfolded.isEmpty, absorbed.count <= 1 {
                errors.append(label + "already folded")
                continue
            }

            let tier = absorbed.map(\.tier).max().map { min(3, $0 + 1) } ?? 1
            let effective = Set(unfolded + absorbed.flatMap(\.effectiveMessageRefs)).sorted()
            let absorbedIDs = Set(absorbed.map(\.id))
            for index in blocks.indices where absorbedIDs.contains(blocks[index].id) {
                blocks[index].active = false
            }
            let block = ContextBlock(
                id: ContextBlockID("b\(nextOrdinal)"),
                tier: tier,
                topic: range.topic ?? "",
                summary: range.summary,
                directMessageRefs: unfolded,
                directBlockIDs: absorbed.map(\.id),
                effectiveMessageRefs: effective,
                createdByCallID: callID
            )
            blocks.append(block)
            created.append(block.id)
            nextOrdinal += 1
        }
        return CompressOutcome(blocks: blocks, created: created, nextBlockOrdinal: nextOrdinal, errors: errors)
    }

    /// Deactivates block `blockID`. Not `full`: its `directBlockIDs` become active again (one tier down);
    /// `full`: they stay inactive so the original messages render. Throws `.unknownBlock(blockID)` for an
    /// unknown id and `.blockInactive(blockID)` for an inactive block.
    static func applyDecompress(
        blockID: String,
        full: Bool,
        blocks: [ContextBlock]
    ) throws(ContextToolError) -> [ContextBlock] {
        guard let index = blocks.firstIndex(where: { $0.id.rawValue == blockID }) else {
            throw ContextToolError.unknownBlock(blockID)
        }
        guard blocks[index].active else {
            throw ContextToolError.blockInactive(blockID)
        }
        var result = blocks
        result[index].active = false
        if !full {
            for child in blocks[index].directBlockIDs {
                if let childIndex = result.firstIndex(where: { $0.id == child }) {
                    result[childIndex].active = true
                }
            }
        }
        return result
    }

    /// Original text of every message the block covers: for each effective ref, `"<ref> [<role>]\n<text>"`
    /// joined by `"\n\n"`, where role is `system`, `user`, `assistant` or `tool:<name>` and text is
    /// `ContextTokens.text(of:)`.
    static func originalText(of block: ContextBlock, messages: [StoredMessage]) -> String {
        block.effectiveMessageRefs.compactMap { ref in
            messages.first { $0.ref == ref }.map { stored in
                "\(ref) [\(roleName(stored.message))]\n\(ContextTokens.text(of: stored.message))"
            }
        }.joined(separator: "\n\n")
    }

    private static func roleName(_ message: ChatMessage) -> String {
        switch message {
        case .system: "system"
        case .user, .userMultimodal: "user"
        case .assistant: "assistant"
        case let .tool(_, name, _): "tool:\(name)"
        }
    }
}
