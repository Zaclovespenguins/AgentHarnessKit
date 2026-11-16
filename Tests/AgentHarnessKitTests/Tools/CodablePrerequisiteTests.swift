@testable import AgentHarnessKit
import Foundation
import Testing

struct FinishReasonCodableTests {
    private func roundTrip(_ value: FinishReason) throws -> FinishReason {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(FinishReason.self, from: data)
    }

    @Test func completedRoundTrips() throws {
        #expect(try roundTrip(.completed) == .completed)
    }

    @Test func errorRoundTrips() throws {
        #expect(try roundTrip(.error) == .error)
    }

    @Test func customRoundTrips() throws {
        #expect(try roundTrip(.custom("stopped")) == .custom("stopped"))
    }

    @Test func maxIterationsReachedRoundTrips() throws {
        #expect(try roundTrip(.maxIterationsReached(limit: 7)) == .maxIterationsReached(limit: 7))
    }

    @Test func tokenBudgetExceededRoundTrips() throws {
        #expect(try roundTrip(.tokenBudgetExceeded(budget: 100, used: 140)) == .tokenBudgetExceeded(
            budget: 100,
            used: 140
        ))
    }

    @Test func emptyCustomRoundTrips() throws {
        #expect(try roundTrip(.custom("")) == .custom(""))
    }

    @Test func customPreservesCase() throws {
        #expect(try roundTrip(.custom("STOPPED")) == .custom("STOPPED"))
    }

    @Test func customCompletedRoundTripsAsCustom() throws {
        #expect(try roundTrip(.custom("completed")) == .custom("completed"))
    }

    @Test func customErrorRoundTripsAsCustom() throws {
        #expect(try roundTrip(.custom("error")) == .custom("error"))
    }

    @Test func discriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.completed)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "completed")
    }

    @Test func customDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.custom("stopped"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "custom")
        #expect(json["value"] as? String == "stopped")
    }

    @Test func maxIterationsReachedDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.maxIterationsReached(limit: 9))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "maxIterationsReached")
        #expect(json["limit"] as? Int == 9)
    }

    @Test func tokenBudgetExceededDiscriminatorIsStable() throws {
        let data = try JSONEncoder().encode(FinishReason.tokenBudgetExceeded(budget: 10, used: 12))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "tokenBudgetExceeded")
        #expect(json["budget"] as? Int == 10)
        #expect(json["used"] as? Int == 12)
    }

    @Test func initMapsArbitraryStringToCustom() {
        #expect(FinishReason("paused") == .custom("paused"))
    }

    @Test func unknownTypeThrowsDecodingError() throws {
        let json = #"{"type":"mystery"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FinishReason.self, from: Data(json.utf8))
        }
    }
}

struct ContextEventPayloadCodableTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func blockIDEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([ContextBlockID("b7")])
        #expect(String(data: data, encoding: .utf8) == #"["b7"]"#)
        #expect(try roundTrip(ContextBlockID("b7")) == ContextBlockID("b7"))
        #expect(ContextBlockID("b7").description == "b7")
    }

    @Test func foldRoundTrips() throws {
        let fold = ContextFold(blockIDs: [ContextBlockID("b1"), ContextBlockID("b2")], tokensSaved: 60124)
        #expect(try roundTrip(fold) == fold)
    }

    @Test func restoreRoundTrips() throws {
        let restore = ContextRestore(blockID: ContextBlockID("b1"), tokensRestored: 7161)
        #expect(try roundTrip(restore) == restore)
    }

    @Test func statusRoundTripsAndDerivesUsage() throws {
        let status = ContextStatus(windowSize: 8000, usedTokens: 6000, blockCount: 3)
        #expect(try roundTrip(status) == status)
        #expect(status.utilization == 0.75)
        #expect(status.remainingTokens == 2000)
    }

    @Test func statusClampsDerivedValues() {
        let overfull = ContextStatus(windowSize: 100, usedTokens: 150, blockCount: 0)
        #expect(overfull.remainingTokens == 0)
        let unknownWindow = ContextStatus(windowSize: 0, usedTokens: 10, blockCount: 0)
        #expect(unknownWindow.utilization == 0)
    }
}

struct ToolApprovalRequestCodableTests {
    private func roundTrip(_ value: ToolApprovalRequest) throws -> ToolApprovalRequest {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ToolApprovalRequest.self, from: data)
    }

    @Test func roundTripsAllFields() throws {
        let request = ToolApprovalRequest(
            toolCallId: "tc_1",
            toolName: "search",
            arguments: #"{"query":"swift"}"#,
            toolDescription: "Search the web"
        )
        #expect(try roundTrip(request) == request)
    }
}

struct ToolApprovalDecisionCodableTests {
    private func roundTrip(_ value: ToolApprovalDecision) throws -> ToolApprovalDecision {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ToolApprovalDecision.self, from: data)
    }

    @Test func approveRoundTrips() throws {
        #expect(try roundTrip(.approve) == .approve)
    }

    @Test func approveAlwaysRoundTrips() throws {
        #expect(try roundTrip(.approveAlways) == .approveAlways)
    }

    @Test func approveWithModifiedArgumentsRoundTrips() throws {
        let decision = ToolApprovalDecision.approveWithModifiedArguments(#"{"safe":true}"#)
        #expect(try roundTrip(decision) == decision)
    }

    @Test func denyWithReasonRoundTrips() throws {
        #expect(try roundTrip(.deny(reason: "too dangerous")) == .deny(reason: "too dangerous"))
    }

    @Test func denyWithNilReasonRoundTrips() throws {
        #expect(try roundTrip(.deny(reason: nil)) == .deny(reason: nil))
    }

    @Test func unknownTypeThrowsDecodingError() throws {
        let json = #"{"type":"unknown"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ToolApprovalDecision.self, from: Data(json.utf8))
        }
    }

    @Test func discriminatorIsStable() throws {
        let data = try JSONEncoder().encode(ToolApprovalDecision.approve)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "approve")
    }
}

struct EventIDCodableTests {
    @Test func roundTrips() throws {
        let id = EventID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(EventID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = EventID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}

struct SessionIDCodableTests {
    @Test func roundTrips() throws {
        let id = SessionID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(SessionID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = SessionID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}

struct RunIDCodableTests {
    @Test func roundTrips() throws {
        let id = RunID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RunID.self, from: data)
        #expect(decoded == id)
    }

    @Test func encodesAsFlatUUIDString() throws {
        let id = RunID()
        let data = try JSONEncoder().encode(id)
        let string = try JSONDecoder().decode(String.self, from: data)
        #expect(string == id.rawValue.uuidString)
    }

    @Test func rejectsMalformedUUIDString() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RunID.self, from: Data(#""not-a-uuid""#.utf8))
        }
    }
}
