import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private struct Boom: Error {}

struct ErrorMappingTests {
    @Test func cancellationPassesThrough() {
        #expect(ErrorMapping.agentError(from: CancellationError(), provider: .anthropic) is CancellationError)
        #expect(ErrorMapping.agentError(from: URLError(.cancelled), provider: .anthropic) is CancellationError)
    }

    @Test func agentErrorPassesThrough() {
        let original = AgentError.llmError(.noChoices)
        #expect(ErrorMapping.agentError(from: original, provider: .openAI) as? AgentError == original)
    }

    @Test func urlErrorBecomesNetworkError() {
        let mapped = ErrorMapping.agentError(from: URLError(.timedOut), provider: .openAI) as? AgentError
        #expect(mapped == .llmError(.networkError(code: .timedOut, description: "URL request failed")))
    }

    @Test func codingAndUnknownErrors() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "bad")
        guard case .llmError(.decodingFailed) = ErrorMapping.agentError(
            from: DecodingError.dataCorrupted(context), provider: .openAI
        ) as? AgentError else {
            Issue.record("expected decodingFailed")
            return
        }
        guard case .llmError(.other) = ErrorMapping.agentError(from: Boom(), provider: .openAI) as? AgentError
        else {
            Issue.record("expected other")
            return
        }
    }
}

struct ProviderOptionsTests {
    private func unsupported(_ body: () throws -> Void) -> Bool {
        do { try body() } catch AgentError.llmError(.featureUnsupported) { return true } catch {}
        return false
    }

    @Test func nilContextChangesNothing() throws {
        var options = GenerationOptions()
        try ProviderOptions.apply(nil, modelType: OpenAILanguageModel.self, to: &options)
        #expect(options[custom: OpenAILanguageModel.self] == nil)
    }

    @Test func openAIOptionsPreserveExistingCustomOptions() throws {
        var options = GenerationOptions()
        options[custom: OpenAILanguageModel.self] = .init(seed: 7)
        let context = RequestContext(
            extraFields: ["foo": .int(1)],
            openAIChat: .init(toolChoice: .function(name: "add"), parallelToolCalls: false)
        )
        try ProviderOptions.apply(context, modelType: OpenAILanguageModel.self, to: &options)
        let custom = try #require(options[custom: OpenAILanguageModel.self])
        #expect(custom.seed == 7)
        #expect(custom.parallelToolCalls == false)
        #expect(custom.extraBody?["foo"] == .int(1))
        let choice = try jsonText(custom.extraBody?["tool_choice"])
        #expect(jsonObject(choice) == ["type": "function", "function": ["name": "add"]])
    }

    @Test func anthropicToolChoiceAndExtraFields() throws {
        var options = GenerationOptions()
        let context = RequestContext(
            extraFields: ["top_k": .int(5)],
            openAIChat: .init(parallelToolCalls: false),
            anthropic: .init(toolChoice: .tool(name: "add", disableParallel: true))
        )
        try ProviderOptions.apply(context, modelType: AnthropicLanguageModel.self, to: &options)
        let custom = try #require(options[custom: AnthropicLanguageModel.self])
        #expect(custom.extraBody?["top_k"] == .int(5))
        let choice = try jsonText(custom.extraBody?["tool_choice"])
        #expect(jsonObject(choice) == ["type": "tool", "name": "add", "disable_parallel_tool_use": true])
        // Options for another provider are ignored.
        #expect(options[custom: OpenAILanguageModel.self] == nil)
    }

    @Test func unsupportedOptionsThrowInsteadOfVanishing() {
        #expect(unsupported {
            var options = GenerationOptions()
            let context = RequestContext(openAIChat: .init(toolChoice: .custom(name: "x")))
            try ProviderOptions.apply(context, modelType: OpenAILanguageModel.self, to: &options)
        })
        #expect(unsupported {
            var options = GenerationOptions()
            let context = RequestContext(openAIChat: .init(customTools: [.init(name: "x")]))
            try ProviderOptions.apply(context, modelType: OpenAILanguageModel.self, to: &options)
        })
        #expect(unsupported {
            var options = GenerationOptions()
            let context = RequestContext(responses: .init(hostedTools: [.webSearch()]))
            try ProviderOptions.apply(context, modelType: OpenResponsesLanguageModel.self, to: &options)
        })
        #expect(unsupported {
            var options = GenerationOptions()
            let context = RequestContext(extraFields: ["x": .bool(true)])
            try ProviderOptions.apply(context, modelType: OllamaLanguageModel.self, to: &options)
        })
    }
}
