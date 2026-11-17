#if MLX
    import AgentHarnessKit
    import AgentHarnessKitALM
    import AgentHarnessKitMLX
    import AnyLanguageModel
    import Foundation
    import Testing

    /// Set AHK_MLX_MODEL to a Hugging Face MLX model id (e.g. mlx-community/Qwen3-0.6B-4bit) to run the smoke test.
    private let smokeModelID = ProcessInfo.processInfo.environment["AHK_MLX_MODEL"]

    @Suite struct MLXClientConstructionTests {
        @Test func initUsesMLXIdentityAndPassesThrough() {
            let model = MLXLanguageModel(modelId: "mlx-community/fake-model")
            let client = HarnessModelClient(
                mlxModel: model,
                contextWindowSize: 4096,
                options: GenerationOptions(temperature: 0.1)
            )
            #expect(client.providerIdentifier == .mlx)
            #expect(client.contextWindowSize == 4096)
            #expect(client.replaySubstrate == nil)
            #expect(client.options.temperature == 0.1)
            #expect(client.model.modelId == "mlx-community/fake-model")
        }

        @Test func contextWindowDefaultsToNil() {
            let client: MLXClient = HarnessModelClient(mlxModel: MLXLanguageModel(modelId: "mlx-community/fake-model"))
            #expect(client.contextWindowSize == nil)
        }
    }

    /// Downloads and runs a real model. NOT RUN unless AHK_MLX_MODEL is set.
    @Suite(.serialized, .enabled(if: smokeModelID != nil, "AHK_MLX_MODEL not set"))
    struct MLXSmokeTests {
        @Test func generatesAndStreams() async throws {
            let client = HarnessModelClient(mlxModel: MLXLanguageModel(modelId: smokeModelID ?? ""))
            let history: [ChatMessage] = [.system("Be terse."), .user("Say hello.")]
            let message = try await client.generate(messages: history, tools: [])
            #expect(!message.content.isEmpty)

            var text = ""
            var finished = false
            for try await delta in client.stream(messages: history, tools: [], requestContext: nil) {
                if case let .content(chunk) = delta { text += chunk }
                if case .finished = delta { finished = true }
            }
            #expect(!text.isEmpty)
            #expect(finished)
        }
    }
#endif

import Testing

/// Keeps this test bundle non-empty when the MLX trait is off.
@Test func mlxTestTargetBuilds() {}
