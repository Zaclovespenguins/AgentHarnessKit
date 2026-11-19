import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation
import Testing

private let history: [ChatMessage] = [.system("You are terse."), .user("What is 2 + 3?")]

private func collect(_ stream: AsyncThrowingStream<StreamDelta, Error>) async throws -> [StreamDelta] {
    var deltas: [StreamDelta] = []
    for try await delta in stream {
        deltas.append(delta)
    }
    return deltas
}

private func contentText(_ deltas: [StreamDelta]) -> String {
    deltas.reduce(into: "") {
        if case let .content(text) = $1 {
            $0 += text
        }
    }
}

private func roles(_ body: [String: Any]) -> [String] {
    (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
}

@Suite(.serialized) struct HarnessModelClientGenerateTests {
    @Test func textResponseWithUsage() async throws {
        let server = try MockServer()
        server.enqueue(.text("The sum is 5."), .usage(input: 12, output: 11))
        let message = try await mockClient(server).generate(messages: history, tools: [])
        #expect(message.content == "The sum is 5.")
        #expect(message.toolCalls.isEmpty)
        #expect(message.tokenUsage?.input == 12)
        #expect(message.tokenUsage?.output == 11)
        #expect(server.requestCount == 1)
        #expect(roles(server.requestJSON(0)) == ["system", "user"])
    }

    @Test func missingUsageStaysNil() async throws {
        let server = try MockServer()
        server.enqueue(.text("hi"))
        let message = try await mockClient(server).generate(messages: history, tools: [])
        #expect(message.content == "hi")
        #expect(message.tokenUsage == nil)
    }

    @Test func toolCallIsReturnedNotExecuted() async throws {
        let server = try MockServer()
        server.enqueue(.toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#), .usage(input: 20, output: 5))
        let message = try await mockClient(server).generate(messages: history, tools: [addTool])
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.id == "call_1")
        #expect(message.toolCalls.first?.name == "add")
        #expect(jsonObject(message.toolCalls.first?.arguments ?? "") == ["a": 2, "b": 3])
        #expect(message.tokenUsage?.input == 20)
        // One request only: ALM must not run the tool and go round again.
        #expect(server.requestCount == 1)
        let tools = server.requestJSON(0)["tools"] as? [[String: Any]] ?? []
        let function = tools.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "add")
        let properties = (function?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        #expect(Set((properties ?? [:]).keys) == ["a", "b"])
    }

    @Test func parallelToolCallsKeepOrder() async throws {
        let server = try MockServer()
        server.enqueue(
            .toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#),
            .toolCall(id: "call_2", name: "add", arguments: #"{"a":4,"b":5}"#)
        )
        let message = try await mockClient(server).generate(messages: history, tools: [addTool])
        #expect(message.toolCalls.map(\.id) == ["call_1", "call_2"])
        #expect(jsonObject(message.toolCalls.last?.arguments ?? "") == ["a": 4, "b": 5])
        #expect(server.requestCount == 1)
    }

    @Test func fullHistoryIsTheWholeRequest() async throws {
        let server = try MockServer()
        server.enqueue(.text("The sum is 5."))
        let call = ToolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#)
        let messages = history + [
            .assistant(AssistantMessage(content: "", toolCalls: [call])),
            .tool(id: "call_1", name: "add", content: "5"),
        ]
        let message = try await mockClient(server).generate(messages: messages, tools: [addTool])
        #expect(message.content == "The sum is 5.")
        let body = server.requestJSON(0)
        // No appended empty user prompt, no "tool was not executed" filler (ARCHITECTURE.md section 3).
        #expect(roles(body) == ["system", "user", "assistant", "tool"])
        let sent = body["messages"] as? [[String: Any]] ?? []
        #expect(sent.last?["tool_call_id"] as? String == "call_1")
        #expect(sent.last?["content"] as? String == "5")
        let calls = sent.dropLast().last?["tool_calls"] as? [[String: Any]]
        #expect(calls?.first?["id"] as? String == "call_1")
    }

    @Test func providerOptionsReachTheWire() async throws {
        let server = try MockServer()
        let context = RequestContext(
            extraFields: ["foo": .int(1)],
            openAIChat: .init(toolChoice: .required, parallelToolCalls: false)
        )
        _ = try await mockClient(server).generate(
            messages: history, tools: [addTool], responseFormat: nil, requestContext: context
        )
        let body = server.requestJSON(0)
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["parallel_tool_calls"] as? Bool == false)
        #expect(body["foo"] as? Int == 1)
    }

    @Test func responseFormatSendsJSONSchema() async throws {
        struct Answer: SchemaProviding, Decodable {
            let sum: Int
            static var jsonSchema: JSONSchema {
                .object(properties: ["sum": .integer()], required: ["sum"])
            }
        }
        let server = try MockServer()
        server.enqueue(.text(#"{"sum":5}"#))
        let message = try await mockClient(server).generate(
            messages: history, tools: [], responseFormat: .jsonSchema(Answer.self)
        )
        #expect(jsonObject(message.content) == ["sum": 5])
        let format = server.requestJSON(0)["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
    }

    @Test func httpFailureMapsToLLMError() async throws {
        let server = try MockServer()
        server.enqueue(status: 500)
        do {
            _ = try await mockClient(server).generate(messages: history, tools: [])
            Issue.record("expected an error")
        } catch let AgentError.llmError(transport) {
            guard case let .httpError(statusCode, _) = transport else {
                Issue.record("expected httpError, got \(transport)")
                return
            }
            #expect(statusCode == 500)
        }
    }

    @Test func unsupportedMediaFailsBeforeAnyRequest() async throws {
        let server = try MockServer()
        await #expect(throws: AgentError.self) {
            _ = try await mockClient(server).generate(
                messages: [.user(audioData: Data([1]), format: .wav)], tools: []
            )
        }
        #expect(server.requestCount == 0)
    }

    /// Offline half of the Anthropic continuity test: the mock does not speak the Messages API, so
    /// the call fails after sending; only the recorded request body is asserted.
    @Test func anthropicReplaySendsSignedAndRedactedThinkingBeforeToolUse() async throws {
        let server = try MockServer()
        let client = HarnessModelClient(
            model: AnthropicLanguageModel(baseURL: server.baseURL, apiKey: "fake-key", model: "claude-mock"),
            providerIdentifier: .anthropic,
            replaySubstrate: .anthropicMessages
        )
        let turn = try ResponseMapping.assistantMessage(
            content: "", entries: thinkingTurn, usage: usage(), replaySubstrate: .anthropicMessages
        )
        let restored = try roundTripped(turn)
        let messages: [ChatMessage] = [
            .user("Compute 2 + 3 and 4 + 5."), restored,
            .tool(id: "toolu_1", name: "add", content: "5"), .tool(id: "toolu_2", name: "add", content: "9"),
        ]
        _ = try? await client.generate(messages: messages, tools: [addTool])
        #expect(server.requestCount == 1)
        let sent = server.requestJSON(0)["messages"] as? [[String: Any]] ?? []
        let blocks = sent.filter { $0["role"] as? String == "assistant" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let types = blocks.compactMap { $0["type"] as? String }
        #expect(types == ["thinking", "redacted_thinking", "tool_use", "tool_use"])
        #expect(blocks.first?["signature"] as? String == "sig-abc")
        #expect(blocks.first?["thinking"] as? String == "Let me add.")
        #expect(blocks.dropFirst().first?["data"] as? String == "redacted-blob")
    }
}

@Suite(.serialized) struct HarnessModelClientStreamTests {
    @Test func textStreamsIncrementallyAndFinishesOnce() async throws {
        let server = try MockServer()
        let words = ["Hello ", "from ", "the ", "mock ", "server."]
        server.enqueue(.text(words[0]), .text(words[1]), .text(words[2]), .text(words[3]), .text(words[4]),
                       .usage(input: 12, output: 11), delayMs: 20)
        let deltas = try await collect(mockClient(server).stream(messages: history, tools: []))
        #expect(contentText(deltas) == words.joined())
        #expect(deltas.count(where: {
            if case .content = $0 {
                true
            } else {
                false
            }
        }) > 2)
        #expect(deltas.last == .finished(usage: TokenUsage(input: 12, output: 11)))
        #expect(deltas.count(where: {
            if case .finished = $0 {
                true
            } else {
                false
            }
        }) == 1)
        #expect(server.requestCount == 1)
        #expect(server.requestJSON(0)["stream"] as? Bool == true)
    }

    @Test func toolCallsStreamUnexecuted() async throws {
        let server = try MockServer()
        server.enqueue(
            .toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#),
            .toolCall(id: "call_2", name: "add", arguments: #"{"a":4,"b":5}"#),
            .usage(input: 20, output: 5)
        )
        let deltas = try await collect(mockClient(server).stream(messages: history, tools: [addTool]))
        let starts = deltas.filter {
            if case .toolCallStart = $0 {
                true
            } else {
                false
            }
        }
        #expect(starts == [
            .toolCallStart(index: 0, id: "call_1", name: "add", kind: .function),
            .toolCallStart(index: 1, id: "call_2", name: "add", kind: .function),
        ])
        var arguments: [Int: String] = [:]
        for case let .toolCallDelta(index, chunk) in deltas {
            arguments[index, default: ""] += chunk
        }
        #expect(jsonObject(arguments[0] ?? "") == ["a": 2, "b": 3])
        #expect(jsonObject(arguments[1] ?? "") == ["a": 4, "b": 5])
        #expect(deltas.last == .finished(usage: TokenUsage(input: 20, output: 5)))
        #expect(server.requestCount == 1)
    }

    @Test func streamWithoutUsageFinishesWithNil() async throws {
        let server = try MockServer()
        server.enqueue(.text("hi"))
        let deltas = try await collect(mockClient(server).stream(messages: history, tools: []))
        #expect(deltas.last == .finished(usage: nil))
    }

    @Test func streamFailureMapsToLLMError() async throws {
        let server = try MockServer()
        server.enqueue(status: 500)
        do {
            _ = try await collect(mockClient(server).stream(messages: history, tools: []))
            Issue.record("expected an error")
        } catch AgentError.llmError(.httpError(statusCode: 500, body: _)) {}
    }

    @Test func streamRateLimitMapsToRateLimited() async throws {
        let server = try MockServer()
        server.enqueue(status: 429)
        do {
            _ = try await collect(mockClient(server).stream(messages: history, tools: []))
            Issue.record("expected an error")
        } catch AgentError.llmError(.rateLimited) {}
    }

    @Test func cancelStopsPromptlyAndReachesTheSocket() async throws {
        let server = try MockServer()
        server.enqueue(.text("1 "), .text("2 "), .text("3 "), .text("4 "), .text("5 "), .text("6 "), .text("7 "),
                       .text("8 "), .text("9 "), .text("10 "), .text("11 "), .text("12 "), .text("13 "),
                       .text("14 "), .text("15 "), .text("16 "), .text("17 "), .text("18 "), .text("19 "),
                       .text("20 "), .text("21 "), .text("22 "), .text("23 "), .text("24 "), .text("25 "),
                       .text("26 "), .text("27 "), .text("28 "), .text("29 "), .text("30 "), delayMs: 100)
        let client = mockClient(server)
        let (seen, seenContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            var count = 0
            for try await delta in client.stream(messages: history, tools: []) {
                if case .content = delta {
                    count += 1
                    seenContinuation.yield()
                }
            }
            return count
        }
        var iterator = seen.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < .milliseconds(500))
        if case let .success(count) = result {
            #expect(count < 30)
        }
        // The mock notices on its next write (100ms tick).
        try await Task.sleep(for: .milliseconds(500))
        #expect(server.abortedStreams == 1)
    }

    @Test func streamForRunDeliversContinuityBeforeFinished() async throws {
        // No reasoning from the Chat mock, so no continuity element: only deltas, ending in finished.
        let server = try MockServer()
        server.enqueue(.text("hi"))
        let client = HarnessModelClient(
            model: OpenAILanguageModel(baseURL: server.baseURL, apiKey: "fake-key", model: "mock"),
            providerIdentifier: .openAICompatible,
            replaySubstrate: .openAIChatCompletions
        )
        var elements: [RunStreamElement] = []
        for try await element in client.streamForRun(messages: history, tools: [], requestContext: nil) {
            elements.append(element)
        }
        guard case .delta(.finished) = elements.last else {
            Issue.record("expected finished last")
            return
        }
        #expect(!elements.contains {
            if case .finalizedContinuity = $0 {
                true
            } else {
                false
            }
        })
    }
}

/// Live two-iteration tool loop against an OpenAI-compatible endpoint, e.g.
/// `AHK_LIVE_BASE_URL=http://host:8080/v1 swift test --filter LiveEndpointTests`.
/// Optional: AHK_LIVE_MODEL, AHK_LIVE_API_KEY. Skipped when AHK_LIVE_BASE_URL is unset.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AHK_LIVE_BASE_URL"]?.isEmpty == false))
struct LiveEndpointTests {
    private var client: HarnessModelClient<OpenAILanguageModel> {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["AHK_LIVE_BASE_URL"] ?? "") ?? OpenAILanguageModel.defaultBaseURL
        return HarnessModelClient(
            model: OpenAILanguageModel(
                baseURL: url, apiKey: env["AHK_LIVE_API_KEY"] ?? "none", model: env["AHK_LIVE_MODEL"] ?? "default"
            ),
            providerIdentifier: .openAICompatible,
            replaySubstrate: .openAIChatCompletions,
            options: GenerationOptions(maximumResponseTokens: 2048)
        )
    }

    private let prompt: [ChatMessage] = [.user("What is 2 + 3? You must use the add tool.")]

    /// Runs the returned calls ourselves, restores the turn from JSON, and asks for the answer.
    private func secondTurn(after first: AssistantMessage) async throws -> AssistantMessage {
        #expect(!first.toolCalls.isEmpty)
        // Reasoning models must carry replay state; others must not invent it.
        #expect((first.continuity != nil) == (first.reasoning != nil))
        let results = first.toolCalls.map { call -> ChatMessage in
            let args = jsonObject(call.arguments)
            let sum = (args?["a"] as? Int ?? 0) + (args?["b"] as? Int ?? 0)
            return .tool(id: call.id, name: call.name, content: String(sum))
        }
        return try await client.generate(messages: prompt + [roundTripped(first)] + results, tools: [addTool])
    }

    @Test func generateToolLoop() async throws {
        let first = try await client.generate(messages: prompt, tools: [addTool])
        #expect(first.tokenUsage != nil)
        let final = try await secondTurn(after: first)
        #expect(final.toolCalls.isEmpty)
        #expect(final.content.contains("5"))
    }

    @Test func streamedToolLoop() async throws {
        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var continuity: AssistantContinuity?
        var finished = 0
        for try await element in client.streamForRun(messages: prompt, tools: [addTool], requestContext: nil) {
            switch element {
            case let .finalizedContinuity(value): continuity = value
            case let .delta(.content(text)): content += text
            case let .delta(.reasoning(text)): reasoning += text
            case let .delta(.toolCallStart(_, id, name, _)): calls.append(ToolCall(id: id, name: name, arguments: ""))
            case let .delta(.toolCallDelta(index, arguments)):
                let call = calls[index]
                calls[index] = ToolCall(id: call.id, name: call.name, arguments: call.arguments + arguments)
            case .delta(.finished): finished += 1
            default: break
            }
        }
        #expect(finished == 1)
        let first = AssistantMessage(
            content: content,
            toolCalls: calls,
            reasoning: reasoning.isEmpty ? nil : ReasoningContent(content: reasoning),
            continuity: continuity
        )
        let final = try await secondTurn(after: first)
        #expect(final.content.contains("5"))
    }

    /// The default agent's final answer arrives as several `.delta` events over time, not all at once in `.finished`.
    @Test func agentStreamsTheFinalAnswer() async throws {
        let agent = Agent<EmptyContext>(client: client, tools: [])
        let start = ContinuousClock.now
        var deltaTimes: [Duration] = []
        var streamed = ""
        var finishedContent: String?
        var finishedAt: Duration?
        for try await event in agent.stream(
            userMessage: "Write four short sentences about the ocean.", context: EmptyContext()
        ) {
            switch event.kind {
            case let .delta(text):
                deltaTimes.append(ContinuousClock.now - start)
                streamed += text
            case let .finished(_, content, _, _):
                finishedContent = content
                finishedAt = ContinuousClock.now - start
            default: break
            }
        }
        let first = deltaTimes.first ?? .zero
        let last = deltaTimes.last ?? .zero
        print("LIVE agent: \(deltaTimes.count) deltas, first \(first), last \(last), finished \(finishedAt ?? .zero)")
        #expect(deltaTimes.count > 1)
        #expect(last - first > .milliseconds(100))
        #expect(finishedContent == streamed)
    }
}
