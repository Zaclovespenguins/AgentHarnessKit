@testable import AgentHarnessKit
import Foundation
import Testing

private struct NoopParams: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema {
        .object(properties: [:], required: [])
    }
}

private struct NoopOutput: Codable {}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

struct ChatTimeoutTests {
    @Test
    func chatHonorsPerToolTimeoutOverride() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: .milliseconds(50),
            executor: { _, _ in
                try await Task.sleep(for: .seconds(10))
                return NoopOutput()
            }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "slow", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("recovered"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [slowTool], toolTimeout: .seconds(30))

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run slow", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "slow"
                    && result.isError
                    && result.content.contains("timed out")
                    && result.content.contains("'slow'")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }

    @Test
    func chatToolTimeoutNilInheritsChatDefault() async throws {
        let slowTool = try Tool<NoopParams, NoopOutput, EmptyContext>(
            name: "slow",
            description: "Slow tool",
            toolTimeout: nil,
            executor: { _, _ in
                try await Task.sleep(for: .milliseconds(500))
                return NoopOutput()
            }
        )

        let firstStreamDeltas: [StreamDelta] = [
            .toolCallStart(index: 0, id: "call_1", name: "slow", kind: .function),
            .toolCallDelta(index: 0, arguments: "{}"),
            .finished(usage: TokenUsage(input: 10, output: 5)),
        ]
        let secondStreamDeltas: [StreamDelta] = [
            .content("recovered"),
            .finished(usage: TokenUsage(input: 20, output: 10)),
        ]
        let client = StreamingMockLLMClient(streamSequences: [firstStreamDeltas, secondStreamDeltas])
        let chat = Chat<EmptyContext>(client: client, tools: [slowTool], toolTimeout: .milliseconds(50))

        var events: [StreamEvent] = []
        for try await event in chat.stream("Run slow", context: EmptyContext()) {
            events.append(event)
        }

        let toolCompletedEvent = events.first { event in
            if case let .toolCallCompleted(_, name, result) = event.kind {
                return name == "slow" && result.isError && result.content.contains("timed out")
            }
            return false
        }
        #expect(toolCompletedEvent != nil)
    }
}
