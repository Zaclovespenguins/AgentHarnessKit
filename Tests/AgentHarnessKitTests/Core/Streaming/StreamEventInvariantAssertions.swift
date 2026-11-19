@testable import AgentHarnessKit
import Foundation
import Testing

enum StreamEventScope {
    case chat
    case agent
}

enum StreamEventInvariantAssertions {
    static func assertStage1RuntimeInvariants(
        _ events: [StreamEvent],
        startedAt: Date,
        endedAt: Date,
        scope: StreamEventScope = .agent
    ) {
        if case .agent = scope {
            // A run stamps one session id and one run id on every event it emits.
            #expect(Set(events.compactMap(\.sessionID)).count <= 1)
            #expect(Set(events.compactMap(\.runID)).count <= 1)
        }
        var ids = Set<EventID>()
        for event in events {
            assertStage1RuntimeInvariants(
                event,
                startedAt: startedAt,
                endedAt: endedAt,
                scope: scope,
                isOutermost: true,
                ids: &ids
            )
        }
    }

    private static func assertStage1RuntimeInvariants(
        _ event: StreamEvent,
        startedAt: Date,
        endedAt: Date,
        scope: StreamEventScope,
        isOutermost: Bool,
        ids: inout Set<EventID>
    ) {
        #expect(ids.insert(event.id).inserted)
        #expect(event.timestamp >= startedAt)
        #expect(event.timestamp <= endedAt)
        #expect(event.origin == .live)
        switch scope {
        case .chat:
            if isOutermost {
                #expect(event.sessionID == nil)
                #expect(event.runID == nil)
            }
        case .agent:
            if isOutermost {
                #expect(event.sessionID != nil)
                #expect(event.runID != nil)
            }
        }
        if case let .subAgentEvent(_, _, nestedEvent) = event.kind {
            assertStage1RuntimeInvariants(
                nestedEvent,
                startedAt: startedAt,
                endedAt: endedAt,
                scope: scope,
                isOutermost: false,
                ids: &ids
            )
        }
    }
}
