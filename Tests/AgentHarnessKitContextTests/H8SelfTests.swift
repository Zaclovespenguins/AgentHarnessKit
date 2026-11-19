import AgentHarnessKit
@testable import AgentHarnessKitContext
import Foundation
import Testing

private let longSummary = String(repeating: "Keep the objective and the file paths. ", count: 3)

private func conversation(_ count: Int) -> [ChatMessage] {
    (0 ..< count).map { index in
        index.isMultiple(of: 2)
            ? .user("question \(index) " + String(repeating: "padding ", count: 400))
            : .assistant(AssistantMessage(content: "answer \(index)"))
    }
}

@Test func renderRejectsDivergedHistoryAndAppendsNewMessages() async throws {
    let store = HierarchicalContextStore(persistence: InMemoryContextPersistence())
    let session = SessionID()
    let first = conversation(4)
    _ = try await store.render(sessionID: session, messages: first, windowSize: 100_000)

    var changed = first
    changed[1] = .assistant(AssistantMessage(content: "different"))
    await #expect(throws: ContextStoreError.historyDiverged(at: MessageRef(2))) {
        _ = try await store.render(sessionID: session, messages: changed, windowSize: 100_000)
    }
    await #expect(throws: ContextStoreError.historyDiverged(at: MessageRef(4))) {
        _ = try await store.render(sessionID: session, messages: Array(first.prefix(3)), windowSize: 100_000)
    }
}

@Test func doctrineIsInsertedAndVersionStartsAtZero() async throws {
    let store = HierarchicalContextStore(persistence: InMemoryContextPersistence())
    let session = SessionID()
    let rendered = try await store.render(sessionID: session, messages: [.user("hi")], windowSize: 100_000)
    #expect(rendered.first == .system(ContextConfiguration().doctrine))
    #expect(try await store.stateVersion(sessionID: session) == "0")
}

@Test func compressFoldsRangeAndReportsCreatedBlock() async throws {
    let store = HierarchicalContextStore(persistence: InMemoryContextPersistence())
    let session = SessionID()
    let messages = conversation(30)
    try await store.record(sessionID: session, messages: messages, usage: nil)
    _ = try await store.render(sessionID: session, messages: messages, windowSize: 100_000)

    let arguments = #"{"ranges":[{"startRef":"m00002","endRef":"m00004","summary":"\#(longSummary)"}]}"#
    let call = ToolCall(id: "c1", name: ContextToolName.compress, arguments: arguments)
    let outcome = try await store.executeTool(call, sessionID: session)
    #expect(!outcome.result.isError)
    #expect(outcome.result.content == "Created b0 (m00002\u{2013}m00004, tier 1)")
    #expect(outcome.events.count == 1)
    #expect(try await store.stateVersion(sessionID: session) == "1")

    let restore = ToolCall(id: "c2", name: ContextToolName.decompress, arguments: #"{"blockId":"b0"}"#)
    let restored = try await store.executeTool(restore, sessionID: session)
    #expect(restored.result.content == "Restored b0")
    #expect(try await store.stateVersion(sessionID: session) == "2")
}

@Test func toFileRejectsPathsAndDisabledExport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("h8-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = InMemoryContextPersistence()
    let store = HierarchicalContextStore(persistence: persistence, exportDirectory: directory)
    let session = SessionID()
    let messages = conversation(30)
    try await store.record(sessionID: session, messages: messages, usage: nil)
    _ = try await store.render(sessionID: session, messages: messages, windowSize: 100_000)
    let compress = ToolCall(
        id: "c1",
        name: ContextToolName.compress,
        arguments: #"{"ranges":[{"startRef":"m00002","endRef":"m00004","summary":"\#(longSummary)"}]}"#
    )
    let created = try await store.executeTool(compress, sessionID: session)
    #expect(!created.result.isError)

    // Escaped in the JSON text, "a\\\\b" decodes to a single backslash.
    for name in ["", ".", "..", "a/b", "a\\\\b"] {
        let call = ToolCall(
            id: "d",
            name: ContextToolName.decompress,
            arguments: #"{"blockId":"b0","toFile":"\#(name)"}"#
        )
        let outcome = try await store.executeTool(call, sessionID: session)
        #expect(outcome.result.isError)
        #expect(outcome.result.content == "Invalid arguments: toFile must be a plain file name")
    }

    let disabled = HierarchicalContextStore(persistence: persistence)
    let plain = ToolCall(
        id: "d",
        name: ContextToolName.decompress,
        arguments: #"{"blockId":"b0","toFile":"ok.txt"}"#
    )
    let disabledOutcome = try await disabled.executeTool(plain, sessionID: session)
    #expect(disabledOutcome.result.content == "Invalid arguments: file export is disabled")

    let bad = ToolCall(id: "d", name: ContextToolName.decompress, arguments: "not json")
    #expect(try await store.executeTool(bad, sessionID: session).result.isError)
}

@Test func searchWithoutHitsSaysNoMatches() async throws {
    let store = HierarchicalContextStore(persistence: InMemoryContextPersistence())
    let call = ToolCall(id: "s", name: ContextToolName.searchContext, arguments: #"{"query":"nothing"}"#)
    let outcome = try await store.executeTool(call, sessionID: SessionID())
    #expect(outcome.result.content == "No matches.")
    #expect(!outcome.result.isError)
}
