@testable import AgentHarnessKit
import Foundation
import Testing

struct PartialTurnRecorderTests {
    private static let cancelled = PartialTurnRecorder.cancelledToolResultContent

    private static func call(_ id: String, _ name: String) -> ToolCall {
        ToolCall(id: id, name: name, arguments: "{}")
    }

    @Test
    func textOnlySnapshotIsAssistantTextAfterBaseHistory() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.system("Be brief."), .user("Hi")])
        recorder.appendText("Hel")
        recorder.appendText("lo")

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [
            .system("Be brief."),
            .user("Hi"),
            .assistant(AssistantMessage(content: "Hello")),
        ])
    }

    @Test
    func committedCallsWithNoResultsGetSyntheticResultsInCallOrder() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Look up two things")])
        let calls = [Self.call("call_1", "lookup"), Self.call("call_2", "search")]
        recorder.commitAssistant(AssistantMessage(content: "", toolCalls: calls))

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [
            .user("Look up two things"),
            .assistant(AssistantMessage(content: "", toolCalls: calls)),
            .tool(id: "call_1", name: "lookup", content: Self.cancelled),
            .tool(id: "call_2", name: "search", content: Self.cancelled),
        ])
    }

    @Test
    func onlyMissingResultsAreSynthesized() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Go")])
        let calls = [
            Self.call("call_1", "lookup"),
            Self.call("call_2", "search"),
            Self.call("call_3", "fetch"),
        ]
        recorder.commitAssistant(AssistantMessage(content: "", toolCalls: calls))
        recorder.appendToolResult(id: "call_1", name: "lookup", result: .success("one"))
        recorder.appendToolResult(id: "call_2", name: "search", result: .success("two"))

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [
            .user("Go"),
            .assistant(AssistantMessage(content: "", toolCalls: calls)),
            .tool(id: "call_1", name: "lookup", content: "one"),
            .tool(id: "call_2", name: "search", content: "two"),
            .tool(id: "call_3", name: "fetch", content: Self.cancelled),
        ])
    }

    @Test
    func allResultsReceivedMeansNoSyntheticResults() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Go")])
        let calls = [Self.call("call_1", "lookup"), Self.call("call_2", "search")]
        recorder.commitAssistant(AssistantMessage(content: "Checking.", toolCalls: calls))
        recorder.appendToolResult(id: "call_1", name: "lookup", result: .success("one"))
        recorder.appendToolResult(id: "call_2", name: "search", result: .success("two"))

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [
            .user("Go"),
            .assistant(AssistantMessage(content: "Checking.", toolCalls: calls)),
            .tool(id: "call_1", name: "lookup", content: "one"),
            .tool(id: "call_2", name: "search", content: "two"),
        ])
    }

    @Test
    func emptyTrailingAssistantIsDropped() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Hi")])
        recorder.commitAssistant(AssistantMessage(content: ""))

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [.user("Hi")])
    }

    @Test
    func textAfterMarkIterationCompleteFollowsValidatedMessages() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Hi")])
        recorder.commitAssistant(AssistantMessage(content: "", toolCalls: [Self.call("call_1", "lookup")]))
        recorder.appendToolResult(id: "call_1", name: "lookup", result: .success("one"))
        recorder.markIterationComplete(messages: [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [Self.call("call_1", "lookup")])),
            .tool(id: "call_1", name: "lookup", content: "one"),
        ])
        recorder.appendText("Second ")
        recorder.appendText("iteration")

        let snapshot = recorder.snapshot()

        try snapshot.validateForLLMRequest()
        #expect(snapshot == [
            .user("Hi"),
            .assistant(AssistantMessage(content: "", toolCalls: [Self.call("call_1", "lookup")])),
            .tool(id: "call_1", name: "lookup", content: "one"),
            .assistant(AssistantMessage(content: "Second iteration")),
        ])
    }

    @Test
    func finishOnlyCommitRestoresAnswerAsPlainText() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Go")])
        let finish = ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)
        recorder.commitAssistant(AssistantMessage(content: "", toolCalls: [finish]))

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        #expect(snapshot == [.user("Go"), .assistant(AssistantMessage(content: "done"))])
        #expect(!snapshot.contains {
            if case .tool = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func finishWithTextMergesPerTerminalAnswerRule() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Go")])
        let finish = ToolCall(id: "finish_1", name: "finish", arguments: #"{"content":"done"}"#)
        recorder.commitAssistant(AssistantMessage(content: "Checking.", toolCalls: [finish]))

        let snapshot = recorder.snapshot()
        try snapshot.validateForLLMRequest()
        let committed: [ChatMessage] = [
            .user("Go"),
            .assistant(AssistantMessage(content: "Checking.", toolCalls: [finish])),
        ]
        let expected = try committed.sanitizedTerminalHistory()
        #expect(snapshot == expected)
        #expect(!snapshot.contains {
            if case .tool = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func snapshotIsNonMutating() throws {
        let recorder = PartialTurnRecorder()
        recorder.begin(baseHistory: [.user("Go")])
        let calls = [Self.call("call_1", "lookup")]
        recorder.commitAssistant(AssistantMessage(content: "", toolCalls: calls))
        recorder.appendText("Waiting")

        let first = recorder.snapshot()
        let second = recorder.snapshot()
        #expect(first == second)
        try second.validateForLLMRequest()

        // The synthetic result must not have been stored: a real result arriving later replaces it.
        recorder.appendToolResult(id: "call_1", name: "lookup", result: .success("finally"))
        let afterResult = recorder.snapshot()

        try afterResult.validateForLLMRequest()
        #expect(afterResult == [
            .user("Go"),
            .assistant(AssistantMessage(content: "", toolCalls: calls)),
            .tool(id: "call_1", name: "lookup", content: "finally"),
            .assistant(AssistantMessage(content: "Waiting")),
        ])
    }
}
