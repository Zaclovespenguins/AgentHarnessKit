import Testing

#if canImport(FoundationModels)
    import AgentHarnessKit
    import AgentHarnessKitALM
    import AgentHarnessKitFoundationModels
    import AnyLanguageModel
    import Foundation

    /// True only on an OS 26+ device with Apple Intelligence enabled and the model downloaded.
    private let onDeviceModelAvailable: Bool = {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel().availability {
            return true
        }
        return false
    }()

    private let addTool = ToolDefinition(
        name: "add",
        description: "Add two integers and return the sum.",
        parametersSchema: .object(
            properties: ["a": .integer(description: "first addend"), "b": .integer(description: "second addend")],
            required: ["a", "b"]
        )
    )

    struct FoundationModelsClientConstructionTests {
        @Test func defaultInitUsesFoundationModelsIdentity() {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            let client = FoundationModelsClient()
            #expect(client.providerIdentifier == .foundationModels)
            #expect(client.replaySubstrate == nil)
            #expect(client.contextWindowSize == client.model.contextSize)
        }

        @Test func explicitModelAndOptionsArePassedThrough() {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            let model = SystemLanguageModel(useCase: .general)
            let client = HarnessModelClient(foundationModel: model, options: GenerationOptions(temperature: 0.2))
            #expect(client.options.temperature == 0.2)
            #expect(client.contextWindowSize == model.contextSize)
            #expect(client.providerIdentifier == .foundationModels)
        }

        @Test func checkAvailabilityMatchesModelAvailability() {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            let client = FoundationModelsClient()
            switch client.model.availability {
            case .available:
                #expect(throws: Never.self) { try client.checkAvailability() }
            case .unavailable:
                #expect {
                    try client.checkAvailability()
                } throws: { error in
                    guard case let .llmError(.other(message)) = error as? AgentError else { return false }
                    return message.hasPrefix("Foundation Models unavailable")
                }
            }
        }
    }

    /// On-device smoke tests. Skipped (NOT RUN) where Apple Intelligence is unavailable.
    @Suite(.serialized, .enabled(if: onDeviceModelAvailable, "Apple Intelligence model not available"))
    struct FoundationModelsOnDeviceSmokeTests {
        private let history: [ChatMessage] = [
            .system("You are terse. Answer in one short sentence."),
            .user("Say hello."),
        ]

        @Test func generatesText() async throws {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            let message = try await FoundationModelsClient().generate(messages: history, tools: [])
            #expect(!message.content.isEmpty)
            #expect(message.toolCalls.isEmpty)
        }

        @Test func streamsTextThenFinishes() async throws {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            var text = ""
            var finished = false
            for try await delta in FoundationModelsClient().stream(messages: history, tools: [], requestContext: nil) {
                switch delta {
                case let .content(chunk): text += chunk
                case .finished: finished = true
                default: break
                }
            }
            #expect(!text.isEmpty)
            #expect(finished)
        }

        @Test func toolCallIsReturnedUnexecuted() async throws {
            guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }
            let messages: [ChatMessage] = [
                .system("Always use the add tool for arithmetic. Never compute sums yourself."),
                .user("What is 2 + 3? Use the add tool."),
            ]
            let message = try await FoundationModelsClient().generate(messages: messages, tools: [addTool])
            let call = try #require(message.toolCalls.first)
            #expect(call.name == "add")
            let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Int]
            #expect(args == ["a": 2, "b": 3])
        }
    }
#endif

/// Keeps this test bundle non-empty where FoundationModels is unavailable (Linux).
@Test func foundationModelsTestTargetBuilds() {}
