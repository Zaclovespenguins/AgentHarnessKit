---
type: integration
title: Local Model Adapters
description: The AgentHarnessKitFoundationModels and AgentHarnessKitMLX products, which are thin typealiases and initializers over HarnessModelClient for Apple's on-device system model and AnyLanguageModel's MLX backend, and how the MLX trait and platform availability decide whether each adapter compiles.
tags: [foundation-models, mlx, on-device, traits, conditional-compilation, llm-client]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
  - id: openwiki-source-586c5687d5ea0028f26787e6
    resource: repo://Sources/AgentHarnessKitFoundationModels/FoundationModelsClient.swift
  - id: openwiki-source-f97bfaa86d96d12ddd864e07
    resource: repo://Sources/AgentHarnessKitMLX/MLXClient.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Local Model Adapters

Two products wrap on-device model backends for the harness. Both are small. They do not contain their own request, streaming, or error logic. Each one is a typealias and a convenience initializer over `HarnessModelClient` from the [AnyLanguageModel adapter](alm-adapter.md), specialized for one ALM model type.

- `AgentHarnessKitFoundationModels` wraps Apple's on-device `SystemLanguageModel`.
- `AgentHarnessKitMLX` wraps ALM's `MLXLanguageModel`, which runs MLX models on Apple Silicon.

Both products depend on `AgentHarnessKit` and `AgentHarnessKitALM` and on the `AnyLanguageModel` product (`Package.swift`, targets `AgentHarnessKitFoundationModels` and `AgentHarnessKitMLX`).

## Foundation Models adapter

`Sources/AgentHarnessKitFoundationModels/FoundationModelsClient.swift` is compiled only when `canImport(FoundationModels)` is true, and the declarations are marked `@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)`. The file defines:

- `typealias FoundationModelsClient = HarnessModelClient<SystemLanguageModel>` (line 8).
- An initializer `init(foundationModel:options:)` on `HarnessModelClient where Model == SystemLanguageModel` (lines 10-24). It uses `.foundationModels` as the provider identifier, takes the context window size from `foundationModel.contextSize`, and sets no replay substrate.
- `checkAvailability()` (lines 26-31). It reads `model.availability` and throws `AgentError.llmError(.other("Foundation Models unavailable: ..."))` when the model is unavailable.

The package's own platform floor is macOS 14 and iOS 17 (`Package.swift`, `platforms`). The Foundation Models declarations are therefore available only on the newer OS versions. On older platforms or SDKs that lack the framework, the file contributes no symbols, and the product compiles empty.

## MLX adapter

`Sources/AgentHarnessKitMLX/MLXClient.swift` is compiled only under `#if MLX`. That condition is set by the package's `MLX` trait. The trait is declared in `Package.swift` and is off by default (`traits: [.trait(name: "MLX"), .default(enabledTraits: [])]`). The trait also turns on ALM's own `MLX` trait, through the conditional dependency on AnyLanguageModel:

```swift
.package(
    url: "https://github.com/huggingface/AnyLanguageModel",
    .upToNextMinor(from: "1.3.0"),
    traits: [.trait(name: "MLX", condition: .when(traits: ["MLX"]))]
)
```

When the trait is enabled, the file defines:

- `typealias MLXClient = HarnessModelClient<MLXLanguageModel>` (line 7).
- `init(mlxModel:contextWindowSize:options:)` on `HarnessModelClient where Model == MLXLanguageModel` (lines 9-24). It uses `.mlx` as the provider identifier, passes the context window size through, and sets no replay substrate.

Without the trait, the product compiles empty. The package comment describes this as Apple Silicon only.

## How the traits gate compilation

Two gates control what gets built:

| Adapter | Compile gate | Platform or dependency gate |
|---|---|---|
| FoundationModels | `canImport(FoundationModels)` | `@available` for macOS 26 and iOS 26 |
| MLX | `#if MLX` (the `MLX` trait) | Apple Silicon; the trait also enables ALM's MLX trait |

Because the MLX trait changes which AnyLanguageModel traits are resolved, enabling it changes the dependency graph, not only the adapter. The default build does not include the MLX backend.

## Tests

- `Tests/AgentHarnessKitFoundationModelsTests/FoundationModelsClientTests.swift` is wrapped in `#if canImport(FoundationModels)`. It checks the default identity, pass-through of an explicit model and options, that `checkAvailability` matches `model.availability`, text generation, streaming, and that a tool call is returned unexecuted. A placeholder test, `foundationModelsTestTargetBuilds`, runs on every platform so the target always has a test.
- `Tests/AgentHarnessKitMLXTests/MLXClientTests.swift` is wrapped in `#if MLX`. It checks the MLX identity and pass-through, that the context window defaults to nil, and generation and streaming. A placeholder test, `mlxTestTargetBuilds`, is defined outside the guard.

Tests that need a real model, such as generation and streaming, depend on the on-device or MLX runtime being present. The unguarded placeholder tests are the only checks that run everywhere.

## Operational consequences

- Calling these adapters on an unsupported OS version fails to compile, not at runtime. A call site has to be guarded with the same availability.
- `checkAvailability()` is the only runtime check. A caller that skips it finds out about an unavailable on-device model when the first request fails, as an `llmError`.
- Neither adapter uses a replay substrate, so reasoning turns are rebuilt from semantic fields rather than replayed verbatim (see [AnyLanguageModel adapter](alm-adapter.md)).

## Related pages

- [AnyLanguageModel adapter](alm-adapter.md) contains the request, streaming, and error logic these adapters reuse.
- [Overview](../architecture/overview.md) lists the products and the package traits.
