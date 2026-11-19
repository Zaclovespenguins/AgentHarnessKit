@testable import AgentHarnessKit
import AgentHarnessKitTesting
import Foundation
import Testing

// v0.2 item 2: a built-in `finish` answer stays in the returned history as a
// plain assistant message, on both the `run` and `stream` paths, and appears
// exactly once in the next turn's request.

private let answer = "The answer is 42 (terminal-answer-marker)."

private func finishCall(id: String = "call_finish", content: String = answer) -> ToolCall {
    ToolCall(id: id, name: "finish", arguments: encodedFinishArguments(content))
}

private func encodedFinishArguments(_ content: String) -> String {
    #"{"content":"\#(content)"}"#
}

private func finishDeltas(text: String? = nil, content: String = answer) -> [StreamDelta] {
    var deltas: [StreamDelta] = []
    if let text {
        deltas.append(.content(text))
    }
    deltas.append(.toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function))
    deltas.append(.toolCallDelta(index: 0, arguments: encodedFinishArguments(content)))
    deltas.append(.finished(usage: TokenUsage(input: 1, output: 1)))
    return deltas
}

private func finishedHistory(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [ChatMessage] {
    var history: [ChatMessage]?
    for try await event in stream {
        if case let .finished(_, _, _, eventHistory) = event.kind {
            history = eventHistory
        }
    }
    return try #require(history)
}

private func textOf(_ message: ChatMessage) -> String {
    switch message {
    case let .system(text), let .user(text):
        text
    case let .userMultimodal(parts):
        String(describing: parts)
    case let .assistant(assistant):
        assistant.content + assistant.toolCalls.map(\.arguments).joined()
    case let .tool(_, _, content):
        content
    }
}

private func occurrences(of needle: String, in messages: [ChatMessage]) -> Int {
    messages.reduce(0) { count, message in
        count + textOf(message).components(separatedBy: needle).count - 1
    }
}

private func expectRestoredAnswer(_ history: [ChatMessage], content expected: String) {
    guard case let .assistant(last) = history.last else {
        Issue.record("Expected history to end with an assistant message, got \(String(describing: history.last))")
        return
    }
    #expect(last.content == expected)
    #expect(last.toolCalls.isEmpty)
    #expect(!history.contains { message in
        guard case let .assistant(assistant) = message else { return false }
        return assistant.toolCalls.contains { $0.name == "finish" }
    })
}

struct TerminalAnswerHistoryRunTests {
    @Test
    func finishOnlyTurnKeepsAnswerInHistory() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "", toolCalls: [finishCall()]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.content == answer)
        #expect(result.history.count == 2)
        expectRestoredAnswer(result.history, content: answer)
        try result.history.validateForAgentHistory()
    }

    @Test
    func finishWithDifferentTextJoinsBoth() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: "Let me wrap up.", toolCalls: [finishCall()]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        expectRestoredAnswer(result.history, content: "Let me wrap up.\n\n\(answer)")
    }

    @Test
    func finishWithEqualTextKeepsOneCopy() async throws {
        let client = ContentOnlyTerminatingMockLLMClient(generateResponses: [
            AssistantMessage(content: answer, toolCalls: [finishCall()]),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        expectRestoredAnswer(result.history, content: answer)
        #expect(occurrences(of: answer, in: result.history) == 1)
    }

    @Test
    func finishAfterToolWorkKeepsAnswerAfterToolResults() async throws {
        let client = TestLLMClient(finishContent: answer)
        let lookup = try Tool<TerminalLookupParams, TerminalLookupOutput, EmptyContext>(
            name: "lookup",
            description: "Look something up",
            executor: { _, _ in TerminalLookupOutput(value: "42") }
        )
        let agent = Agent<EmptyContext>(client: client, tools: [lookup])

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.content == answer)
        expectRestoredAnswer(result.history, content: answer)
        try result.history.validateForLLMRequest()
        try result.history.validateForAgentHistory()
    }

    @Test
    func completionToolRunHistoryIsUnchanged() async throws {
        let client = TestLLMClient(completionToolName: "submit")
        let agent = Agent<EmptyContext>(client: client, tools: [], completionTool: TerminalSubmitTool())

        let result = try await agent.run(userMessage: "Q", context: EmptyContext())

        #expect(result.history.count == 3)
        guard case let .assistant(assistant) = result.history[1] else {
            Issue.record("Expected the completion call to stay in history")
            return
        }
        #expect(assistant.toolCalls.map(\.name) == ["submit"])
        guard case let .tool(_, name, content) = result.history[2] else {
            Issue.record("Expected the completion tool result to end history")
            return
        }
        #expect(name == "submit")
        #expect(content == result.content)
    }
}

struct TerminalAnswerHistoryStreamTests {
    @Test
    func finishOnlyTurnKeepsAnswerInFinishedHistory() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [finishDeltas()])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let history = try await finishedHistory(agent.stream(userMessage: "Q", context: EmptyContext()))

        #expect(history.count == 2)
        expectRestoredAnswer(history, content: answer)
        try history.validateForAgentHistory()
    }

    @Test
    func finishWithDifferentTextJoinsBoth() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [finishDeltas(text: "Let me wrap up.")])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let history = try await finishedHistory(agent.stream(userMessage: "Q", context: EmptyContext()))

        expectRestoredAnswer(history, content: "Let me wrap up.\n\n\(answer)")
    }

    @Test
    func completionToolStreamHistoryIsUnchanged() async throws {
        let client = TestLLMClient(completionToolName: "submit")
        let agent = Agent<EmptyContext>(client: client, tools: [], completionTool: TerminalSubmitTool())

        let history = try await finishedHistory(agent.stream(userMessage: "Q", context: EmptyContext()))

        #expect(history.count == 3)
        guard case let .tool(_, name, _) = history.last else {
            Issue.record("Expected the completion tool result to end history")
            return
        }
        #expect(name == "submit")
    }
}

struct TerminalAnswerFollowUpRequestTests {
    @Test
    func streamFollowUpRequestContainsAnswerOnce() async throws {
        let client = CapturingStreamingMockLLMClient(streamSequences: [
            finishDeltas(),
            finishDeltas(content: "Second answer"),
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])

        let firstHistory = try await finishedHistory(agent.stream(userMessage: "Q1", context: EmptyContext()))
        _ = try await finishedHistory(
            agent.stream(userMessage: "Q2", history: firstHistory, context: EmptyContext())
        )

        let requests = await client.allCapturedMessages
        #expect(requests.count == 2)
        let followUp = try #require(requests.last)
        #expect(occurrences(of: answer, in: followUp) == 1)
        try followUp.validateForLLMRequest()
    }
}

private struct TerminalLookupParams: Codable, SchemaProviding {
    let query: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["query": .string()], required: ["query"])
    }
}

private struct TerminalLookupOutput: Codable {
    let value: String
}

private struct TerminalSubmitTool: AnyTool {
    typealias Context = EmptyContext

    let name = "submit"
    let description = "Submit the final result. Call it alone once the work is done."
    let parametersSchema: JSONSchema = .object(properties: ["summary": .string()], required: ["summary"])

    func execute(arguments _: Data, context _: EmptyContext) async throws -> ToolResult {
        .success("submitted")
    }
}
