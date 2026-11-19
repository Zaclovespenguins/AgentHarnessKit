import AgentHarnessKit
@testable import AgentHarnessKitContext
import Foundation
import Testing

private let quiet = ContextConfiguration(
    protectedRecentMessages: 2, protectedRecentTokens: 1, nudgeFloor: 2.0, doctrine: "DOCTRINE"
)

private let longSummary = String(repeating: "summary ", count: 8)

private func compressCall(_ ranges: [CompressRange], id: String = "k1") throws -> ToolCall {
    struct Arguments: Encodable {
        let ranges: [CompressRange]
    }
    let json = try String(decoding: JSONEncoder().encode(Arguments(ranges: ranges)), as: UTF8.self)
    return ToolCall(id: id, name: "compress", arguments: json)
}

/// 1 system, 2 first user, then user/assistant pairs: user "question i", assistant "answer i".
private func history(pairs: Int) -> [ChatMessage] {
    [.system("sys"), .user("first task")] + (1 ... pairs).flatMap { index -> [ChatMessage] in
        [.user("question \(index)"), .assistant(AssistantMessage(content: "answer \(index)"))]
    }
}

struct HierarchicalContextStoreTests {
    private let session = SessionID()
    private let persistence = InMemoryContextPersistence()

    private func store(
        _ configuration: ContextConfiguration = quiet,
        exportDirectory: URL? = nil
    ) -> HierarchicalContextStore {
        HierarchicalContextStore(
            persistence: persistence,
            configuration: configuration,
            exportDirectory: exportDirectory
        )
    }

    @Test func offersTheFourReservedTools() {
        #expect(Set(store().toolDefinitions.map(\.name)) == ContextToolName.all)
    }

    @Test func missingWindowSizeIsAnError() async {
        await #expect(throws: AgentError.missingContextWindowSize) {
            try await store().render(sessionID: session, messages: [.user("hi")], windowSize: nil)
        }
    }

    @Test func rendersTagsAndDoctrineAndPersistsMessages() async throws {
        let rendered = try await store().render(sessionID: session, messages: history(pairs: 1), windowSize: 100_000)
        #expect(rendered == [
            .system("sys\n\nDOCTRINE"),
            .user("<acp tokens=\"3\" type=\"text\">m00002</acp>\nfirst task"),
            .user("<acp tokens=\"3\" type=\"text\">m00003</acp>\nquestion 1"),
            .assistant(AssistantMessage(content: "answer 1")),
        ])
        let state = try await persistence.load(sessionID: session)
        #expect(state.messages.map(\.message) == history(pairs: 1))
        #expect(state.version == 0)
        #expect(try await store().stateVersion(sessionID: session) == "0")

        let noSystem = SessionID()
        let bare = try await store().render(sessionID: noSystem, messages: [.user("hi")], windowSize: 100_000)
        #expect(bare.first == .system("DOCTRINE"))
    }

    @Test func divergedHistoryFailsClearly() async throws {
        let contextStore = store()
        _ = try await contextStore.render(sessionID: session, messages: history(pairs: 2), windowSize: 100_000)
        var changed = history(pairs: 2)
        changed[3] = .assistant(AssistantMessage(content: "rewritten"))
        await #expect(throws: ContextStoreError.historyDiverged(at: MessageRef(4))) {
            try await contextStore.render(sessionID: session, messages: changed, windowSize: 100_000)
        }
        await #expect(throws: ContextStoreError.historyDiverged(at: MessageRef(4))) {
            try await contextStore.render(
                sessionID: session,
                messages: Array(history(pairs: 2).prefix(3)),
                windowSize: 100_000
            )
        }
    }

    @Test func recordAppendsOnlyUnseenMessagesAndUsage() async throws {
        let contextStore = store()
        let messages = history(pairs: 1)
        _ = try await contextStore.render(sessionID: session, messages: Array(messages.prefix(3)), windowSize: 100_000)
        try await contextStore.record(
            sessionID: session,
            messages: Array(messages.suffix(3)),
            usage: TokenUsage(input: 42, output: 1)
        )
        try await contextStore.record(sessionID: session, messages: [], usage: nil)
        let state = try await persistence.load(sessionID: session)
        #expect(state.messages.map(\.message) == messages)
        #expect(state.lastInputTokens == 42)
    }

    @Test func compressReportsTokensSavedWhenTheSummaryIsShorter() async throws {
        let contextStore = store()
        let bulky = String(repeating: "verbose tool chatter ", count: 50)
        let messages = [ChatMessage.system("sys"), .user("first task")] + (1 ... 6).flatMap { index -> [ChatMessage] in
            [.user("question \(index)"), .assistant(AssistantMessage(content: "answer \(index) \(bulky)"))]
        }
        _ = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        let outcome = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", summary: longSummary)]),
            sessionID: session
        )
        guard case let .contextFolded(fold) = outcome.events.first else {
            Issue.record("expected contextFolded, got \(outcome.events)")
            return
        }
        #expect(fold.tokensSaved > 0)
    }

    @Test func compressFoldsBumpsVersionAndEmitsEvent() async throws {
        let contextStore = store()
        let messages = history(pairs: 6)
        _ = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        let outcome = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", topic: "q1-2", summary: longSummary)]),
            sessionID: session
        )
        #expect(!outcome.result.isError)
        #expect(outcome.result.content.contains("Created b0 (m00003\u{2013}m00006, tier 1)"))
        guard case let .contextFolded(fold) = outcome.events.first else {
            Issue.record("expected contextFolded, got \(outcome.events)")
            return
        }
        #expect(fold.blockIDs == [ContextBlockID("b0")])
        #expect(fold.tokensSaved >= 0)
        #expect(try await contextStore.stateVersion(sessionID: session) == "1")

        let rendered = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        #expect(rendered.count == messages.count - 4 + 1)
        #expect(rendered[2] ==
            .user("[Compressed conversation section b0: m00003\u{2013}m00006]\nTopic: q1-2\n\(longSummary)"))
        #expect(try await contextStore.stateVersion(sessionID: session) == "1")
    }

    @Test func compressMistakesAreModelReadable() async throws {
        let contextStore = store()
        _ = try await contextStore.render(sessionID: session, messages: history(pairs: 3), windowSize: 100_000)
        let badJSON = try await contextStore.executeTool(
            ToolCall(id: "k1", name: "compress", arguments: "{not json"), sessionID: session
        )
        #expect(badJSON.result.isError)
        #expect(badJSON.result.content.contains("Invalid arguments"))
        let rejected = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00002", endRef: "m00004", summary: longSummary)]),
            sessionID: session
        )
        #expect(rejected.result.isError)
        #expect(rejected.result.content.contains("protected"))
        #expect(rejected.events.isEmpty)
        let unknown = try await contextStore.executeTool(
            ToolCall(id: "x", name: "bogus", arguments: "{}"),
            sessionID: session
        )
        #expect(unknown.result.isError)
        #expect(try await contextStore.stateVersion(sessionID: session) == "0")
    }

    @Test func foldIsAppendOnlyAroundTheFoldedRange() async throws {
        let contextStore = store()
        let messages = history(pairs: 8)
        let before = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00005", endRef: "m00008", summary: longSummary)]),
            sessionID: session
        )
        let after = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        #expect(Array(after.prefix(4)) == Array(before.prefix(4)))
        #expect(Array(after.suffix(from: 5)) == Array(before.suffix(from: 8)))
    }

    @Test func decompressRestoresAndDecompressToFileLeavesRenderUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contextStore = store(exportDirectory: directory)
        let messages = history(pairs: 6)
        let original = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)
        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", summary: longSummary)]),
            sessionID: session
        )
        let folded = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000)

        let written = try await contextStore.executeTool(
            ToolCall(id: "d1", name: "decompress", arguments: #"{"blockId":"b0","toFile":"b0.txt"}"#),
            sessionID: session
        )
        #expect(written.result.content == "Wrote b0 (4 messages) to b0.txt")
        #expect(written.events.isEmpty)
        let text = try String(contentsOf: directory.appendingPathComponent("b0.txt"), encoding: .utf8)
        #expect(text.contains("m00004 [assistant]\nanswer 1"))
        #expect(try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000) == folded)
        #expect(try await contextStore.stateVersion(sessionID: session) == "1")

        for bad in ["../b0.txt", "a/b.txt", "..", ""] {
            let arguments = try String(
                decoding: JSONSerialization.data(withJSONObject: ["blockId": "b0", "toFile": bad]),
                as: UTF8.self
            )
            let refused = try await contextStore.executeTool(
                ToolCall(id: "d2", name: "decompress", arguments: arguments), sessionID: session
            )
            #expect(refused.result.isError, "toFile \(bad) must be refused")
        }

        let restored = try await contextStore.executeTool(
            ToolCall(id: "d3", name: "decompress", arguments: #"{"blockId":"b0"}"#), sessionID: session
        )
        #expect(restored.result.content == "Restored b0")
        guard case let .contextRestored(restore) = restored.events.first else {
            Issue.record("expected contextRestored, got \(restored.events)")
            return
        }
        #expect(restore.blockID == ContextBlockID("b0"))
        #expect(try await contextStore.stateVersion(sessionID: session) == "2")
        #expect(try await contextStore.render(sessionID: session, messages: messages, windowSize: 100_000) == original)

        let again = try await contextStore.executeTool(
            ToolCall(id: "d4", name: "decompress", arguments: #"{"blockId":"b0"}"#), sessionID: session
        )
        #expect(again.result.isError)
    }

    @Test func fileExportIsDisabledWithoutADirectory() async throws {
        let contextStore = store()
        _ = try await contextStore.render(sessionID: session, messages: history(pairs: 4), windowSize: 100_000)
        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", summary: longSummary)]),
            sessionID: session
        )
        let refused = try await contextStore.executeTool(
            ToolCall(id: "d1", name: "decompress", arguments: #"{"blockId":"b0","toFile":"b0.txt"}"#),
            sessionID: session
        )
        #expect(refused.result.isError)
    }

    @Test func searchAndStatus() async throws {
        let contextStore = store()
        _ = try await contextStore.render(sessionID: session, messages: history(pairs: 4), windowSize: 50000)
        let found = try await contextStore.executeTool(
            ToolCall(id: "s1", name: "search_context", arguments: #"{"query":"question"}"#), sessionID: session
        )
        #expect(found.result.content.hasPrefix("m00003: "))
        #expect(found.result.content.split(separator: "\n").count == 4)
        let limited = try await contextStore.executeTool(
            ToolCall(id: "s2", name: "search_context", arguments: #"{"query":"question","limit":2}"#),
            sessionID: session
        )
        #expect(limited.result.content.split(separator: "\n").count == 2)
        let huge = SessionID()
        let bigText = "needle " + String(repeating: "line of output\n", count: 500)
        _ = try await contextStore.render(sessionID: huge, messages: [.user(bigText)], windowSize: 100_000)
        let bounded = try await contextStore.executeTool(
            ToolCall(id: "s4", name: "search_context", arguments: #"{"query":"needle"}"#), sessionID: huge
        )
        #expect(!bounded.result.content.contains("\n"))
        #expect(bounded.result.content.count < 400)
        let none = try await contextStore.executeTool(
            ToolCall(id: "s3", name: "search_context", arguments: #"{"query":"giraffe"}"#), sessionID: session
        )
        #expect(none.result.content == "No matches.")

        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", summary: longSummary)]),
            sessionID: session
        )
        let status = try await contextStore.executeTool(
            ToolCall(id: "c1", name: "context_status", arguments: "{}"), sessionID: session
        )
        #expect(!status.result.isError)
        #expect(status.result.content.contains("b0"))
        guard case let .contextStatus(snapshot) = status.events.first else {
            Issue.record("expected contextStatus, got \(status.events)")
            return
        }
        #expect(snapshot.windowSize == 50000)
        #expect(snapshot.blockCount == 1)
        #expect(snapshot.usedTokens > 0)
    }

    @Test func sessionsDoNotShareState() async throws {
        let contextStore = store()
        let other = SessionID()
        _ = try await contextStore.render(sessionID: session, messages: history(pairs: 4), windowSize: 100_000)
        _ = try await contextStore.render(sessionID: other, messages: [.user("other")], windowSize: 100_000)
        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00006", summary: longSummary)]),
            sessionID: session
        )
        #expect(try await contextStore.stateVersion(sessionID: other) == "0")
        #expect(try await persistence.load(sessionID: other).blocks.isEmpty)
    }

    @Test func nudgeIsGatedByFloorAndGrowth() async throws {
        let config = ContextConfiguration(
            protectedRecentMessages: 2, protectedRecentTokens: 1, nudgeFloor: 0.5, nudgeGrowthTokens: 1000,
            doctrine: "D", nudgeText: "NUDGE"
        )
        let contextStore = store(config)
        let messages = history(pairs: 10)
        let first = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100)
        guard case let .user(text) = first.last else {
            Issue.record("expected a nudge, got \(String(describing: first.last))")
            return
        }
        #expect(text.hasPrefix("NUDGE"))
        #expect(text.contains("m00003\u{2013}"))
        let second = try await contextStore.render(sessionID: session, messages: messages, windowSize: 100)
        #expect(second.count == first.count - 1)

        _ = try await contextStore.executeTool(
            compressCall([CompressRange(startRef: "m00003", endRef: "m00010", summary: longSummary)]),
            sessionID: session
        )
        let third = try await contextStore.render(sessionID: session, messages: messages, windowSize: 10000)
        #expect(third.last == .assistant(AssistantMessage(content: "answer 10")))
    }
}

/// Thousands of synthetic messages: a scripted "model" folds everything compressible whenever nudged.
struct LongSessionTests {
    @Test(arguments: [PersistenceKind.inMemory, .grdbQueue])
    func renderedSizeStaysUnderTheWindow(kind: PersistenceKind) async throws {
        let window = 20000
        let turns = kind == .inMemory ? 1500 : 400
        let config = ContextConfiguration(
            protectedRecentMessages: 4,
            protectedRecentTokens: 1000,
            nudgeGrowthTokens: 2000
        )
        let persistence = try kind.make()
        let contextStore = HierarchicalContextStore(persistence: persistence, configuration: config)
        let session = SessionID()
        let filler = String(repeating: "x", count: 400)
        var messages: [ChatMessage] = [.system("You are a test agent."), .user("first task " + filler)]
        var folds = 0
        for turn in 1 ... turns {
            messages.append(.user("step \(turn) " + filler))
            messages.append(.assistant(AssistantMessage(content: "did \(turn) " + filler)))
            let rendered = try await contextStore.render(sessionID: session, messages: messages, windowSize: window)
            let used = rendered.reduce(0) { $0 + ContextTokens.estimate($1) }
            #expect(used < window, "turn \(turn): \(used) tokens")
            guard case let .user(last) = rendered.last, last.hasPrefix(config.nudgeText),
                  let end = last.matches(of: /m(\d+)\u{2013}m(\d+)/).last.flatMap({ Int($0.output.2) })
            else { continue }
            let outcome = try await contextStore.executeTool(
                compressCall([CompressRange(
                    startRef: "m00003", endRef: MessageRef(end).description, topic: "steps",
                    summary: "Steps up to \(MessageRef(end)) done. " + longSummary
                )], id: "k\(turn)"),
                sessionID: session
            )
            #expect(!outcome.result.isError, "turn \(turn): \(outcome.result.content)")
            folds += 1
        }
        #expect(folds > 5)
        #expect(try await contextStore.stateVersion(sessionID: session) == String(folds))
        let state = try await persistence.load(sessionID: session)
        #expect(state.messages.count == messages.count)
        #expect(state.blocks.filter(\.active).count == 1)
        #expect(state.blocks.map(\.tier).max() == 3)
    }
}

/// `compressibleRanges(sessionID:)` and `deleteSession(_:)`: the app-driven fold and chat delete.
struct ContextStoreAppAPITests {
    private let session = SessionID()
    private let persistence = InMemoryContextPersistence()

    private var contextStore: HierarchicalContextStore {
        HierarchicalContextStore(persistence: persistence, configuration: quiet)
    }

    /// m1 system, m2 first user, tool turns, a context-tool call at m8–m9, then m15–m16 as the recent zone.
    private let scripted: [ChatMessage] = [
        .system("sys"),
        .user("first task"),
        .user("question 1"),
        assistantCalling(call("c1", "bash", #"{"cmd":"ls"}"#)),
        .tool(id: "c1", name: "bash", content: "file.txt"),
        .assistant(AssistantMessage(content: "answer 1")),
        .user("question 2"),
        assistantCalling(call("s1", ContextToolName.contextStatus)),
        .tool(id: "s1", name: ContextToolName.contextStatus, content: "status"),
        .assistant(AssistantMessage(content: "answer 2")),
        .user("question 3"),
        assistantCalling(call("c2", "bash", #"{"cmd":"pwd"}"#)),
        .tool(id: "c2", name: "bash", content: "/tmp"),
        .assistant(AssistantMessage(content: "answer 3")),
        .user("last question"),
        .assistant(AssistantMessage(content: "final answer")),
    ]

    private func fold(_ ranges: [CompressibleRange], id: String) throws -> ToolCall {
        try compressCall(
            ranges.map { CompressRange(startRef: $0.startRef.description, endRef: $0.endRef.description,
                                       summary: longSummary) },
            id: id
        )
    }

    @Test func emptySessionHasNoRanges() async throws {
        #expect(try await contextStore.compressibleRanges(sessionID: session).isEmpty)
    }

    @Test func matchesThePipelineAndSkipsProtectedRefs() async throws {
        let store = contextStore
        _ = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        let ranges = try await store.compressibleRanges(sessionID: session)
        #expect(ranges.map { $0.startRef ... $0.endRef } == [ref(3) ... ref(7), ref(10) ... ref(14)])

        let state = try await persistence.load(sessionID: session)
        let protected = ContextPipeline.protectedRefs(state.messages, configuration: quiet)
        let expected = ContextPipeline.compressibleRanges(state.messages, blocks: state.blocks, protected: protected)
            .map { range in
                let covered = state.messages.filter { range.contains($0.ref) }
                return CompressibleRange(
                    startRef: range.lowerBound, endRef: range.upperBound,
                    messages: covered.map(\.message), tokens: covered.reduce(0) { $0 + $1.tokens }
                )
            }
        #expect(ranges == expected)
        #expect(ranges[0].messages == Array(scripted[2 ... 6]))

        let returned = Set(state.messages.map(\.ref).filter { ref in
            ranges.contains { ($0.startRef ... $0.endRef).contains(ref) }
        })
        // System, first and last user, the context-tool call and result, and the recent zone.
        #expect(returned.isDisjoint(with: [ref(1), ref(2), ref(8), ref(9), ref(15), ref(16)]))
    }

    @Test func isReadOnly() async throws {
        let store = contextStore
        _ = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        let firstRange = try #require(try await store.compressibleRanges(sessionID: session).first)
        _ = try await store.executeTool(fold([firstRange], id: "k1"), sessionID: session)
        let before = try await persistence.load(sessionID: session)
        _ = try await store.compressibleRanges(sessionID: session)
        _ = try await store.compressibleRanges(sessionID: session)
        let after = try await persistence.load(sessionID: session)
        #expect(after == before)
        #expect(after.version == 1)
        #expect(after.blocks.map(\.survivedCount) == before.blocks.map(\.survivedCount))
    }

    @Test func everyRangeRoundTripsThroughCompress() async throws {
        let store = contextStore
        _ = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        let ranges = try await store.compressibleRanges(sessionID: session)
        let outcome = try await store.executeTool(fold(ranges, id: "app-fold-1"), sessionID: session)
        #expect(!outcome.result.isError)
        #expect(outcome.result.content.split(separator: "\n").allSatisfy { $0.hasPrefix("Created ") })
        let state = try await persistence.load(sessionID: session)
        #expect(state.blocks.count == ranges.count)
        #expect(state.blocks.allSatisfy { $0.createdByCallID == "app-fold-1" })
        // Folded refs are no longer offered.
        #expect(try await store.compressibleRanges(sessionID: session).isEmpty)
    }

    @Test func appMadeCallIDRendersLikeAModelFold() async throws {
        let modelSession = SessionID()
        let store = contextStore
        for id in [session, modelSession] {
            _ = try await store.render(sessionID: id, messages: scripted, windowSize: 100_000)
        }
        let unfolded = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        let ranges = try await store.compressibleRanges(sessionID: session)
        _ = try await store.executeTool(fold(ranges, id: "app-fold-2"), sessionID: session)
        _ = try await store.executeTool(fold(ranges, id: "k1"), sessionID: modelSession)

        let appRender = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        let modelRender = try await store.render(sessionID: modelSession, messages: scripted, windowSize: 100_000)
        #expect(appRender == modelRender)
        #expect(appRender.count == unfolded.count - 10 + 2)

        // Once the block is inactive, hideCompressionCalls looks for the app id in history, finds nothing, and
        // the next turn renders exactly as before the fold.
        _ = try await store.executeTool(
            ToolCall(id: "d1", name: ContextToolName.decompress, arguments: #"{"blockId":"b0"}"#),
            sessionID: session
        )
        _ = try await store.executeTool(
            ToolCall(id: "d2", name: ContextToolName.decompress, arguments: #"{"blockId":"b1"}"#),
            sessionID: session
        )
        #expect(try await store.render(sessionID: session, messages: scripted, windowSize: 100_000) == unfolded)
    }

    @Test func deleteSessionLetsAFreshHistoryRender() async throws {
        let store = contextStore
        _ = try await store.render(sessionID: session, messages: scripted, windowSize: 100_000)
        try await store.deleteSession(session)
        #expect(try await persistence.load(sessionID: session) == ContextSessionState())

        let fresh: [ChatMessage] = [.system("sys"), .user("a different chat")]
        _ = try await store.render(sessionID: session, messages: fresh, windowSize: 100_000)
        #expect(try await persistence.load(sessionID: session).messages.map(\.message) == fresh)

        try await store.deleteSession(session)
        let status = try await store.executeTool(
            ToolCall(id: "s", name: ContextToolName.contextStatus, arguments: "{}"), sessionID: session
        )
        guard case let .contextStatus(snapshot) = status.events.first else {
            Issue.record("expected contextStatus, got \(status.events)")
            return
        }
        #expect(snapshot.windowSize == 0)
    }
}
