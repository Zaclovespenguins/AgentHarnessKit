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
/// the same position, else `ContextStoreError.historyDiverged(at:)` naming the first mismatching ref (when more
/// messages are stored than passed, the first stored ref with no loop message: `MessageRef(messages.count + 1)`). Messages beyond the stored count are appended with `ContextPipeline.assignRefs`. `record` receives
/// only the newest messages: find the largest `k` such that the last `k` stored messages equal the first `k`
/// given, append the rest, and store `usage?.input` as `lastInputTokens` when usage is non-nil.
///
/// `version` changes only when the block state changes (a successful compress or non-file decompress), so
/// appending messages or syncing blocks never invalidates a checkpoint. `stateVersion` returns `String(version)`.
public actor HierarchicalContextStore: ContextStore {
    private let persistence: any ContextPersistence
    private let configuration: ContextConfiguration
    private let exportDirectory: URL?
    /// Window size of the last `render` per session, for `context_status`. Not persisted.
    private var windowSizes: [SessionID: Int] = [:]

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
        [
            ToolDefinition(
                name: ContextToolName.compress,
                description: #"Fold finished message ranges into summary blocks. Argument format: {"ranges":[{"startRef":"m00001","endRef":"m00005","topic":"optional","summary":"keep objectives, decisions, paths, identifiers"}]}. Compress between task steps, never mid-step."#,
                parametersSchema: .object(properties: [
                    "ranges": .array(items: .object(properties: [
                        "startRef": .string(description: "First message ref, e.g. m00001"),
                        "endRef": .string(description: "Last message ref, inclusive"),
                        "topic": .string(description: "Optional short topic"),
                        "summary": .string(description: "Summary that replaces the range"),
                    ], required: ["startRef", "endRef", "summary"])),
                ], required: ["ranges"])
            ),
            ToolDefinition(
                name: ContextToolName.decompress,
                description: #"Restore a compressed block. Argument format: {"blockId":"b0","full":false,"toFile":"name.txt"}. full:true keeps nested blocks folded; toFile writes the original messages to a file instead of restoring them."#,
                parametersSchema: .object(properties: [
                    "blockId": .string(description: "Block id, e.g. b0"),
                    "full": .boolean(description: "Restore original messages instead of one tier down"),
                    "toFile": .string(description: "Plain file name to export the original messages to"),
                ], required: ["blockId"])
            ),
            ToolDefinition(
                name: ContextToolName.searchContext,
                description: #"Search compressed blocks and original messages. Argument format: {"query":"words","limit":5}."#,
                parametersSchema: .object(properties: [
                    "query": .string(description: "Words to find; all must appear"),
                    "limit": .integer(description: "Maximum hits, default 5"),
                ], required: ["query"])
            ),
            ToolDefinition(
                name: ContextToolName.contextStatus,
                description: "Show context-window usage, active blocks and compressible ranges. Argument format: {}.",
                parametersSchema: .object(properties: [:], required: [])
            ),
        ]
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
        guard let windowSize else { throw AgentError.missingContextWindowSize }
        var state = try await persistence.load(sessionID: sessionID)
        if messages.count < state.messages.count {
            throw ContextStoreError.historyDiverged(at: MessageRef(messages.count + 1))
        }
        for stored in state.messages where stored.message != messages[stored.ref.ordinal - 1] {
            throw ContextStoreError.historyDiverged(at: stored.ref)
        }
        let existing = state.messages.count
        state.messages += ContextPipeline.assignRefs(Array(messages.dropFirst(existing)), existingCount: existing)
        state.blocks = ContextPipeline.syncBlocks(state.blocks, promotionThreshold: configuration.promotionThreshold)

        let protected = ContextPipeline.protectedRefs(state.messages, configuration: configuration)
        let items = pipelineItems(state, windowSize: windowSize)
        var rendered = ContextPipeline.render(items)
        if case let .system(text)? = rendered.first {
            rendered[0] = .system(text + "\n\n" + configuration.doctrine)
        } else {
            rendered.insert(.system(configuration.doctrine), at: 0)
        }

        let used = tokenSum(items)
        if ContextPipeline.shouldNudge(
            usedTokens: used, windowSize: windowSize, baseline: state.nudgeBaseline, configuration: configuration
        ) {
            let ranges = ContextPipeline.compressibleRanges(state.messages, blocks: state.blocks, protected: protected)
            rendered.append(ContextPipeline.nudgeMessage(ranges: ranges, messages: state.messages, configuration: configuration))
            state.nudgeBaseline = used
        }
        try await persistence.save(sessionID: sessionID, state: state)
        windowSizes[sessionID] = windowSize
        return rendered
    }

    /// Appends the loop's newest messages (see type docs) and stores the reported input tokens.
    public func record(sessionID: SessionID, messages: [ChatMessage], usage: TokenUsage?) async throws {
        var state = try await persistence.load(sessionID: sessionID)
        var overlap = min(state.messages.count, messages.count)
        while overlap > 0, state.messages.suffix(overlap).map(\.message) != Array(messages.prefix(overlap)) {
            overlap -= 1
        }
        let existing = state.messages.count
        state.messages += ContextPipeline.assignRefs(Array(messages.dropFirst(overlap)), existingCount: existing)
        if let usage { state.lastInputTokens = usage.input }
        try await persistence.save(sessionID: sessionID, state: state)
    }

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
        do {
            switch call.name {
            case ContextToolName.compress:
                return try await runCompress(call, sessionID: sessionID)
            case ContextToolName.decompress:
                return try await runDecompress(call, sessionID: sessionID)
            case ContextToolName.searchContext:
                return try await runSearch(call, sessionID: sessionID)
            case ContextToolName.contextStatus:
                return try await runStatus(sessionID: sessionID)
            default:
                return ContextToolOutcome(result: ToolResult(content: "Unknown context tool: \(call.name)", isError: true))
            }
        } catch let error as ContextToolError {
            return ContextToolOutcome(result: ToolResult(content: error.description, isError: true))
        }
    }

    /// Version is the saved block-state counter, as text.
    public func stateVersion(sessionID: SessionID) async throws -> String? {
        let state = try await persistence.load(sessionID: sessionID)
        return String(state.version)
    }

    // MARK: - Tools

    private struct CompressArguments: Decodable {
        let ranges: [CompressRange]
    }

    private struct DecompressArguments: Decodable {
        let blockId: String
        let full: Bool?
        let toFile: String?
    }

    private struct SearchArguments: Decodable {
        let query: String
        let limit: Int?
    }

    private func runCompress(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        let args = try decode(CompressArguments.self, call)
        let state = try await persistence.load(sessionID: sessionID)
        let outcome = ContextPipeline.applyCompress(
            args.ranges,
            messages: state.messages,
            blocks: state.blocks,
            protected: ContextPipeline.protectedRefs(state.messages, configuration: configuration),
            nextBlockOrdinal: state.nextBlockOrdinal,
            callID: call.id,
            configuration: configuration
        )
        let created = outcome.created.compactMap { id in outcome.blocks.first { $0.id == id } }
        let lines = created.map { block -> String in
            let refs = block.effectiveMessageRefs
            let first = refs.first?.description ?? ""
            let last = refs.last?.description ?? ""
            return "Created \(block.id.rawValue) (\(first)\u{2013}\(last), tier \(block.tier))"
        }
        let content = lines + outcome.errors
        guard !created.isEmpty else {
            let text = content.isEmpty ? "No ranges given." : content.joined(separator: "\n")
            return ContextToolOutcome(result: ToolResult(content: text, isError: true))
        }

        var next = state
        next.blocks = outcome.blocks
        next.nextBlockOrdinal = outcome.nextBlockOrdinal
        next.nudgeBaseline = nil
        next.version += 1
        let before = tokenSum(folded(state))
        let after = tokenSum(folded(next))
        try await persistence.save(sessionID: sessionID, state: next)
        let fold = ContextFold(blockIDs: outcome.created, tokensSaved: max(0, before - after))
        return ContextToolOutcome(
            result: ToolResult(content: content.joined(separator: "\n")),
            events: [.contextFolded(fold)]
        )
    }

    private func runDecompress(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        let args = try decode(DecompressArguments.self, call)
        let state = try await persistence.load(sessionID: sessionID)
        if let toFile = args.toFile {
            return try export(blockID: args.blockId, toFile: toFile, state: state)
        }

        var next = state
        next.blocks = try ContextPipeline.applyDecompress(blockID: args.blockId, full: args.full ?? false, blocks: state.blocks)
        next.version += 1
        let before = tokenSum(folded(state))
        let after = tokenSum(folded(next))
        try await persistence.save(sessionID: sessionID, state: next)
        let restore = ContextRestore(blockID: ContextBlockID(args.blockId), tokensRestored: max(0, after - before))
        return ContextToolOutcome(
            result: ToolResult(content: "Restored \(args.blockId)"),
            events: [.contextRestored(restore)]
        )
    }

    private func export(blockID: String, toFile: String, state: ContextSessionState) throws -> ContextToolOutcome {
        guard isPlainFileName(toFile) else {
            throw ContextToolError.invalidArguments("toFile must be a plain file name")
        }
        guard let exportDirectory else {
            throw ContextToolError.invalidArguments("file export is disabled")
        }
        guard let block = state.blocks.first(where: { $0.id.rawValue == blockID }) else {
            throw ContextToolError.unknownBlock(blockID)
        }
        guard block.active else {
            throw ContextToolError.blockInactive(blockID)
        }
        let text = ContextPipeline.originalText(of: block, messages: state.messages)
        do {
            try text.write(to: exportDirectory.appendingPathComponent(toFile), atomically: true, encoding: .utf8)
        } catch {
            return ContextToolOutcome(
                result: ToolResult(content: "Could not write \(toFile): \(error.localizedDescription)", isError: true)
            )
        }
        let count = block.effectiveMessageRefs.count
        return ContextToolOutcome(result: ToolResult(content: "Wrote \(block.id.rawValue) (\(count) messages) to \(toFile)"))
    }

    private func runSearch(_ call: ToolCall, sessionID: SessionID) async throws -> ContextToolOutcome {
        let args = try decode(SearchArguments.self, call)
        // Context tool results skip maxToolResultCharacters, so bound hits and snippets here.
        let limit = min(max(args.limit ?? 5, 1), 20)
        let hits = try await persistence.search(sessionID: sessionID, query: args.query, limit: limit)
        let lines = hits.map { hit -> String in
            let flat = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            let snippet = flat.count > 300 ? flat.prefix(300) + "…" : flat
            return switch hit.source {
            case let .message(ref): "\(ref): \(snippet)"
            case let .block(id): "\(id.rawValue): \(snippet)"
            }
        }
        let text = lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
        return ContextToolOutcome(result: ToolResult(content: text))
    }

    private func runStatus(sessionID: SessionID) async throws -> ContextToolOutcome {
        let state = try await persistence.load(sessionID: sessionID)
        let windowSize = windowSizes[sessionID] ?? 0
        let items = pipelineItems(state, windowSize: windowSize)
        let used = tokenSum(items)
        let active = state.blocks.filter(\.active)
        let protected = ContextPipeline.protectedRefs(state.messages, configuration: configuration)
        let ranges = ContextPipeline.compressibleRanges(state.messages, blocks: state.blocks, protected: protected)

        var system = 0, tools = 0, summaries = 0, text = 0
        for item in items {
            switch item {
            case .summary: summaries += item.tokens
            case let .message(stored):
                switch stored.message {
                case .system: system += item.tokens
                case .tool: tools += item.tokens
                default: text += item.tokens
                }
            }
        }

        let window = windowSize > 0 ? " of \(windowSize) (\(used * 100 / windowSize)%)" : ""
        let activeText = active.isEmpty ? "none" : active.map { "\($0.id.rawValue) (tier \($0.tier))" }.joined(separator: ", ")
        let rangeText = ranges.isEmpty ? "none" : ranges.map { "\($0.lowerBound)\u{2013}\($0.upperBound)" }.joined(separator: ", ")
        let report = [
            "Context: \(used) tokens used\(window)",
            "Breakdown: system \(system), tools \(tools), summaries \(summaries), text \(text)",
            "Active blocks: \(activeText)",
            "Compressible ranges: \(rangeText)",
        ].joined(separator: "\n")
        let status = ContextStatus(windowSize: windowSize, usedTokens: used, blockCount: active.count)
        return ContextToolOutcome(result: ToolResult(content: report), events: [.contextStatus(status)])
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(call.arguments.utf8))
        } catch {
            throw ContextToolError.invalidArguments("\(call.name): \(error.localizedDescription)")
        }
    }

    private func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    /// Fold and hide consumed compress calls; no truncation.
    private func folded(_ state: ContextSessionState) -> [RenderItem] {
        ContextPipeline.hideCompressionCalls(
            ContextPipeline.fold(state.messages, blocks: state.blocks), blocks: state.blocks
        )
    }

    /// `folded`, then emergency truncation when a window is known (`windowSize > 0`).
    private func pipelineItems(_ state: ContextSessionState, windowSize: Int) -> [RenderItem] {
        let items = folded(state)
        guard windowSize > 0 else { return items }
        let protected = ContextPipeline.protectedRefs(state.messages, configuration: configuration)
        return ContextPipeline.emergencyTruncate(items, windowSize: windowSize, protected: protected, configuration: configuration)
    }

    private func tokenSum(_ items: [RenderItem]) -> Int {
        items.reduce(0) { $0 + $1.tokens }
    }
}
