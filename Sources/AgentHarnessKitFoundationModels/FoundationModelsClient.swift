import AgentHarnessKit
import AgentHarnessKitALM
import AnyLanguageModel

#if canImport(FoundationModels)
    /// On-device Apple Foundation Models client.
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    public typealias FoundationModelsClient = HarnessModelClient<SystemLanguageModel>

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    public extension HarnessModelClient where Model == SystemLanguageModel {
        /// Wraps the system model; context size comes from the model itself.
        init(
            foundationModel: SystemLanguageModel = SystemLanguageModel(),
            options: GenerationOptions = GenerationOptions()
        ) {
            self.init(
                model: foundationModel,
                providerIdentifier: .foundationModels,
                contextWindowSize: foundationModel.contextSize,
                replaySubstrate: nil,
                options: options
            )
        }

        /// Throws `AgentError.llmError` when the on-device model is unavailable.
        func checkAvailability() throws {
            if case let .unavailable(reason) = model.availability {
                throw AgentError.llmError(.other("Foundation Models unavailable: \(reason)"))
            }
        }
    }
#endif
