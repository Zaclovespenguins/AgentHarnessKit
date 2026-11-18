import AgentHarnessKit
import Foundation

// Shared contract for the Phase 4b context pipeline. Frozen: pipeline/storage files implement against it.
// Design follows billion-context (acp-kernel); see docs/ARCHITECTURE.md section 4b for deviations.

/// Stable id of one recorded message, minted once per session and never reused. Rendered as `m00042`.
public struct MessageRef: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// 1-based position in the session's recorded messages.
    public let ordinal: Int

    public init(_ ordinal: Int) {
        self.ordinal = ordinal
    }

    /// Parses `m` followed by digits (`m00042`, `m7`); nil otherwise.
    public init?(_ string: String) {
        guard string.first == "m", let value = Int(string.dropFirst()), value > 0,
              string.dropFirst().allSatisfy(\.isASCII) else { return nil }
        ordinal = value
    }

    /// `m` + ordinal zero-padded to five digits (wider when the ordinal needs it).
    public var description: String {
        let digits = String(ordinal)
        return "m" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }

    public static func < (lhs: MessageRef, rhs: MessageRef) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// A recorded message with its ref and frozen token estimate.
public struct StoredMessage: Sendable, Equatable {
    public let ref: MessageRef
    public let message: ChatMessage
    public let tokens: Int

    public init(ref: MessageRef, message: ChatMessage, tokens: Int) {
        self.ref = ref
        self.message = message
        self.tokens = tokens
    }
}

public enum BlockGeneration: String, Sendable, Codable {
    case young, old
}

/// A summary that replaces a range of history. Tier 1 folds messages; tier N+1 absorbs tier-N blocks (cap 3).
public struct ContextBlock: Sendable, Equatable {
    /// `b0`, `b1`, ... (unpadded), minted from `ContextSessionState.nextBlockOrdinal`.
    public let id: ContextBlockID
    public var tier: Int
    public var topic: String
    public var summary: String
    /// Messages folded directly by this block (not via a source block), ascending.
    public var directMessageRefs: [MessageRef]
    /// Blocks absorbed by this block, ascending by ordinal.
    public var directBlockIDs: [ContextBlockID]
    /// Every original message this block covers, transitively through `directBlockIDs`, ascending.
    public var effectiveMessageRefs: [MessageRef]
    /// Inactive blocks are kept (archive, never delete) but not rendered.
    public var active: Bool
    public var generation: BlockGeneration
    /// Number of `syncBlocks` passes survived while active.
    public var survivedCount: Int
    /// Id of the `compress` tool call that created this block, used to hide consumed compress calls.
    public var createdByCallID: String?

    public init(
        id: ContextBlockID,
        tier: Int,
        topic: String,
        summary: String,
        directMessageRefs: [MessageRef],
        directBlockIDs: [ContextBlockID] = [],
        effectiveMessageRefs: [MessageRef],
        active: Bool = true,
        generation: BlockGeneration = .young,
        survivedCount: Int = 0,
        createdByCallID: String? = nil
    ) {
        self.id = id
        self.tier = tier
        self.topic = topic
        self.summary = summary
        self.directMessageRefs = directMessageRefs
        self.directBlockIDs = directBlockIDs
        self.effectiveMessageRefs = effectiveMessageRefs
        self.active = active
        self.generation = generation
        self.survivedCount = survivedCount
        self.createdByCallID = createdByCallID
    }

    /// Ordinal of `bN`; nil if the id is not in that form.
    public var ordinal: Int? {
        id.rawValue.first == "b" ? Int(id.rawValue.dropFirst()) : nil
    }
}

/// One element of the per-turn pipeline between folding and rendering.
public enum RenderItem: Sendable, Equatable {
    case message(StoredMessage)
    case summary(ContextBlock)
}

/// Thresholds and prompt text. Defaults follow acp-kernel `config.ts` (verified 2026-11-16).
public struct ContextConfiguration: Sendable {
    /// Recent zone: at least this many trailing messages are protected (kernel `preserveRecentMessages`).
    public var protectedRecentMessages: Int
    /// Recent zone also extends back until it holds at least this many tokens (kernel `preserveRecentTokens`).
    public var protectedRecentTokens: Int
    /// Nudge only when used tokens >= this fraction of the window (kernel `nudge.minContextLimitPct`).
    public var nudgeFloor: Double
    /// After a nudge, the next one needs this much growth (tokens) since it (kernel `nudge.minGrowthFloor`).
    public var nudgeGrowthTokens: Int
    /// Emergency truncation when rendered tokens exceed this fraction of the window (kernel `truncate.threshold`).
    public var emergencyThreshold: Double
    /// Active blocks become `.old` after surviving this many syncs (kernel `promotionThreshold`).
    public var promotionThreshold: Int
    /// Summaries shorter than this are rejected (kernel `compress.minSummaryLength`).
    public var minSummaryLength: Int
    /// Appended to the system prompt so the model manages context without a nudge.
    public var doctrine: String
    /// Heading of the nudge message; the compressible ranges are listed after it.
    public var nudgeText: String

    public init(
        protectedRecentMessages: Int = 3,
        protectedRecentTokens: Int = 5000,
        nudgeFloor: Double = 0.45,
        nudgeGrowthTokens: Int = 20000,
        emergencyThreshold: Double = 0.95,
        promotionThreshold: Int = 5,
        minSummaryLength: Int = 50,
        doctrine: String = ContextConfiguration.defaultDoctrine,
        nudgeText: String = ContextConfiguration.defaultNudgeText
    ) {
        self.protectedRecentMessages = protectedRecentMessages
        self.protectedRecentTokens = protectedRecentTokens
        self.nudgeFloor = nudgeFloor
        self.nudgeGrowthTokens = nudgeGrowthTokens
        self.emergencyThreshold = emergencyThreshold
        self.promotionThreshold = promotionThreshold
        self.minSummaryLength = minSummaryLength
        self.doctrine = doctrine
        self.nudgeText = nudgeText
    }

    public static let defaultDoctrine = """
    CONTEXT MANAGEMENT: user and tool messages carry tags like <acp tokens="1.2K" type="bash">m00042</acp>. \
    You manage your own context with `compress` (fold a finished range mSTART-mEND into a summary you write), \
    `decompress` (restore a block bN), `search_context` and `context_status`. Compress between task steps, \
    never mid-step, and only ranges whose details you no longer need. Keep open objectives, decisions, file \
    paths and identifiers in summaries. You may decline to compress.
    """

    public static let defaultNudgeText = """
    This is an efficiency nudge to compress early and keep context lean, not an overflow warning. \
    Fold finished work with one `compress` call if it fits your current step; otherwise continue.
    """
}

/// Per-session state the engine loads, runs the pipeline over, and saves.
public struct ContextSessionState: Sendable, Equatable {
    /// Every recorded message in order; refs are `MessageRef(1)...MessageRef(count)`. Append-only.
    public var messages: [StoredMessage]
    /// All blocks ever created, active and archived, in creation order.
    public var blocks: [ContextBlock]
    /// Next `bN` ordinal to mint.
    public var nextBlockOrdinal: Int
    /// Used-token level at the last nudge; nil after a successful compress or before any nudge.
    public var nudgeBaseline: Int?
    /// Input tokens the provider reported for the latest request; nil when never reported.
    public var lastInputTokens: Int?
    /// Incremented on every saved mutation. Checkpoints store it as the block-state version.
    public var version: Int

    public init(
        messages: [StoredMessage] = [],
        blocks: [ContextBlock] = [],
        nextBlockOrdinal: Int = 0,
        nudgeBaseline: Int? = nil,
        lastInputTokens: Int? = nil,
        version: Int = 0
    ) {
        self.messages = messages
        self.blocks = blocks
        self.nextBlockOrdinal = nextBlockOrdinal
        self.nudgeBaseline = nudgeBaseline
        self.lastInputTokens = lastInputTokens
        self.version = version
    }
}

public struct ContextSearchHit: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case message(MessageRef)
        case block(ContextBlockID)
    }

    public let source: Source
    /// The matching text (summary or message text), possibly shortened.
    public let snippet: String

    public init(source: Source, snippet: String) {
        self.source = source
        self.snippet = snippet
    }
}

/// Durable storage for `ContextSessionState`, scoped by session. No query may cross sessions.
public protocol ContextPersistence: Sendable {
    /// Returns the saved state, or an empty `ContextSessionState()` for an unknown session.
    func load(sessionID: SessionID) async throws -> ContextSessionState
    /// Persists `state`. Messages are append-only: throws `ContextPersistenceError.messageRewritten` if a
    /// previously saved ref has different content, or `.messagesRemoved` if fewer messages are passed.
    /// Blocks are upserted by id; scalar fields are replaced.
    func save(sessionID: SessionID, state: ContextSessionState) async throws
    /// Case-insensitive search for messages and block summaries containing every whitespace-separated
    /// word of `query` as a whole word. Covers all messages (folded originals included) and active
    /// blocks. Order: blocks by ascending ordinal, then messages by ascending ref; at most `limit` hits.
    /// An empty query returns no hits.
    func search(sessionID: SessionID, query: String, limit: Int) async throws -> [ContextSearchHit]
}

public enum ContextPersistenceError: Error, Equatable {
    case messageRewritten(MessageRef)
    case messagesRemoved(saved: Int, given: Int)
}

/// Token estimation shared by every stage: ceil(characters / 4), the acp-kernel `render-refs.ts` default.
public enum ContextTokens {
    public static func estimate(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// Text of the message: content, plus tool-call names and arguments for assistants, plus text parts for
    /// multimodal users. Each non-text multimodal part adds 256 tokens.
    public static func estimate(_ message: ChatMessage) -> Int {
        switch message {
        case let .userMultimodal(parts):
            parts.reduce(0) { total, part in
                if case let .text(text) = part {
                    return total + estimate(text)
                }
                return total + 256
            }
        default:
            estimate(text(of: message))
        }
    }

    /// Plain text used for estimation and search.
    public static func text(of message: ChatMessage) -> String {
        switch message {
        case let .system(text), let .user(text):
            text
        case let .userMultimodal(parts):
            parts.compactMap {
                if case let .text(text) = $0 {
                    text
                } else {
                    nil
                }
            }.joined(separator: "\n")
        case let .assistant(assistant):
            ([assistant.content] + assistant.toolCalls.map { "\($0.name) \($0.arguments)" })
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case let .tool(_, _, content):
            content
        }
    }
}

/// The four reserved tool names.
public enum ContextToolName {
    public static let compress = "compress"
    public static let decompress = "decompress"
    public static let searchContext = "search_context"
    public static let contextStatus = "context_status"
    public static let all: Set<String> = [compress, decompress, searchContext, contextStatus]
}

public extension RenderItem {
    /// Message: its frozen `tokens`. Summary: estimate(topic) + estimate(summary).
    var tokens: Int {
        switch self {
        case let .message(stored): stored.tokens
        case let .summary(block): ContextTokens.estimate(block.topic) + ContextTokens.estimate(block.summary)
        }
    }
}

/// Model-readable failure of a context tool; the engine returns `description` as an `isError` tool result.
public enum ContextToolError: Error, Equatable, CustomStringConvertible {
    case unknownBlock(String)
    case blockInactive(String)
    case invalidArguments(String)

    public var description: String {
        switch self {
        case let .unknownBlock(id): "Unknown block \(id). Call context_status to list active blocks."
        case let .blockInactive(id): "Block \(id) is not active (already restored or absorbed into another block)."
        case let .invalidArguments(detail): "Invalid arguments: \(detail)"
        }
    }
}

/// Namespace for the pure per-turn pipeline stages. Order: assignRefs, syncBlocks, fold,
/// hideCompressionCalls, emergencyTruncate, render, then append the nudge when `shouldNudge`.
public enum ContextPipeline {}
