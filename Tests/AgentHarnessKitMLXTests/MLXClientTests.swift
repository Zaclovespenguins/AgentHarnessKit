import Testing

#if MLX
    import AgentHarnessKit
    import AgentHarnessKitALM
    import AgentHarnessKitMLX
    import AnyLanguageModel
    import Foundation

    /// Set AHK_MLX_MODEL to a Hugging Face MLX model id (e.g. mlx-community/Qwen3-0.6B-4bit) to run the smoke test.
    private let smokeModelID = ProcessInfo.processInfo.environment["AHK_MLX_MODEL"]

    /// `MLXLanguageModel.init` touches Metal; `swift build` does not compile MLX's metallib, so these
    /// only run with AHK_MLX_RUNTIME=1 in a build that has it (xcodebuild). They always type-check the API.
    private let mlxRuntimeAvailable = ProcessInfo.processInfo.environment["AHK_MLX_RUNTIME"] == "1"

    @Suite(.enabled(if: mlxRuntimeAvailable, "AHK_MLX_RUNTIME not set; MLX metallib unavailable under swift build"))
    struct MLXClientConstructionTests {
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
    @Suite(
        .serialized,
        .enabled(if: mlxRuntimeAvailable && smokeModelID != nil, "AHK_MLX_RUNTIME/AHK_MLX_MODEL not set")
    )
    struct MLXSmokeTests {
        @Test func generatesAndStreams() async throws {
            let client = HarnessModelClient(mlxModel: MLXLanguageModel(modelId: smokeModelID ?? ""))
            let history: [ChatMessage] = [.system("Be terse."), .user("Say hello.")]
            let message = try await client.generate(messages: history, tools: [])
            #expect(!message.content.isEmpty)

            var text = ""
            var finished = false
            for try await delta in client.stream(messages: history, tools: [], requestContext: nil) {
                if case let .content(chunk) = delta {
                    text += chunk
                }
                if case .finished = delta {
                    finished = true
                }
            }
            #expect(!text.isEmpty)
            #expect(finished)
        }
    }
#endif

/// Keeps this test bundle non-empty when the MLX trait is off.
@Test func mlxTestTargetBuilds() {}
