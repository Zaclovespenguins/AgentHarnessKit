@testable import AgentHarnessKit
import Foundation
import Testing

struct StreamEventKindCodableTests {
    private func roundTrip(_ kind: StreamEvent.Kind) throws -> StreamEvent.Kind {
        let event = StreamEvent(kind: kind)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
        return decoded.kind
    }

    @Test func deltaRoundTrips() throws {
        let kind = StreamEvent.Kind.delta("Hello, world!")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func reasoningDeltaRoundTrips() throws {
        let kind = StreamEvent.Kind.reasoningDelta("Let me think...")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolCallStartedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolCallStarted(name: "search", id: "tc_001")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolCallCompletedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolCallCompleted(
            id: "tc_001",
            name: "search",
            result: ToolResult(content: "42 results found")
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioDataRoundTrips() throws {
        let kind = StreamEvent.Kind.audioData(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioTranscriptRoundTrips() throws {
        let kind = StreamEvent.Kind.audioTranscript("Hello from audio")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func audioFinishedRoundTrips() throws {
        let kind = StreamEvent.Kind.audioFinished(
            id: "audio_001",
            expiresAt: 1_711_800_000,
            data: Data([0x01, 0x02, 0x03])
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func finishedWithMaxIterationsReasonRoundTrips() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 20, output: 10)),
            content: nil,
            reason: .maxIterationsReached(limit: 4),
            history: []
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func finishedWithTokenBudgetReasonRoundTrips() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 30, output: 20)),
            content: nil,
            reason: .tokenBudgetExceeded(budget: 40, used: 50),
            history: []
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func subAgentStartedRoundTrips() throws {
        let kind = StreamEvent.Kind.subAgentStarted(toolCallId: "tc_sub", toolName: "research")
        #expect(try roundTrip(kind) == kind)
    }

    @Test func subAgentCompletedRoundTrips() throws {
        let kind = StreamEvent.Kind.subAgentCompleted(
            toolCallId: "tc_sub",
            toolName: "research",
            result: ToolResult(content: "sub-agent result")
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test(arguments: [TokenUsage(input: 200, output: 80, reasoning: 10), nil])
    func iterationCompletedRoundTrips(usage: TokenUsage?) throws {
        let kind = StreamEvent.Kind.iterationCompleted(
            usage: usage,
            iteration: 3,
            history: [.user("Hi"), .tool(id: "tc_1", name: "echo", content: "{\"echoed\":\"hi\"}")]
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func contextFoldedRoundTrips() throws {
        let kind = StreamEvent.Kind.contextFolded(
            ContextFold(blockIDs: [ContextBlockID("b1"), ContextBlockID("b2")], tokensSaved: 5000)
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func contextRestoredRoundTrips() throws {
        let kind = StreamEvent.Kind.contextRestored(
            ContextRestore(blockID: ContextBlockID("b1"), tokensRestored: 1200)
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func contextStatusRoundTrips() throws {
        let kind = StreamEvent.Kind.contextStatus(
            ContextStatus(windowSize: 8192, usedTokens: 5000, blockCount: 2)
        )
        #expect(try roundTrip(kind) == kind)
    }

    @Test func contextEventWireShapeIsStable() throws {
        let kind = StreamEvent.Kind.contextRestored(
            ContextRestore(blockID: ContextBlockID("b1"), tokensRestored: 1200)
        )
        let data = try JSONEncoder().encode(kind)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "contextRestored")
        let context = try #require(json["context"] as? [String: Any])
        #expect(context["blockID"] as? String == "b1")
        #expect(context["tokensRestored"] as? Int == 1200)
    }

    @Test func legacyCompactionEventTypesAreRejected() {
        for type in ["compacted", "budgetUpdated", "budgetAdvisory"] {
            let json = #"{"type":"\#(type)","totalTokens":1,"windowSize":2}"#
            do {
                _ = try JSONDecoder().decode(StreamEvent.Kind.self, from: Data(json.utf8))
                Issue.record("Expected DecodingError.dataCorrupted for \(type)")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.debugDescription.contains(type))
            } catch {
                Issue.record("Expected DecodingError.dataCorrupted for \(type), got \(error)")
            }
        }
    }

    @Test func toolApprovalRequestedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolApprovalRequested(ToolApprovalRequest(
            toolCallId: "tc_1",
            toolName: "delete_file",
            arguments: #"{"path":"/tmp/test"}"#,
            toolDescription: "Deletes a file"
        ))
        #expect(try roundTrip(kind) == kind)
    }

    @Test func toolApprovalResolvedRoundTrips() throws {
        let kind = StreamEvent.Kind.toolApprovalResolved(
            toolCallId: "tc_1",
            decision: .deny(reason: "too risky")
        )
        #expect(try roundTrip(kind) == kind)
    }
}

struct StreamEventRecursiveCodableTests {
    private func requiredUUID(_ value: String) throws -> UUID {
        try #require(UUID(uuidString: value))
    }

    @Test func twoLevelNestingRoundTrips() throws {
        let innerID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000001"))
        let innerSessionID = try SessionID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000002"))
        let innerRunID = try RunID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000003"))
        let innerTimestamp = Date(timeIntervalSince1970: 0.123)
        let innerEvent = StreamEvent(
            id: innerID,
            timestamp: innerTimestamp,
            sessionID: innerSessionID,
            runID: innerRunID,
            kind: .delta("leaf")
        )
        let outerKind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_outer",
            toolName: "agent_a",
            event: innerEvent
        )
        let outerEvent = StreamEvent(kind: outerKind)

        let data = try JSONEncoder().encode(outerEvent)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .subAgentEvent(toolCallId, toolName, nestedEvent) = decoded.kind else {
            Issue.record("Expected subAgentEvent, got \(decoded.kind)")
            return
        }
        #expect(toolCallId == "tc_outer")
        #expect(toolName == "agent_a")
        #expect(nestedEvent.id == innerID)
        #expect(abs(nestedEvent.timestamp.timeIntervalSince1970 - innerTimestamp.timeIntervalSince1970) < 0.001)
        #expect(nestedEvent.sessionID == innerSessionID)
        #expect(nestedEvent.runID == innerRunID)
        #expect(nestedEvent.kind == .delta("leaf"))
    }

    @Test func threeLevelNestingRoundTrips() throws {
        let level3ID = try EventID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000011"))
        let level3SessionID = try SessionID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000012"))
        let level3RunID = try RunID(rawValue: requiredUUID("00000000-0000-0000-0000-000000000013"))
        let level3Timestamp = Date(timeIntervalSince1970: 10.456)
        let level3 = StreamEvent(
            id: level3ID,
            timestamp: level3Timestamp,
            sessionID: level3SessionID,
            runID: level3RunID,
            kind: .reasoningDelta("thinking")
        )
        let level2Kind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_l2",
            toolName: "agent_b",
            event: level3
        )
        let level2ID = try EventID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000021")))
        let level2Timestamp = Date(timeIntervalSince1970: 20.789)
        let level2 = StreamEvent(id: level2ID, timestamp: level2Timestamp, kind: level2Kind)
        let level1Kind = StreamEvent.Kind.subAgentEvent(
            toolCallId: "tc_l1",
            toolName: "agent_a",
            event: level2
        )
        let level1 = StreamEvent(kind: level1Kind)

        let data = try JSONEncoder().encode(level1)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .subAgentEvent(_, _, mid) = decoded.kind else {
            Issue.record("Expected level 1 subAgentEvent")
            return
        }
        guard case let .subAgentEvent(_, _, leaf) = mid.kind else {
            Issue.record("Expected level 2 subAgentEvent")
            return
        }
        #expect(mid.id == level2ID)
        #expect(abs(mid.timestamp.timeIntervalSince1970 - level2Timestamp.timeIntervalSince1970) < 0.001)
        #expect(leaf.id == level3ID)
        #expect(abs(leaf.timestamp.timeIntervalSince1970 - level3Timestamp.timeIntervalSince1970) < 0.001)
        #expect(leaf.sessionID == level3SessionID)
        #expect(leaf.runID == level3RunID)
        #expect(leaf.kind == .reasoningDelta("thinking"))
    }
}

struct StreamEventKindEqualityTests {
    @Test func subAgentEventEqualityIgnoresNestedEnvelope() {
        let innerA = StreamEvent(id: EventID(), timestamp: Date(timeIntervalSince1970: 1), kind: .delta("same"))
        let innerB = StreamEvent(id: EventID(), timestamp: Date(timeIntervalSince1970: 2), kind: .delta("same"))
        let kindA = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerA)
        let kindB = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerB)
        #expect(kindA == kindB)
    }

    @Test func subAgentEventInequalityWhenNestedKindDiffers() {
        let innerA = StreamEvent(kind: .delta("alpha"))
        let innerB = StreamEvent(kind: .delta("beta"))
        let kindA = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerA)
        let kindB = StreamEvent.Kind.subAgentEvent(toolCallId: "tc", toolName: "agent", event: innerB)
        #expect(kindA != kindB)
    }
}

struct StreamEventEnvelopeCodableTests {
    @Test func allFieldsSurviveRoundTrip() throws {
        let id = EventID()
        let sessionID = SessionID()
        let runID = RunID()
        let checkpointID = CheckpointID()
        let event = StreamEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_711_800_000),
            sessionID: sessionID,
            runID: runID,
            origin: .replayed(from: checkpointID),
            kind: .delta("test")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.runID == runID)
        #expect(decoded.origin == .replayed(from: checkpointID))
        #expect(decoded.kind == .delta("test"))
    }

    @Test func timestampPreservesMillisecondPrecision() throws {
        let event = StreamEvent(
            timestamp: Date(timeIntervalSince1970: 1_711_800_000.123),
            kind: .delta("ts")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(abs(decoded.timestamp.timeIntervalSince1970 - 1_711_800_000.123) < 0.001)
    }

    @Test(arguments: [
        (0.123, "1970-01-01T00:00:00.123Z"),
        (-0.123, "1969-12-31T23:59:59.877Z"),
        (0.9996, "1970-01-01T00:00:01.000Z"),
        (-0.9996, "1969-12-31T23:59:59.000Z"),
    ])
    func timestampEncodesAsStableISO8601String(secondsSince1970: TimeInterval, timestamp: String) throws {
        let event = StreamEvent(
            timestamp: Date(timeIntervalSince1970: secondsSince1970),
            kind: .delta("ts")
        )

        let data = try JSONEncoder().encode(event)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: data)

        #expect(json["timestamp"] == .string(timestamp))
    }

    @Test(arguments: [
        Double(Int64.max) / 1000,
        (Double(Int64.min) / 1000).nextDown,
        Double.greatestFiniteMagnitude,
        Double.infinity,
        -Double.infinity,
        Double.nan,
    ])
    func unrepresentableTimestampThrowsEncodingError(secondsSince1970: TimeInterval) throws {
        let event = StreamEvent(
            timestamp: Date(timeIntervalSince1970: secondsSince1970),
            kind: .delta("ts")
        )

        do {
            _ = try JSONEncoder().encode(event)
            Issue.record("Expected EncodingError.invalidValue")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["timestamp"])
        }
    }

    @Test(arguments: [
        ("1970-01-01T00:00:00.000Z", 0.0),
        ("2026-03-30T14:22:09.123Z", 1_774_880_529.123),
    ])
    func timestampArchiveDecodesToExpectedDate(timestamp: String, secondsSince1970: TimeInterval) throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "\(timestamp)",
            "kind": {"type": "delta", "text": "hello"}
        }
        """

        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        #expect(event.timestamp == Date(timeIntervalSince1970: secondsSince1970))
        #expect(event.kind == .delta("hello"))
    }

    @Test func nilOptionalFieldsOmittedFromJSON() throws {
        let event = StreamEvent(kind: .delta("bare"))
        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["sessionID"] == nil)
        #expect(json["runID"] == nil)
        #expect(json["origin"] == nil)
    }

    @Test func nonNilOptionalFieldsPreserved() throws {
        let sessionID = SessionID()
        let runID = RunID()
        let event = StreamEvent(
            sessionID: sessionID,
            runID: runID,
            kind: .delta("ctx")
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.sessionID == sessionID)
        #expect(decoded.runID == runID)
    }
}

struct EventOriginCodableTests {
    private func roundTrip(_ origin: EventOrigin) throws -> EventOrigin {
        let data = try JSONEncoder().encode(origin)
        return try JSONDecoder().decode(EventOrigin.self, from: data)
    }

    private func encodedString(_ origin: EventOrigin) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(try String(data: encoder.encode(origin), encoding: .utf8))
    }

    private func uuid(_ value: String) throws -> UUID {
        try #require(UUID(uuidString: value))
    }

    @Test func liveEncodesAsTypeOnlyDictionary() throws {
        #expect(try encodedString(.live) == #"{"type":"live"}"#)
        #expect(try roundTrip(.live) == .live)
    }

    @Test func replayedEncodesAsTaggedDictionary() throws {
        let checkpointID = try CheckpointID(rawValue: uuid("00000000-0000-0000-0000-000000000601"))
        let origin = EventOrigin.replayed(from: checkpointID)
        let expected = #"{"from":"00000000-0000-0000-0000-000000000601","type":"replayed"}"#
        #expect(try encodedString(origin) == expected)
        #expect(try roundTrip(origin) == origin)
    }

    @Test func unknownTypeThrowsWithDescriptiveError() throws {
        let data = Data(#"{"type":"forked","from":"00000000-0000-0000-0000-000000000601"}"#.utf8)

        do {
            _ = try JSONDecoder().decode(EventOrigin.self, from: data)
            Issue.record("Expected DecodingError.dataCorrupted")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("forked"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got \(error)")
        }
    }

    @Test func replayedTypeWithoutFromKeyThrows() throws {
        let data = Data(#"{"type":"replayed"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventOrigin.self, from: data)
        }
    }

    @Test func replayedTypeWithNullFromThrows() throws {
        let data = Data(#"{"type":"replayed","from":null}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventOrigin.self, from: data)
        }
    }
}

struct StreamEventFinishedCodableTests {
    @Test func nonTrivialHistoryRoundTrips() throws {
        let history: [ChatMessage] = [
            .system("You are helpful."),
            .user("What is 2+2?"),
            .assistant(AssistantMessage(
                content: "Let me calculate.",
                toolCalls: [ToolCall(id: "tc_1", name: "calculator", arguments: #"{"expr":"2+2"}"#)]
            )),
            .tool(id: "tc_1", name: "calculator", content: "4"),
            .assistant(AssistantMessage(content: "The answer is 4.")),
        ]
        let kind = StreamEvent.Kind.finished(
            tokenUsage: makeTokenUsageTotals(
                TokenUsage(input: 150, output: 30, reasoning: 5, cacheRead: 10, cacheWrite: 20)
            ),
            content: "The answer is 4.",
            reason: .completed,
            history: history
        )
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.kind == kind)
    }

    @Test func nilContentAndReasonOmittedFromJSON() throws {
        let kind = StreamEvent.Kind.finished(
            tokenUsage: makeTokenUsageTotals(TokenUsage(input: 10, output: 5)),
            content: nil,
            reason: nil,
            history: []
        )
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kindJSON = try #require(json["kind"] as? [String: Any])

        #expect(kindJSON["content"] == nil)
        #expect(kindJSON["reason"] == nil)
        #expect(kindJSON["history"] is [Any])

        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
        #expect(decoded.kind == kind)
    }
}

struct StreamEventAudioDataCodableTests {
    @Test func nonTrivialBinaryDataRoundTrips() throws {
        let bytes = Data(UInt8.min ... UInt8.max)
        let kind = StreamEvent.Kind.audioData(bytes)
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        guard case let .audioData(decodedBytes) = decoded.kind else {
            Issue.record("Expected audioData, got \(decoded.kind)")
            return
        }
        #expect(decodedBytes == bytes)
    }

    @Test func emptyDataRoundTrips() throws {
        let kind = StreamEvent.Kind.audioData(Data())
        let event = StreamEvent(kind: kind)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded.kind == kind)
    }
}

struct StreamEventDiscriminatorTests {
    @Test func deltaDiscriminatorIsStable() throws {
        let event = StreamEvent(kind: .delta("Hello"))
        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kindJSON = try #require(json["kind"] as? [String: Any])
        #expect(kindJSON["type"] as? String == "delta")
    }

    @Test(arguments: [
        "not-a-date",
        "2026-03-30T14:22:0/.123Z",
        "2026-03-30T14:22:0:.123Z",
        "2026-03-30T14:22:07.12/Z",
        "2026-03-30T14:22:07.12:Z",
    ])
    func invalidTimestampThrowsDecodingError(timestamp: String) throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "\(timestamp)",
            "kind": {
                "type": "delta",
                "text": "hello"
            }
        }
        """
        do {
            _ = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError.dataCorrupted")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["timestamp"])
        }
    }

    @Test(arguments: [
        "2026-02-30T14:22:07.123Z",
        "2025-02-29T00:00:00.000Z",
        "2026-04-31T00:00:00.000Z",
        "2026-13-01T00:00:00.000Z",
        "2026-03-30T24:00:00.000Z",
        "2026-03-30T14:60:00.000Z",
        "2026-03-30T14:22:60.000Z",
    ])
    func impossibleCalendarTimestampThrowsDecodingError(timestamp: String) throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "\(timestamp)",
            "kind": {
                "type": "delta",
                "text": "hello"
            }
        }
        """
        do {
            _ = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError.dataCorrupted")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["timestamp"])
        }
    }

    @Test func timestampOutsideFourDigitYearThrowsEncodingError() throws {
        // 10000-01-01T00:00:00Z fits in Int64 milliseconds, so only the four-digit-year guard can reject it.
        let date = Date(timeIntervalSince1970: 253_402_300_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        #expect(calendar.component(.year, from: date) == 10000)

        let event = StreamEvent(timestamp: date, kind: .delta("ts"))
        do {
            _ = try JSONEncoder().encode(event)
            Issue.record("Expected EncodingError.invalidValue")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["timestamp"])
        }
    }

    @Test func unknownTypeErrorMessageIncludesTypeName() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "2026-03-30T14:22:07.123Z",
            "kind": {
                "type": "teleport",
                "destination": "mars"
            }
        }
        """
        do {
            _ = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
            Issue.record("Expected DecodingError")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("teleport"))
        } catch {
            Issue.record("Expected DecodingError.dataCorrupted, got \(error)")
        }
    }
}
