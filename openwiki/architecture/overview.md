---
type: architecture
title: Architecture Overview
description: Package layering of AgentHarnessKit, with the dependency-free core target and its adapter targets for ALM, Context (GRDB), MCP, Testing, Apple Foundation Models and MLX, plus the MLX trait and platform floors declared in Package.swift.
tags: [architecture, package, targets, traits, dependencies, swift]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Architecture Overview

AgentHarnessKit is a Swift package that splits one agent runtime from the integrations around it. The core target owns the message model, tools, the agent loop, streaming, checkpointing, and sub-agents. Every provider, database, and platform integration sits in a separate library product that depends on the core. The layering is declared in `Package.swift`, which is the authoritative source for what ships.

## Layers

`Package.swift` declares swift-tools 6.3 with the Swift 6 language mode applied to every target (`Package.swift:1-11`). The platform floors are macOS 14 and iOS 17 (`Package.swift:14-17`).

| Layer | Product | Target | Depends on |
| --- | --- | --- | --- |
| Core | `AgentHarnessKit` | `AgentHarnessKit` | none (no package dependencies) |
| Provider transport | `AgentHarnessKitALM` | `AgentHarnessKitALM` | core, AnyLanguageModel |
| Apple Foundation Models | `AgentHarnessKitFoundationModels` | `AgentHarnessKitFoundationModels` | core, ALM, AnyLanguageModel |
| MLX | `AgentHarnessKitMLX` | `AgentHarnessKitMLX` | core, ALM, AnyLanguageModel |
| Context storage | `AgentHarnessKitContext` | `AgentHarnessKitContext` | core, GRDB |
| MCP | `AgentHarnessKitMCP` | `AgentHarnessKitMCP` | core |
| Testing support | `AgentHarnessKitTesting` | `AgentHarnessKitTesting` | core |

The core target's comment says it has "no provider, database or Apple-only dependency" (`Package.swift:44-45`). The adapter targets are the only places where ALM, GRDB, or MCP-specific code is allowed. Checking that rule means reading the `dependencies` arrays in `Package.swift`, not the source tree.

## Package dependencies

- **AnyLanguageModel 1.3.0** (`huggingface/AnyLanguageModel`) is pinned with `.upToNextMinor(from: "1.3.0")` (`Package.swift:35-39`). It is used only by the ALM, Foundation Models, and MLX targets.
- **GRDB 7.12.0** (`groue/grdb.swift`) is pinned with `.upToNextMajor(from: "7.12.0")` (`Package.swift:41`). It is used only by the Context target.

The comments in `Package.swift` give the reason for the separation. The ALM dependency is "provider and transport layer for AgentHarnessKitALM only", and the GRDB dependency is for "AgentHarnessKitContext only". Each dependency therefore enters the build graph only when its product is used.

## Traits

Two traits control optional code (`Package.swift:27-31`):

- `MLX` is opt-in. Its comment describes it as enabling ALM's MLX trait and the `AgentHarnessKitMLX` adapter, which is Apple Silicon only.
- The default trait set is empty (`enabledTraits: []`).

The MLX dependency is wired by a conditional trait on AnyLanguageModel: `traits: [.trait(name: "MLX", condition: .when(traits: ["MLX"]))]` (`Package.swift:38`). The `AgentHarnessKitMLX` target compiles to nothing unless the trait is enabled. The Foundation Models target similarly compiles empty where FoundationModels is unavailable (`Package.swift:58`).

## Test and probe targets

The test targets mirror the layers: `AgentHarnessKitTests`, `AgentHarnessKitContextTests`, `AgentHarnessKitMCPTests`, `AgentHarnessKitALMTests`, `AgentHarnessKitFoundationModelsTests`, and `AgentHarnessKitMLXTests`. The core test target also depends on the `CheckpointResumeProbe` executable target (`Package.swift:100-103`). That executable is a child process for the cross-process resume test and is not a product (`Package.swift:93-97`). See [Checkpointing and resume](checkpointing.md).

## Where to read next

- [Agent loop](agent-loop.md) covers the core execution path.
- [Messages and history](messages-and-history.md) covers the canonical message model.
- [ALM adapter](../integrations/alm-adapter.md) covers the only provider transport in the package.
- [Build and CI](../operations/build-and-ci.md) covers how these targets are built and tested.

The repository's `docs/ARCHITECTURE.md` is a Phase 0 decision record. It describes the provider-transport decision and the GRDB gate results. Those are decision history, so this page takes the current structure from `Package.swift` instead.
