@testable import AgentHarnessKit
import Foundation
import Testing

struct AgentHistoryTests {
    @Test
    func historyIncludedInMessages() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let history: [ChatMessage] = [
            .user("Previous question"),
            .assistant(AssistantMessage(content: "Previous answer"))
        ]
        _ = try await agent.run(userMessage: "Follow-up", history: history, context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 3)
        guard case let .user(first) = capturedMessages[0] else {
            Issue.record("Expected user message first")
            return
        }
        #expect(first == "Previous question")
        guard case .assistant = capturedMessages[1] else {
            Issue.record("Expected assistant message second")
            return
        }
        guard case let .user(followUp) = capturedMessages[2] else {
            Issue.record("Expected user message third")
            return
        }
        #expect(followUp == "Follow-up")
    }

    @Test
    func resultContainsHistory() async throws {
        let finishCall = ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
        let client = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.history.count == 1)
        guard case .user = result.history[0] else {
            Issue.record("Expected user message first in history")
            return
        }
    }

    @Test
    func historyWithSystemPromptOrdering() async throws {
        let client = CapturingMockLLMClient(
            responses: [AssistantMessage(content: "", toolCalls: [
                ToolCall(id: "1", name: "finish", arguments: #"{"content": "done"}"#)
            ])]
        )
        let config = AgentConfiguration(systemPrompt: "You are helpful.")
        let agent = Agent<EmptyContext>(client: client, tools: [], configuration: config)
        let history: [ChatMessage] = [
            .user("Previous question"),
            .assistant(AssistantMessage(content: "Previous answer"))
        ]
        _ = try await agent.run(userMessage: "Follow-up", history: history, context: EmptyContext())

        let capturedMessages = await client.capturedMessages
        #expect(capturedMessages.count == 4)

        guard case let .system(prompt) = capturedMessages[0] else {
            Issue.record("Expected system message first")
            return
        }
        #expect(prompt == "You are helpful.")

        guard case let .user(histUser) = capturedMessages[1] else {
            Issue.record("Expected history user message second")
            return
        }
        #expect(histUser == "Previous question")

        guard case let .assistant(histAssistant) = capturedMessages[2] else {
            Issue.record("Expected history assistant message third")
            return
        }
        #expect(histAssistant.content == "Previous answer")

        guard case let .user(newUser) = capturedMessages[3] else {
            Issue.record("Expected new user message fourth")
            return
        }
        #expect(newUser == "Follow-up")
    }

    @Test
    func multiTurnConversationHistoryAccumulates() async throws {
        let echoTool = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo",
            description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: "Echo: \(params.message)") }
        )

        let toolCall = ToolCall(id: "call_1", name: "echo", arguments: #"{"message": "hello"}"#)
        let finishCall = ToolCall(id: "call_2", name: "finish", arguments: #"{"content": "done"}"#)

        let client = MockLLMClient(responses: [
            AssistantMessage(content: "Calling echo", toolCalls: [toolCall]),
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent = Agent<EmptyContext>(client: client, tools: [echoTool])
        let result = try await agent.run(userMessage: "Test", context: EmptyContext())

        #expect(result.history.count == 3)

        guard case .user = result.history[0] else {
            Issue.record("Expected user message first in history")
            return
        }
        guard case let .assistant(first) = result.history[1] else {
            Issue.record("Expected first assistant message second")
            return
        }
        #expect(first.content == "Calling echo")
        #expect(first.toolCalls.count == 1)

        guard case let .tool(id, name, content) = result.history[2] else {
            Issue.record("Expected tool result third")
            return
        }
        #expect(id == "call_1")
        #expect(name == "echo")
        #expect(content.contains("Echo: hello"))
    }

    @Test
    func historyFromPreviousRunCanBeChained() async throws {
        let finishCall = ToolCall(id: "1", name: "finish", arguments: #"{"content": "response 1"}"#)
        let client1 = MockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall])
        ])
        let agent1 = Agent<EmptyContext>(client: client1, tools: [])
        let result1 = try await agent1.run(userMessage: "First message", context: EmptyContext())

        let finishCall2 = ToolCall(id: "2", name: "finish", arguments: #"{"content": "response 2"}"#)
        let client2 = CapturingMockLLMClient(responses: [
            AssistantMessage(content: "", toolCalls: [finishCall2])
        ])
        let agent2 = Agent<EmptyContext>(client: client2, tools: [])
        let result2 = try await agent2.run(
            userMessage: "Second message",
            history: result1.history,
            context: EmptyContext()
        )

        let capturedMessages = await client2.capturedMessages
        #expect(capturedMessages.count == 2)

        guard case let .user(first) = capturedMessages[0] else {
            Issue.record("Expected first user message")
            return
        }
        #expect(first == "First message")

        guard case let .user(second) = capturedMessages[1] else {
            Issue.record("Expected second user message")
            return
        }
        #expect(second == "Second message")

        #expect(result2.history.count == 2)
    }
}

struct AgentTruncationTests {

}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

private actor AllCallsCapturingMockLLMClient: LLMClient {
    nonisolated let providerIdentifier: ProviderIdentifier = .custom("AllCallsCapturingMockLLMClient")
    private let responses: [AssistantMessage]
    private var callIndex: Int = 0
    private(set) var allCapturedMessages: [[ChatMessage]] = []

    init(responses: [AssistantMessage]) {
        self.responses = responses
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        allCapturedMessages.append(messages)
        defer { callIndex += 1 }
        guard callIndex < responses.count else {
            throw AgentError.llmError(.other("No more mock responses available"))
        }
        return responses[callIndex]
    }

    nonisolated func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
