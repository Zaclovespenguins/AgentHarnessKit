import AgentHarnessKit
@testable import AgentHarnessKitContext
import Foundation
import Testing

enum PersistenceKind: String, CaseIterable, CustomTestStringConvertible {
    case inMemory, grdbQueue

    var testDescription: String {
        rawValue
    }

    func make() throws -> any ContextPersistence {
        switch self {
        case .inMemory: InMemoryContextPersistence()
        case .grdbQueue: try GRDBContextPersistence()
        }
    }
}

@Suite("Context persistence (H6)")
struct PersistenceTests {
    private let session = SessionID()

    private var sampleState: ContextSessionState {
        let messages = stored([
            .system("sys"),
            .user("the zebra crossed the road"),
            .assistant(AssistantMessage(
                content: "looking", toolCalls: [call("c1", "bash", #"{"cmd":"ls"}"#)],
                tokenUsage: TokenUsage(input: 12, output: 3)
            )),
            .tool(id: "c1", name: "bash", content: "a ZEBRA again"),
            .userMultimodal([.text("see image"), .imageURL("https://example.com/i.png")]),
        ], tokens: [1, 7, 9, 4, 260])
        var old = block(0, covering: refs(2 ... 3), active: false, topic: "zebra old", summary: "zebra archived")
        old.survivedCount = 6
        old.generation = .old
        let tierTwo = block(
            1, tier: 2, covering: refs(2 ... 4), direct: [ref(4)], sources: [0],
            topic: "t", summary: "zebra summary here", callID: "k1"
        )
        return ContextSessionState(
            messages: messages, blocks: [old, tierTwo], nextBlockOrdinal: 2,
            nudgeBaseline: 4500, lastInputTokens: 6000, version: 3
        )
    }

    @Test(arguments: PersistenceKind.allCases)
    func unknownSessionLoadsEmpty(kind: PersistenceKind) async throws {
        #expect(try await kind.make().load(sessionID: session) == ContextSessionState())
    }

    @Test(arguments: PersistenceKind.allCases)
    func roundTripsEveryField(kind: PersistenceKind) async throws {
        let store = try kind.make()
        try await store.save(sessionID: session, state: sampleState)
        #expect(try await store.load(sessionID: session) == sampleState)
    }

    @Test(arguments: PersistenceKind.allCases)
    func appendsMessagesAndUpdatesBlocks(kind: PersistenceKind) async throws {
        let store = try kind.make()
        var state = sampleState
        try await store.save(sessionID: session, state: state)
        try await store.save(sessionID: session, state: state)
        state.messages += stored(Array(repeating: .user("more"), count: 7)).dropFirst(5)
        state.blocks[1].active = false
        state.blocks.append(block(2, tier: 3, covering: refs(2 ... 6), direct: refs(5 ... 6), sources: [1]))
        state.nextBlockOrdinal = 3
        state.nudgeBaseline = nil
        state.version = 4
        try await store.save(sessionID: session, state: state)
        #expect(try await store.load(sessionID: session) == state)
    }

    @Test(arguments: PersistenceKind.allCases)
    func messagesAreAppendOnly(kind: PersistenceKind) async throws {
        let store = try kind.make()
        try await store.save(sessionID: session, state: sampleState)
        var rewritten = sampleState
        rewritten.messages[1] = StoredMessage(ref: ref(2), message: .user("changed"), tokens: 7)
        await #expect(throws: ContextPersistenceError.messageRewritten(ref(2))) {
            try await store.save(sessionID: session, state: rewritten)
        }
        var shorter = sampleState
        shorter.messages.removeLast(2)
        await #expect(throws: ContextPersistenceError.messagesRemoved(saved: 5, given: 3)) {
            try await store.save(sessionID: session, state: shorter)
        }
    }

    @Test(arguments: PersistenceKind.allCases)
    func sessionsAreIsolated(kind: PersistenceKind) async throws {
        let store = try kind.make()
        let other = SessionID()
        try await store.save(sessionID: session, state: sampleState)
        let otherState = ContextSessionState(messages: stored([.user("unrelated giraffe")]), version: 1)
        try await store.save(sessionID: other, state: otherState)
        #expect(try await store.load(sessionID: other) == otherState)
        #expect(try await store.load(sessionID: session) == sampleState)
        #expect(try await store.search(sessionID: other, query: "zebra", limit: 10).isEmpty)
        #expect(try await store.search(sessionID: session, query: "giraffe", limit: 10).isEmpty)
    }

    @Test(arguments: PersistenceKind.allCases)
    func searchOrderAndScope(kind: PersistenceKind) async throws {
        let store = try kind.make()
        try await store.save(sessionID: session, state: sampleState)
        let hits = try await store.search(sessionID: session, query: "Zebra", limit: 10)
        #expect(hits.map(\.source) == [.block(ContextBlockID("b1")), .message(ref(2)), .message(ref(4))])
        #expect(hits.allSatisfy { !$0.snippet.isEmpty })
        #expect(try await store.search(sessionID: session, query: "zebra crossed", limit: 10).map(\.source)
            == [.message(ref(2))])
        #expect(try await store.search(sessionID: session, query: "zebra", limit: 2).count == 2)
        #expect(try await store.search(sessionID: session, query: "zeb", limit: 10).isEmpty)
        #expect(try await store.search(sessionID: session, query: "  ", limit: 10).isEmpty)
        _ = try await store.search(sessionID: session, query: #"(zebra" OR"#, limit: 10)
    }

    @Test func fileDatabaseIsReopenedByASecondInstance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await GRDBContextPersistence(directory: directory).save(sessionID: session, state: sampleState)
        let reopened = try GRDBContextPersistence(directory: directory)
        #expect(try await reopened.load(sessionID: session) == sampleState)
        #expect(try await reopened.search(sessionID: session, query: "crossed", limit: 5).map(\.source) == [.message(ref(2))])
    }
}
