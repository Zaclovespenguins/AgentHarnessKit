@testable import AgentHarnessKit
import Foundation
import Testing

private func fixedDate(millisecondsSince1970: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1000)
}

private func uuid(_ string: String) throws -> UUID {
    try #require(UUID(uuidString: string))
}

struct StreamEventWireFormatTests {
    @Test func legacyFinishedEventPreservesPartialAccounting() throws {
        let archive = [
            #"{"id":"00000000-0000-0000-0000-000000000101","#,
            #""kind":{"content":"Done.","history":[],"#,
            #""reason":{"type":"completed"},"#,
            #""tokenUsage":{"input":100,"output":50,"reasoning":0},"#,
            #""type":"finished"},"#,
            #""runID":"66666666-7777-8888-9999-AAAAAAAAAAAA","#,
            #""sessionID":"11111111-2222-3333-4444-555555555555","#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        let decoded = try StreamEventJSONCodec.decode(Data(archive.utf8))
        #expect(try decoded.id == EventID(rawValue: uuid("00000000-0000-0000-0000-000000000101")))
        #expect(decoded.timestamp == fixedDate(millisecondsSince1970: 1_774_880_527_123))
        #expect(try decoded.sessionID == SessionID(rawValue: uuid("11111111-2222-3333-4444-555555555555")))
        #expect(try decoded.runID == RunID(rawValue: uuid("66666666-7777-8888-9999-AAAAAAAAAAAA")))
        guard case let .finished(usage, content, reason, history) = decoded.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(usage.input == 100)
        #expect(usage.output == 50)
        #expect(usage.coverage == .partial)
        #expect(usage.cacheReadCoverage == .unavailable)
        #expect(usage.cacheWriteCoverage == .unavailable)
        #expect(content == "Done.")
        #expect(reason == .completed)
        #expect(history.isEmpty)
    }

    @Test func finishedEventWithAccountingFixtureIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000101")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            sessionID: SessionID(rawValue: uuid("11111111-2222-3333-4444-555555555555")),
            runID: RunID(rawValue: uuid("66666666-7777-8888-9999-AAAAAAAAAAAA")),
            kind: .finished(
                tokenUsage: makeTokenUsageTotals(TokenUsage(input: 100, output: 50)),
                content: "Done.",
                reason: .completed,
                history: []
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))

        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000101","#,
            #""kind":{"content":"Done.","history":[],"#,
            #""reason":{"type":"completed"},"#,
            #""tokenUsage":{"accounting":{"cacheRead":"unavailable","cacheWrite":"unavailable","#,
            #""type":"observed","usage":"complete"},"input":100,"output":50,"reasoning":0},"#,
            #""type":"finished"},"#,
            #""runID":"66666666-7777-8888-9999-AAAAAAAAAAAA","#,
            #""sessionID":"11111111-2222-3333-4444-555555555555","#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        #expect(string == expected)

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(decoded.sessionID == event.sessionID)
        #expect(decoded.runID == event.runID)
        #expect(decoded.kind == event.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func recursiveSubAgentEventFixtureIsStable() throws {
        let childEvent = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000202")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_456),
            kind: .delta("inner content")
        )
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000201")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .subAgentEvent(
                toolCallId: "tc_sub",
                toolName: "research",
                event: childEvent
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))
        let expected = [
            "{\"id\":\"00000000-0000-0000-0000-000000000201\",",
            "\"kind\":{\"event\":{\"id\":\"00000000-0000-0000-0000-",
            "000000000202\",\"kind\":{\"text\":\"inner content\",",
            "\"type\":\"delta\"},\"timestamp\":\"2026-03-30T14:",
            "22:07.456Z\"},\"toolCallId\":\"tc_sub\",",
            "\"toolName\":\"research\",\"type\":\"subAgentEvent\"",
            "},\"timestamp\":\"2026-03-30T14:22:07.123Z\"}",
        ].joined()

        #expect(
            string == expected
        )

        let decoded = try StreamEventJSONCodec.decode(data)
        guard case let .subAgentEvent(toolCallId, toolName, nestedEvent) = decoded.kind else {
            Issue.record("Expected subAgentEvent, got \(decoded.kind)")
            return
        }
        #expect(toolCallId == "tc_sub")
        #expect(toolName == "research")
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(nestedEvent.id == childEvent.id)
        #expect(nestedEvent.timestamp == childEvent.timestamp)
        #expect(nestedEvent.kind == childEvent.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func legacyStructuralFinishedEventPreservesPartialAccounting() throws {
        let archive = [
            #"{"id":"00000000-0000-0000-0000-000000000301","#,
            #""kind":{"history":[],"#,
            #""reason":{"limit":3,"type":"maxIterationsReached"},"#,
            #""tokenUsage":{"input":80,"output":20,"reasoning":0},"#,
            #""type":"finished"},"#,
            #""timestamp":"2026-03-30T14:22:08.123Z"}"#,
        ].joined()
        let decoded = try StreamEventJSONCodec.decode(Data(archive.utf8))
        guard case let .finished(usage, content, reason, history) = decoded.kind else {
            Issue.record("Expected finished event")
            return
        }
        #expect(usage.input == 80)
        #expect(usage.output == 20)
        #expect(usage.coverage == .partial)
        #expect(content == nil)
        #expect(reason == .maxIterationsReached(limit: 3))
        #expect(history.isEmpty)
    }

    @Test func iterationCompletedWithHistoryFixtureIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000401")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .iterationCompleted(
                usage: TokenUsage(input: 10, output: 5),
                iteration: 1,
                history: [.user("Hi")]
            )
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000401","#,
            #""kind":{"history":[{"content":"Hi","role":"user"}],"#,
            #""iteration":1,"#,
            #""type":"iterationCompleted","#,
            #""usage":{"input":10,"output":5,"reasoning":0}},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        #expect(string == expected)

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.kind == event.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func iterationCompletedV1ArchiveDecodesAsEmptyHistory() throws {
        let v1Archive = [
            #"{"id":"00000000-0000-0000-0000-000000000401","#,
            #""kind":{"iteration":1,"#,
            #""type":"iterationCompleted","#,
            #""usage":{"input":10,"output":5,"reasoning":0}},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        let data = try #require(v1Archive.data(using: .utf8))

        let decoded = try StreamEventJSONCodec.decode(data)
        guard case let .iterationCompleted(usage, iteration, history) = decoded.kind else {
            Issue.record("Expected iterationCompleted kind, got \(decoded.kind)")
            return
        }
        #expect(usage == TokenUsage(input: 10, output: 5))
        #expect(iteration == 1)
        #expect(history.isEmpty)
    }

    @Test func iterationCompletedWithoutUsageFixtureIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000402")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .iterationCompleted(usage: nil, iteration: 2, history: [.user("Hi")])
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000402","#,
            #""kind":{"history":[{"content":"Hi","role":"user"}],"#,
            #""iteration":2,"type":"iterationCompleted"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()

        #expect(try StreamEventJSONCodec.encode(event) == Data(expected.utf8))
        let decoded = try StreamEventJSONCodec.decode(Data(expected.utf8))
        #expect(decoded.kind == event.kind)
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
    }

    @Test(arguments: [
        #"{"iteration":2,"type":"iterationCompleted"}"#,
        #"{"iteration":2,"type":"iterationCompleted","usage":null}"#,
    ])
    func iterationCompletedDecodesUnavailableUsage(archive: String) throws {
        let decoded = try StreamEventJSONCodec.makeDecoder().decode(StreamEvent.Kind.self, from: Data(archive.utf8))
        #expect(decoded == .iterationCompleted(usage: nil, iteration: 2, history: []))
        #expect(decoded != .iterationCompleted(usage: TokenUsage(), iteration: 2, history: []))
    }

    @Test(arguments: [
        #"{"iteration":2,"type":"iterationCompleted","history":null}"#,
        #"{"iteration":2,"type":"iterationCompleted","history":{}}"#,
        #"{"iteration":2,"type":"iterationCompleted","usage":"unavailable"}"#,
        #"{"iteration":2,"type":"iterationCompleted","usage":{}}"#,
    ])
    func iterationCompletedRejectsMalformedPayload(archive: String) throws {
        #expect(throws: DecodingError.self) {
            try StreamEventJSONCodec.makeDecoder().decode(StreamEvent.Kind.self, from: Data(archive.utf8))
        }
    }

    @Test func replayedOriginRoundTripsWithCheckpointID() throws {
        let checkpointID = try CheckpointID(rawValue: uuid("00000000-0000-0000-0000-000000000501"))
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000502")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_529_123),
            origin: .replayed(from: checkpointID),
            kind: .delta("x")
        )

        let data = try StreamEventJSONCodec.encode(event)
        let string = try #require(String(data: data, encoding: .utf8))
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000502","#,
            #""kind":{"text":"x","type":"delta"},"#,
            #""origin":{"from":"00000000-0000-0000-0000-000000000501","type":"replayed"},"#,
            #""timestamp":"2026-03-30T14:22:09.123Z"}"#,
        ].joined()
        #expect(string == expected)

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(decoded.origin == event.origin)
        #expect(decoded.kind == event.kind)

        let reencoded = try StreamEventJSONCodec.encode(decoded)
        let reencodedString = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedString == string)
    }

    @Test func envelopeV1ArchiveWithoutOriginDecodesAsLive() throws {
        let v1Archive = [
            #"{"id":"00000000-0000-0000-0000-000000000503","#,
            #""kind":{"text":"x","type":"delta"},"#,
            #""timestamp":"2026-03-30T14:22:09.123Z"}"#,
        ].joined()
        let data = try #require(v1Archive.data(using: .utf8))

        let decoded = try StreamEventJSONCodec.decode(data)
        #expect(decoded.origin == .live)
        #expect(decoded.kind == .delta("x"))
    }
}

/// Golden wire shapes for every event kind, so a symmetric key rename can't slip through a round trip.
struct StreamEventKindWireShapeTests {
    private func expectGoldenWireFormat(_ event: StreamEvent, _ expected: String) throws {
        let data = try StreamEventJSONCodec.encode(event)
        #expect(String(data: data, encoding: .utf8) == expected)

        let decoded = try StreamEventJSONCodec.decode(Data(expected.utf8))
        #expect(decoded.id == event.id)
        #expect(decoded.timestamp == event.timestamp)
        #expect(decoded.kind == event.kind)
        #expect(try StreamEventJSONCodec.encode(decoded) == Data(expected.utf8))
    }

    @Test func toolCallStartedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000701")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .toolCallStarted(name: "search", id: "tc_001")
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000701","#,
            #""kind":{"id":"tc_001","name":"search","type":"toolCallStarted"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func toolCallCompletedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000702")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .toolCallCompleted(id: "tc_001", name: "search", result: ToolResult(content: "42 results found"))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000702","#,
            #""kind":{"id":"tc_001","name":"search","#,
            #""result":{"content":"42 results found","isError":false},"#,
            #""type":"toolCallCompleted"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func audioDataWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000703")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .audioData(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000703","#,
            #""kind":{"data":"3q2+7w==","type":"audioData"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func audioTranscriptWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000704")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .audioTranscript("Hello from audio")
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000704","#,
            #""kind":{"text":"Hello from audio","type":"audioTranscript"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func audioFinishedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000705")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .audioFinished(id: "audio_001", expiresAt: 1_711_800_000, data: Data([0x01, 0x02, 0x03]))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000705","#,
            #""kind":{"data":"AQID","expiresAt":1711800000,"id":"audio_001","type":"audioFinished"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func subAgentStartedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000706")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .subAgentStarted(toolCallId: "tc_sub", toolName: "research")
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000706","#,
            #""kind":{"toolCallId":"tc_sub","toolName":"research","type":"subAgentStarted"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func subAgentCompletedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000707")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .subAgentCompleted(
                toolCallId: "tc_sub",
                toolName: "research",
                result: ToolResult(content: "sub-agent result")
            )
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000707","#,
            #""kind":{"result":{"content":"sub-agent result","isError":false},"#,
            #""toolCallId":"tc_sub","toolName":"research","type":"subAgentCompleted"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func contextFoldedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000708")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .contextFolded(ContextFold(blockIDs: [ContextBlockID("b1"), ContextBlockID("b2")], tokensSaved: 5000))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000708","#,
            #""kind":{"context":{"blockIDs":["b1","b2"],"tokensSaved":5000},"type":"contextFolded"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func contextStatusWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000709")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .contextStatus(ContextStatus(windowSize: 8192, usedTokens: 5000, blockCount: 2))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000709","#,
            #""kind":{"context":{"blockCount":2,"usedTokens":5000,"windowSize":8192},"type":"contextStatus"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func toolApprovalRequestedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000710")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .toolApprovalRequested(ToolApprovalRequest(
                toolCallId: "tc_1",
                toolName: "delete_file",
                arguments: #"{"city":"Layton"}"#,
                toolDescription: "Deletes a file"
            ))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000710","#,
            #""kind":{"request":{"arguments":"{\"city\":\"Layton\"}","toolCallId":"tc_1","#,
            #""toolDescription":"Deletes a file","toolName":"delete_file"},"#,
            #""type":"toolApprovalRequested"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func toolApprovalResolvedWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000711")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .toolApprovalResolved(toolCallId: "tc_1", decision: .deny(reason: "too risky"))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000711","#,
            #""kind":{"decision":{"reason":"too risky","type":"deny"},"#,
            #""toolCallId":"tc_1","type":"toolApprovalResolved"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func reasoningDeltaWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000712")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .reasoningDelta("Thinking out loud")
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000712","#,
            #""kind":{"text":"Thinking out loud","type":"reasoningDelta"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }

    @Test func contextRestoredWireShapeIsStable() throws {
        let event = try StreamEvent(
            id: EventID(rawValue: uuid("00000000-0000-0000-0000-000000000713")),
            timestamp: fixedDate(millisecondsSince1970: 1_774_880_527_123),
            kind: .contextRestored(ContextRestore(blockID: ContextBlockID("b1"), tokensRestored: 1200))
        )
        let expected = [
            #"{"id":"00000000-0000-0000-0000-000000000713","#,
            #""kind":{"context":{"blockID":"b1","tokensRestored":1200},"type":"contextRestored"},"#,
            #""timestamp":"2026-03-30T14:22:07.123Z"}"#,
        ].joined()
        try expectGoldenWireFormat(event, expected)
    }
}
