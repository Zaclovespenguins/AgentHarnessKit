import AgentHarnessKit
import Foundation

// TASK H8. Stubs; replace the bodies, keep the public signatures.

public enum ContextStoreError: Error, Equatable {
    /// The loop's history no longer extends what the store recorded for this session.
    case historyDiverged(at: MessageRef)
}

/// The billion-context `ContextStore`: persists every message, renders through `ContextPipeline`, and executes
/// the four reserved tools. One actor may serve many sessions; all state lives in `persistence`.
///
/// Message alignment (render and record): the loop's messages are append-only. `render` receives the full
/// history: message `i` (0-based) is `MessageRef(i + 1)`; every stored message must equal the loop message at
/// the same position, else `ContextStoreError.historyDiverged(at:)` (also when more messages are stored than
/// passed). Messages beyond the stored count are appended with `ContextPipeline.assignRefs`. `record` receives
/// only the newest messages: find the largest `k` such that the last `k` stored messages equal the first `k`
/// given, append the rest, and store `usage?.input` as `lastInputTokens` when usage is non-nil.
///
/// `version` changes only when the block state changes (a successful compress or non-file decompress), so
/// appending messages or syncing blocks never invalidates a checkpoint. `stateVersion` returns `String(version)`.
public actor HierarchicalContextStore: ContextStore {
    private let persistence: any ContextPersistence
    private let configuration: ContextConfiguration
    private let exportDirectory: URL?

    /// - Parameter exportDirectory: where `decompress` with `toFile` may write; nil disables file export.
    public init(
        persistence: any ContextPersistence,
        configuration: ContextConfiguration = ContextConfiguration(),
        exportDirectory: URL? = nil
    ) {
        self.persistence = persistence
        self.configuration = configuration
        self.exportDirectory = exportDirectory
    }

    /// `compress` `{"ranges":[{"startRef","endRef","topic"?,"summary"}]}`; `decompress`
    /// `{"blockId", "full"?: Bool, "toFile"?: String}`; `search_context` `{"query", "limit"?: Int}` (default 5);
    /// `context_status` `{}`. Descriptions tell the model the formats; names from `ContextToolName`.
    public nonisolated var toolDefinitions: [ToolDefinition] {
        []
    }

    /// 1. nil `windowSize` throws `AgentError.missingContextWindowSize`.
    /// 2. Align and append messages (see type docs); `syncBlocks` once per render.
    /// 3. `protectedRefs`, `fold`, `hideCompressionCalls`, `emergencyTruncate(windowSize:)`, `render`.
    /// 4. Doctrine: when the first rendered message is `.system(s)` it becomes `.system(s + "\n\n" + doctrine)`,
    ///    else `.system(doctrine)` is inserted first.
    /// 5. used = sum of `RenderItem.tokens` after truncation. If `shouldNudge(used, windowSize, nudgeBaseline)`,
    ///    append `nudgeMessage(compressibleRanges(...))` as the last message and set `nudgeBaseline = used`.
    /// 6. Save the state (version unchanged) and remember `windowSize` for `context_status`.
    public func render(sessionID: SessionID, messages: [ChatMessage], windowSize: Int?) async throws -> [ChatMessage] {
        messages
    }

    public func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws {}

    /// Model mistakes (bad JSON, rejected ranges, unknown or inactive block, file export disabled, unknown tool)
    /// come back as `isError: true` results with readable text, never as thrown errors.
    /// - compress: `applyCompress(callID: call.id)` with the session's `protectedRefs`. Content lists one line per
    ///   created block, `"Created bN (mA–mB, tier T)"`, then the error lines. `isError` when nothing was created.
    ///   On success: blocks and `nextBlockOrdinal` saved, `nudgeBaseline = nil`, `version += 1`, and one
    ///   `.contextFolded(ContextFold(blockIDs: created, tokensSaved: max(0, before - after)))` event, where
    ///   before/after are the token sums of `fold` + `hideCompressionCalls` over the stored messages.
    /// - decompress without `toFile`: `applyDecompress`; `version += 1`; content `"Restored bN"`; event
    ///   `.contextRestored(ContextRestore(blockID:, tokensRestored: max(0, after - before)))`.
    /// - decompress with `toFile`: must be a plain file name (no `/`, not `.` or `..`, non-empty) and
    ///   `exportDirectory` must be set; writes `originalText(of:)` to `exportDirectory/toFile` and returns
    ///   `"Wrote bN (<count> messages) to <toFile>"`. Blocks and version unchanged, no event.
    /// - search_context: `persistence.search`; one line per hit, `"<id>: <snippet>"` (bN or mNNNNN), or
    ///   `"No matches."`.
    /// - context_status: a readable report (used tokens, window, breakdown system/tools/summaries/text, active
    ///   blocks, compressible ranges) and event `.contextStatus(ContextStatus(windowSize: <last render's window,
    ///   0 if none>, usedTokens: <rendered token sum>, blockCount: <active blocks>))`.
    public func executeTool(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        ContextToolOutcome(result: ToolResult(content: "", isError: true))
    }

    public func stateVersion(sessionID: SessionID) async throws -> String? {
        nil
    }
}
