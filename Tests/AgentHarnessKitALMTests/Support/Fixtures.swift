import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation

typealias Entry = Transcript.Entry

let addTool = ToolDefinition(
    name: "add",
    description: "Add two integers and return the sum.",
    parametersSchema: .object(
        properties: ["a": .integer(description: "first addend"), "b": .integer(description: "second addend")],
        required: ["a", "b"]
    )
)

func jsonObject(_ string: String) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? NSDictionary
}

func jsonText(_ value: some Encodable) throws -> String {
    try String(bytes: JSONEncoder().encode(value), encoding: .utf8) ?? ""
}

/// A message after a JSON round trip, as a checkpoint would restore it.
func roundTripped(_ message: AssistantMessage) throws -> ChatMessage {
    try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage.assistant(message)))
}

func text(_ content: String) -> Transcript.Segment {
    .text(.init(content: content))
}

func usage(input: Int = 0, cached: Int = 0, output: Int = 0, reasoning: Int = 0) -> LanguageModelSession.Usage {
    .init(
        input: .init(totalTokenCount: input, cachedTokenCount: cached),
        output: .init(totalTokenCount: output, reasoningTokenCount: reasoning)
    )
}

func mockClient(_ server: MockServer) -> HarnessModelClient<OpenAILanguageModel> {
    HarnessModelClient(
        model: OpenAILanguageModel(baseURL: server.baseURL, apiKey: "fake-key", model: "mock"),
        providerIdentifier: .openAICompatible
    )
}

/// ALM's Anthropic provider only replays reasoning whose metadata names it as the origin
/// (ALM Transcript.swift `originKey`); reasoning without it is dropped from the request.
let anthropicOrigin: [String: GeneratedContent] = ["provider": GeneratedContent("anthropic")]

/// Signed thinking, then redacted thinking, then two parallel tool calls: the Anthropic turn shape
/// that must replay verbatim.
let thinkingTurn: [Entry] = [
    .reasoning(.init(metadata: anthropicOrigin, segments: [text("Let me add.")], signature: Data("sig-abc".utf8))),
    .reasoning(.init(
        metadata: anthropicOrigin.merging(["isRedacted": GeneratedContent(true)]) { $1 },
        segments: [], signature: Data("redacted-blob".utf8)
    )),
    .toolCalls(.init([
        .init(id: "toolu_1", toolName: "add", arguments: GeneratedContent(properties: ["a": 2, "b": 3])),
        .init(id: "toolu_2", toolName: "add", arguments: GeneratedContent(properties: ["a": 4, "b": 5])),
    ])),
]
