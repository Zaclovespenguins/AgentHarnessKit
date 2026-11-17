import AgentHarnessKit
import AgentHarnessKitALM
import AnyLanguageModel

#if MLX
/// `HarnessModelClient` over AnyLanguageModel's MLX backend (Apple Silicon, MLX trait).
public typealias MLXClient = HarnessModelClient<MLXLanguageModel>

extension HarnessModelClient where Model == MLXLanguageModel {
    /// providerIdentifier = .mlx, replaySubstrate = nil; contextWindowSize passed through.
    public init(
        mlxModel: MLXLanguageModel,
        contextWindowSize: Int? = nil,
        options: GenerationOptions = GenerationOptions()
    ) {
        self.init(
            model: mlxModel,
            providerIdentifier: .mlx,
            contextWindowSize: contextWindowSize,
            replaySubstrate: nil,
            options: options
        )
    }
}
#endif
