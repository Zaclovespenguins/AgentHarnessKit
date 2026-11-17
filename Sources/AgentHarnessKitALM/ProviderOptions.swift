import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// Applies `RequestContext` provider options that ALM exposes only through per-model custom options.
enum ProviderOptions {
    private typealias ALMJSON = AnyLanguageModel.JSONValue

    static func apply(
        _ requestContext: RequestContext?,
        modelType: (some LanguageModel).Type,
        to options: inout GenerationOptions
    ) throws {
        guard let requestContext else {
            return
        }
        let extraFields = requestContext.extraFields.mapValues(almJSON)

        if modelType == OpenAILanguageModel.self {
            try applyOpenAI(requestContext, extraFields: extraFields, to: &options)
        } else if modelType == AnthropicLanguageModel.self {
            applyAnthropic(requestContext, extraFields: extraFields, to: &options)
        } else if modelType == OpenResponsesLanguageModel.self {
            try applyOpenResponses(requestContext, extraFields: extraFields, to: &options)
        } else if modelType == GeminiLanguageModel.self {
            try applyGemini(requestContext, extraFields: extraFields, to: &options)
        } else {
            try applyOther(extraFields: extraFields)
        }
    }

    private static func applyOpenAI(
        _ requestContext: RequestContext,
        extraFields: [String: ALMJSON],
        to options: inout GenerationOptions
    ) throws {
        var custom = options[custom: OpenAILanguageModel.self] ?? OpenAILanguageModel.CustomGenerationOptions()
        var extraBody = custom.extraBody ?? [:]
        if let chat = requestContext.openAIChat {
            if let parallelToolCalls = chat.parallelToolCalls {
                custom.parallelToolCalls = parallelToolCalls
            }
            if !chat.customTools.isEmpty {
                throw unsupported("OpenAI custom tools")
            }
            if let toolChoice = chat.toolChoice {
                switch toolChoice {
                case .none: extraBody["tool_choice"] = .string("none")
                case .auto: extraBody["tool_choice"] = .string("auto")
                case .required: extraBody["tool_choice"] = .string("required")
                case let .function(name):
                    extraBody["tool_choice"] = .object([
                        "type": .string("function"),
                        "function": .object(["name": .string(name)]),
                    ])
                case .custom, .allowedTools:
                    throw unsupported("OpenAI custom/allowed tool choice")
                }
            }
        }
        // extraFields are merged last so they win on key collision.
        extraBody.merge(extraFields) { _, new in new }
        custom.extraBody = extraBody
        options[custom: OpenAILanguageModel.self] = custom
    }

    private static func applyAnthropic(
        _ requestContext: RequestContext,
        extraFields: [String: ALMJSON],
        to options: inout GenerationOptions
    ) {
        var custom = options[custom: AnthropicLanguageModel.self] ?? AnthropicLanguageModel.CustomGenerationOptions()
        var extraBody = custom.extraBody ?? [:]
        if let toolChoice = requestContext.anthropic?.toolChoice {
            extraBody["tool_choice"] = anthropicToolChoiceJSON(toolChoice)
        }
        extraBody.merge(extraFields) { _, new in new }
        custom.extraBody = extraBody
        options[custom: AnthropicLanguageModel.self] = custom
    }

    private static func applyOpenResponses(
        _ requestContext: RequestContext,
        extraFields: [String: ALMJSON],
        to options: inout GenerationOptions
    ) throws {
        if let hostedTools = requestContext.responses?.hostedTools, !hostedTools.isEmpty {
            throw unsupported("Responses hosted tools")
        }
        var custom = options[custom: OpenResponsesLanguageModel.self]
            ?? OpenResponsesLanguageModel.CustomGenerationOptions()
        var extraBody = custom.extraBody ?? [:]
        extraBody.merge(extraFields) { _, new in new }
        custom.extraBody = extraBody
        options[custom: OpenResponsesLanguageModel.self] = custom
    }

    private static func applyGemini(
        _ requestContext: RequestContext,
        extraFields: [String: ALMJSON],
        to options: inout GenerationOptions
    ) throws {
        if let gemini = requestContext.gemini {
            if gemini.allowedFunctionNames != nil {
                throw unsupported("Gemini function calling mode")
            }
            switch gemini.functionCallingMode {
            case .auto: break
            case .any: options.toolCallingMode = .required
            case .none: options.toolCallingMode = .disallowed
            case .validated: throw unsupported("Gemini function calling mode")
            }
        }
        // ALM's Gemini custom options have no extra-body field.
        if !extraFields.isEmpty {
            throw unsupported("Gemini extraFields")
        }
    }

    private static func applyOther(extraFields: [String: ALMJSON]) throws {
        if !extraFields.isEmpty {
            throw unsupported("extraFields")
        }
    }

    private static func unsupported(_ feature: String) -> AgentError {
        .llmError(.featureUnsupported(provider: "AnyLanguageModel", feature: feature))
    }

    /// Raw Anthropic wire JSON for `tool_choice`; ALM writes it into `extraBody` verbatim.
    private static func anthropicToolChoiceJSON(_ choice: AnthropicToolChoice) -> ALMJSON {
        switch choice {
        case let .auto(disableParallel):
            anthropicToolChoiceObject("auto", disableParallel: disableParallel)
        case let .any(disableParallel):
            anthropicToolChoiceObject("any", disableParallel: disableParallel)
        case let .tool(name, disableParallel):
            anthropicToolChoiceObject("tool", name: name, disableParallel: disableParallel)
        case .none:
            .object(["type": .string("none")])
        }
    }

    private static func anthropicToolChoiceObject(
        _ type: String,
        name: String? = nil,
        disableParallel: Bool
    ) -> ALMJSON {
        var object: [String: ALMJSON] = ["type": .string(type)]
        if let name {
            object["name"] = .string(name)
        }
        if disableParallel {
            object["disable_parallel_tool_use"] = .bool(true)
        }
        return .object(object)
    }

    private static func almJSON(_ value: AgentHarnessKit.JSONValue) -> ALMJSON {
        switch value {
        case let .string(string): .string(string)
        case let .int(int): .int(int)
        case let .double(double): .double(double)
        case let .bool(bool): .bool(bool)
        case .null: .null
        case let .array(array): .array(array.map(almJSON))
        case let .object(object): .object(object.mapValues(almJSON))
        }
    }
}
