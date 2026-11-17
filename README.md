# AgentHarnessKit

AgentHarnessKit is a Swift package for building tool-using LLM agents. It matches the feature set of [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit) 6.1.0 (agent loop, typed tools, streaming, tool approval, checkpoint and resume, sub-agents, context management) and runs on iOS, macOS and Linux. The harness owns the message history, executes tools and decides when to stop. Provider transport comes from [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel), which sends one request per iteration with tools declared but never auto-executed. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

**Platforms:** macOS 14+, iOS 17+, Linux. **Swift:** 6.3 (Swift 6 language mode, strict concurrency). The Apple Foundation Models adapter also needs macOS 26 or iOS 26 at runtime.

**Status:** pre-release. See [ROADMAP.md](ROADMAP.md) for what is done and what is still open, and [CHANGELOG.md](CHANGELOG.md) for known gaps.

## Installation

Add the package to your `Package.swift` and depend on the products you need:

```swift
dependencies: [
    .package(url: "https://github.com/zaclovespenguins/agentharnesskit", from: "0.2.0"),
],
targets: [
    .target(
        name: "MyAgent",
        dependencies: [
            .product(name: "AgentHarnessKit", package: "AgentHarnessKit"),
            .product(name: "AgentHarnessKitALM", package: "AgentHarnessKit"),
        ]
    ),
]
```

To name ALM types such as `OpenAILanguageModel` in your own code, also declare `AnyLanguageModel` (`https://github.com/huggingface/AnyLanguageModel`, `.upToNextMinor(from: "1.3.0")`) and add `.product(name: "AnyLanguageModel", package: "AnyLanguageModel")` to your target.

## Products

| Product | What it provides |
| --- | --- |
| `AgentHarnessKit` | Core, with no provider or database dependency: messages, typed tools, `Agent` and `Chat`, streaming, tool approval, checkpointing and sub-agents. Defines the `LLMClient` seam. |
| `AgentHarnessKitALM` | `HarnessModelClient`, an `LLMClient` over any AnyLanguageModel `LanguageModel` (OpenAI-compatible endpoints, Anthropic, Gemini, Ollama and others). |
| `AgentHarnessKitContext` | `HierarchicalContextStore` for context management, with `InMemoryContextPersistence` or GRDB-backed `GRDBContextPersistence`. |
| `AgentHarnessKitMCP` | `MCPClient` for Model Context Protocol servers over stdio (`StdioMCPTransport`) or HTTP (`HTTPMCPTransport`). |
| `AgentHarnessKitTesting` | `TestLLMClient`, a scripted `LLMClient` for deterministic loop tests. |
| `AgentHarnessKitFoundationModels` | `FoundationModelsClient` for Apple's on-device model. Apple platforms only; compiles empty elsewhere. |
| `AgentHarnessKitMLX` | `MLXClient` over AnyLanguageModel's MLX backend. Apple Silicon only, and requires the `MLX` trait. |

**Traits.** `MLX` is an opt-in package trait and is off by default. It enables the MLX backend in ALM and compiles `AgentHarnessKitMLX`. Enable it on your dependency with `traits: ["MLX"]`.

## Quick start

This runs one tool-using turn against an OpenAI-compatible endpoint. It mirrors the end-to-end test in `Tests/AgentHarnessKitALMTests/AgentOverAdapterTests.swift`.

```swift
import AgentHarnessKit
import AgentHarnessKitALM
import AnyLanguageModel

struct AddParams: Codable, SchemaProviding {
    let a: Int
    let b: Int
}

let client = HarnessModelClient(
    model: OpenAILanguageModel(
        baseURL: URL(string: "http://localhost:8080/v1")!, apiKey: "none", model: "default"
    ),
    providerIdentifier: .openAICompatible
)

let add = try Tool<AddParams, String, EmptyContext>(
    name: "add", description: "Add two integers and return the sum.",
    executor: { params, _ in "\(params.a + params.b)" }
)

let agent = Agent<EmptyContext>(client: client, tools: [add])
let result = try await agent.run(userMessage: "What is 2 + 3?", context: EmptyContext())
print(result.content ?? "")
```

`Agent` executes the tool, sends the result back, and finishes through the built-in `finish` tool. `run` returns an `AgentResult` with `content`, `finishReason`, `iterations` and `totalTokenUsage`. Use `agent.stream(...)` for incremental events.

## Tool approval

Set `approvalPolicy` in `AgentConfiguration` to choose which tools need a decision. `ToolApprovalQueue` is a ready-made approval handler: pass `queue.handler` to the stream, watch `queue.updates` for parked requests, and resolve each one from your UI. Requests resolve in any order, and `denyAll(reason:)` clears whatever is still waiting, so a Stop button should call it before cancelling the stream. A single run asks one approval at a time; several requests only pile up when runs share a queue.

```swift
let queue = ToolApprovalQueue()
let agent = Agent<EmptyContext>(client: client, tools: [add],
                                configuration: AgentConfiguration(approvalPolicy: .allTools))
let stream = AgentStream(agent: agent)
stream.send("What is 2 + 3?", context: EmptyContext(), approvalHandler: queue.handler)

// From the UI, for a request you were shown:
_ = await queue.resolve(id: request.toolCallId, decision: .approve)
```

## Development

Requirements: Xcode with Swift 6.3, and Homebrew for the lint tools.

```sh
make bootstrap   # installs Mint, then the pinned SwiftFormat and SwiftLint from the Mintfile
make build       # swift build
make test        # swift test
make check       # format-check, lint and test with -warnings-as-errors; matches CI
make dev-check   # format (rewrites files), lint and test
```

**Live provider tests.** `LiveEndpointTests` calls a real OpenAI-compatible endpoint. It is skipped unless `AHK_LIVE_BASE_URL` is set:

```sh
AHK_LIVE_BASE_URL=http://localhost:8080/v1 \
AHK_LIVE_MODEL=my-model \
AHK_LIVE_API_KEY=<your key, optional> \
swift test --filter LiveEndpointTests
```

`AHK_LIVE_MODEL` and `AHK_LIVE_API_KEY` are optional. Never commit a key.

**iOS build.** ALM's Swift macros trigger Xcode's macro trust prompt, which CI cannot answer. Pass `-skipMacroValidation`:

```sh
xcodebuild -scheme AgentHarnessKit-Package -destination 'generic/platform=iOS Simulator' -skipMacroValidation build
```

## Documentation

- [docs/README.md](docs/README.md): documentation index
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): design decisions and spike evidence
- [ROADMAP.md](ROADMAP.md): phased work plan
- [AGENTHARNESSKIT_PARITY_SPEC.md](AGENTHARNESSKIT_PARITY_SPEC.md): behavioral parity spec with AgentRunKit
- [CHANGELOG.md](CHANGELOG.md): release notes and known gaps

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE), which credits AgentRunKit.
