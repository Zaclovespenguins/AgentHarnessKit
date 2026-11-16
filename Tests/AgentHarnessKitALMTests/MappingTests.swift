import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation
import Testing

private func kinds(_ transcript: Transcript) -> [String] {
    transcript.map {
        switch $0 {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .reasoning: "reasoning"
        case .response: "response"
        }
    }
}

struct TranscriptMappingTests {
    @Test func historyMapsInOrder() throws {
        let call = ToolCall(id: "c1", name: "add", arguments: #"{"a":2,"b":3}"#)
        let transcript = try TranscriptMapping.transcript(
            from: [
                .system("be brief"), .user("2+3?"),
                .assistant(AssistantMessage(content: "calling", toolCalls: [call])),
                .tool(id: "c1", name: "add", content: "5"),
            ],
            replaySubstrate: nil
        )
        #expect(kinds(transcript) == ["instructions", "prompt", "response", "toolCalls", "toolOutput"])
        guard case let .toolCalls(calls) = transcript[3], case let .toolOutput(output) = transcript[4] else {
            Issue.record("unexpected entries")
            return
        }
        #expect(calls.count == 1)
        #expect(calls[0].id == "c1")
        #expect(calls[0].toolName == "add")
        #expect(jsonObject(calls[0].arguments.jsonString) == ["a": 2, "b": 3])
        #expect(output.id == "c1")
        #expect(output.toolName == "add")
        #expect("\(output.segments)".contains("5"))
    }

    @Test func emptyContentAndEmptyArgumentsAreHandled() throws {
        let call = ToolCall(id: "c1", name: "noop", arguments: "")
        let transcript = try TranscriptMapping.transcript(
            from: [.assistant(AssistantMessage(content: "", toolCalls: [call]))], replaySubstrate: nil
        )
        #expect(kinds(transcript) == ["toolCalls"])
    }

    @Test func reasoningPrecedesToolCallsAndKeepsSignature() throws {
        let message = AssistantMessage(
            content: "",
            toolCalls: [ToolCall(id: "c1", name: "add", arguments: "{}")],
            reasoning: ReasoningContent(content: "think", signature: "sig-abc")
        )
        let transcript = try TranscriptMapping.transcript(from: [.assistant(message)], replaySubstrate: nil)
        #expect(kinds(transcript) == ["reasoning", "toolCalls"])
        guard case let .reasoning(reasoning) = transcript[0] else { return }
        #expect(reasoning.signature == Data("sig-abc".utf8))
    }

    @Test func continuityReplaysVerbatimOnlyOnMatchingSubstrate() throws {
        let message = try ResponseMapping.assistantMessage(
            content: "", entries: thinkingTurn, usage: usage(), replaySubstrate: .anthropicMessages
        )
        let replayed = try TranscriptMapping.transcript(
            from: [.assistant(message)], replaySubstrate: .anthropicMessages
        )
        #expect(Array(replayed) == thinkingTurn)

        // Another substrate must not receive foreign signed blocks verbatim: rebuilt from semantic fields.
        let rebuilt = try TranscriptMapping.transcript(
            from: [.assistant(message)], replaySubstrate: .openAIChatCompletions
        )
        #expect(Array(rebuilt) != thinkingTurn)
        #expect(kinds(rebuilt) == ["reasoning", "toolCalls"])
    }

    @Test func corruptContinuityThrows() {
        let message = AssistantMessage(
            content: "x",
            continuity: AssistantContinuity(
                substrate: .anthropicMessages,
                payload: .object([TranscriptMapping.continuityEntriesKey: .string("garbage")])
            )
        )
        #expect(throws: AgentError.self) {
            try TranscriptMapping.transcript(from: [.assistant(message)], replaySubstrate: .anthropicMessages)
        }
    }

    @Test func imagesMapAndUnsupportedMediaThrows() throws {
        let transcript = try TranscriptMapping.transcript(
            from: [.user(text: "look", imageData: Data([1, 2, 3]), mimeType: "image/png")], replaySubstrate: nil
        )
        guard case let .prompt(prompt) = transcript[0] else {
            Issue.record("expected prompt")
            return
        }
        #expect(prompt.segments.count == 2)
        guard case .image = prompt.segments[1] else {
            Issue.record("expected image segment")
            return
        }
        #expect(throws: AgentError.self) {
            try TranscriptMapping.transcript(
                from: [.user(text: "watch", videoData: Data([1]))], replaySubstrate: nil
            )
        }
        #expect(throws: AgentError.self) {
            try TranscriptMapping.transcript(from: [.user(audioData: Data([1]), format: .wav)], replaySubstrate: nil)
        }
    }
}

struct ToolBridgingTests {
    @Test func schemaKeepsPropertiesAndRequired() throws {
        let schema = try ToolBridging.generationSchema(from: addTool.parametersSchema)
        let encoded = try jsonText(schema)
        let object = try #require(jsonObject(encoded))
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["a", "b"])
        #expect(Set(object["required"] as? [String] ?? []) == ["a", "b"])
    }

    @Test func nestedSchemaConverts() throws {
        let nested = JSONSchema.object(
            properties: [
                "tags": .array(items: .string()),
                "mode": .string(enumValues: ["fast", "slow"]),
                "limit": JSONSchema.integer().optional(),
                "inner": .object(properties: ["flag": .boolean()], required: ["flag"]),
            ],
            required: ["tags", "mode"]
        )
        let encoded = try jsonText(ToolBridging.generationSchema(from: nested))
        for name in ["tags", "mode", "limit", "inner", "flag", "fast", "slow"] {
            #expect(encoded.contains("\"\(name)\""))
        }
    }

    @Test func declaredToolsCarryDefinitionAndNeverExecute() async throws {
        let tools = try ToolBridging.almTools(from: [addTool])
        #expect(tools.map(\.name) == ["add"])
        #expect(tools[0].description == addTool.description)
        let declared = try #require(tools[0] as? DeclaredTool)
        await #expect(throws: AgentError.self) {
            _ = try await declared.call(arguments: GeneratedContent(properties: ["a": 1, "b": 2]))
        }
    }
}

struct ResponseMappingTests {
    @Test func zeroUsageIsNilNotZero() {
        #expect(ResponseMapping.tokenUsage(from: usage()) == nil)
    }

    @Test func usageMaps() {
        #expect(
            ResponseMapping.tokenUsage(from: usage(input: 20, cached: 7, output: 5, reasoning: 2))
                == TokenUsage(input: 20, output: 5, reasoning: 2, cacheRead: 7)
        )
        #expect(ResponseMapping.tokenUsage(from: usage(input: 20, output: 5))?.cacheRead == nil)
    }

    @Test func assistantMessageFromThinkingTurn() throws {
        let message = try ResponseMapping.assistantMessage(
            content: "", entries: thinkingTurn, usage: usage(input: 3, output: 4), replaySubstrate: .anthropicMessages
        )
        #expect(message.toolCalls.map(\.id) == ["toolu_1", "toolu_2"])
        #expect(message.toolCalls.map(\.name) == ["add", "add"])
        #expect(message.toolCalls.allSatisfy { $0.kind == .function })
        #expect(jsonObject(message.toolCalls[1].arguments) == ["a": 4, "b": 5])
        #expect(message.reasoning?.content == "Let me add.")
        #expect(message.reasoning?.signature == "redacted-blob")
        #expect(message.tokenUsage == TokenUsage(input: 3, output: 4))
        #expect(message.continuity?.substrate == .anthropicMessages)
        #expect(message.reasoningDetails == nil)
    }

    @Test func noContinuityWithoutReasoningOrSubstrate() throws {
        let plain: [Entry] = [.response(.init(assetIDs: [], segments: [text("hi")]))]
        let message = try ResponseMapping.assistantMessage(
            content: "", entries: plain, usage: usage(), replaySubstrate: .anthropicMessages
        )
        #expect(message.content == "hi")
        #expect(message.continuity == nil)
        #expect(message.reasoning == nil)
        #expect(message.tokenUsage == nil)
        #expect(try ResponseMapping.continuity(entries: thinkingTurn, substrate: nil) == nil)
    }

    @Test func explicitContentWins() throws {
        let plain: [Entry] = [.response(.init(assetIDs: [], segments: [text("from entries")]))]
        let message = try ResponseMapping.assistantMessage(
            content: "explicit", entries: plain, usage: usage(), replaySubstrate: nil
        )
        #expect(message.content == "explicit")
    }
}

struct StreamDeltaMapperTests {
    @Test func emitsOnlyNewSuffixes() {
        var mapper = StreamDeltaMapper()
        let thinking: [Entry] = [.reasoning(.init(segments: [text("hm")]))]
        let moreThinking: [Entry] = [.reasoning(.init(segments: [text("hmm ok")]))]
        #expect(mapper.deltas(content: "", entries: thinking) == [.reasoning("hm")])
        #expect(mapper.deltas(content: "Hel", entries: moreThinking) == [.reasoning("m ok"), .content("Hel")])
        #expect(mapper.deltas(content: "Hel", entries: moreThinking).isEmpty)
        #expect(mapper.deltas(content: "Hello", entries: moreThinking) == [.content("lo")])
        // A non-prefix rewrite emits nothing and does not corrupt later diffs.
        #expect(mapper.deltas(content: "He", entries: moreThinking).isEmpty)
        #expect(mapper.deltas(content: "Hello!", entries: moreThinking) == [.content("!")])
    }

    @Test func snapshotsNeverCarryToolCallDeltas() {
        var mapper = StreamDeltaMapper()
        #expect(mapper.deltas(content: "", entries: thinkingTurn) == [.reasoning("Let me add.")])
    }

    @Test func toolCallDeltasAreIndexedAcrossEntries() {
        let extra: [Entry] = [
            .toolCalls(.init([.init(id: "toolu_3", toolName: "sub", arguments: GeneratedContent(properties: [:]))])),
        ]
        let deltas = StreamDeltaMapper.toolCallDeltas(entries: thinkingTurn + extra)
        #expect(deltas.count == 6)
        #expect(deltas[0] == .toolCallStart(index: 0, id: "toolu_1", name: "add", kind: .function))
        #expect(deltas[2] == .toolCallStart(index: 1, id: "toolu_2", name: "add", kind: .function))
        #expect(deltas[4] == .toolCallStart(index: 2, id: "toolu_3", name: "sub", kind: .function))
        guard case let .toolCallDelta(index, arguments) = deltas[3] else {
            Issue.record("expected delta")
            return
        }
        #expect(index == 1)
        #expect(jsonObject(arguments) == ["a": 4, "b": 5])
        #expect(StreamDeltaMapper.toolCallDeltas(entries: []).isEmpty)
    }
}
