import AgentHarnessKit
@testable import AgentHarnessKitContext
import Foundation
import Testing

private func sampleState() -> ContextSessionState {
    let messages = [
        StoredMessage(ref: MessageRef(1), message: .user("The quick brown fox, zebra!"), tokens: 7),
        StoredMessage(ref: MessageRef(2), message: .assistant(AssistantMessage(
            content: "a lazy dog", toolCalls: [ToolCall(id: "c1", name: "bash", arguments: "{\"cmd\":\"ls\"}")]
        )), tokens: 9),
        StoredMessage(ref: MessageRef(3), message: .tool(id: "c1", name: "bash", content: "zebra crossing"), tokens: 4),
    ]
    let folded = ContextBlock(
        id: ContextBlockID("b0"), tier: 1, topic: "fox", summary: "The fox jumped over the zebra.",
        directMessageRefs: [MessageRef(1), MessageRef(2)], effectiveMessageRefs: [MessageRef(1), MessageRef(2)],
        createdByCallID: "compress-1"
    )
    let outer = ContextBlock(
        id: ContextBlockID("b1"), tier: 2, topic: "outer", summary: "Zebra summary two.",
        directMessageRefs: [MessageRef(3)], directBlockIDs: [ContextBlockID("b0")],
        effectiveMessageRefs: [MessageRef(1), MessageRef(2), MessageRef(3)],
        active: true, generation: .old, survivedCount: 4
    )
    let archived = ContextBlock(
        id: ContextBlockID("b2"), tier: 1, topic: "old", summary: "Zebra archived.",
        directMessageRefs: [], effectiveMessageRefs: [], active: false
    )
    return ContextSessionState(
        messages: messages, blocks: [folded, outer, archived], nextBlockOrdinal: 3,
        nudgeBaseline: 1200, lastInputTokens: 900, version: 5
    )
}

private func stores() throws -> [any ContextPersistence] {
    try [InMemoryContextPersistence(), GRDBContextPersistence()]
}

@Test func roundTripAndUnknownSessionAreIdenticalAcrossStores() async throws {
    let session = SessionID()
    for store in try stores() {
        #expect(try await store.load(sessionID: session) == ContextSessionState())
        try await store.save(sessionID: session, state: sampleState())
        #expect(try await store.load(sessionID: session) == sampleState())
    }
}

@Test func appendOnlyRulesThrowTheDocumentedErrors() async throws {
    let session = SessionID()
    for store in try stores() {
        try await store.save(sessionID: session, state: sampleState())
        var shorter = sampleState()
        shorter.messages.removeLast()
        await #expect(throws: ContextPersistenceError.messagesRemoved(saved: 3, given: 2)) {
            try await store.save(sessionID: session, state: shorter)
        }
        var rewritten = sampleState()
        rewritten.messages[1] = StoredMessage(ref: MessageRef(2), message: .user("changed"), tokens: 9)
        await #expect(throws: ContextPersistenceError.messageRewritten(MessageRef(2))) {
            try await store.save(sessionID: session, state: rewritten)
        }
    }
}

@Test func searchMatchesAcrossStoresAndSkipsInactiveBlocks() async throws {
    let session = SessionID()
    for store in try stores() {
        try await store.save(sessionID: session, state: sampleState())
        let hits = try await store.search(sessionID: session, query: "ZEBRA", limit: 10)
        #expect(hits == [
            ContextSearchHit(source: .block(ContextBlockID("b0")), snippet: "The fox jumped over the zebra."),
            ContextSearchHit(source: .block(ContextBlockID("b1")), snippet: "Zebra summary two."),
            ContextSearchHit(source: .message(MessageRef(1)), snippet: "The quick brown fox, zebra!"),
            ContextSearchHit(source: .message(MessageRef(3)), snippet: "zebra crossing"),
        ])
        #expect(try await store.search(sessionID: session, query: "archived", limit: 10).isEmpty)
        #expect(try await store.search(sessionID: session, query: "  \"!!\" ", limit: 10).isEmpty)
        #expect(try await store.search(sessionID: session, query: "zebra", limit: 1).count == 1)
    }
}

@Test func sessionsAreIsolatedInOneDatabase() async throws {
    let first = SessionID()
    let second = SessionID()
    let store = try GRDBContextPersistence()
    try await store.save(sessionID: first, state: sampleState())
    #expect(try await store.load(sessionID: second) == ContextSessionState())
    #expect(try await store.search(sessionID: second, query: "zebra", limit: 10).isEmpty)
}

@Test func fileDatabaseSurvivesReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("h6-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = SessionID()
    try await GRDBContextPersistence(directory: directory).save(sessionID: session, state: sampleState())
    #expect(try await GRDBContextPersistence(directory: directory).load(sessionID: session) == sampleState())
}
