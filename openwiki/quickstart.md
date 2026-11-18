---
type: guide
title: Quickstart
description: Task-routing entry point for AgentHarnessKit. Maps each kind of change to the module, wiki page, and test target to read first, and lists the commands to run before a change lands.
tags: [quickstart, navigation, routing, swift-package, onboarding]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-012f2c78e3b1446dfc35803f
    resource: repo://Makefile
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Quickstart

AgentHarnessKit is a Swift package with one core library and several optional products. Start with the [overview](architecture/overview.md) for the product map. Then use the routing table below to find the page and tests for your change.

## Products

- `AgentHarnessKit` is the core: the agent loop, streaming, checkpointing, messages, and tools.
- `AgentHarnessKitALM` adapts AnyLanguageModel providers to the core `LLMClient` protocol.
- `AgentHarnessKitContext` is the hierarchical context store with GRDB persistence.
- `AgentHarnessKitMCP` connects to Model Context Protocol servers and wraps their tools.
- `AgentHarnessKitTesting` provides `TestLLMClient` for offline runs.
- `AgentHarnessKitFoundationModels` and `AgentHarnessKitMLX` are on-device adapters. The MLX adapter compiles only with the `MLX` package trait.

## Where to read first

| If you are changing | Read | Main tests |
|---|---|---|
| Turn loop, iteration limits, completion, tool execution order | [Agent loop](architecture/agent-loop.md) | `Tests/AgentHarnessKitTests/Core/AgentLoop` |
| Streaming events, replay, cursors | [Streaming](architecture/streaming.md) | `Tests/AgentHarnessKitTests/Core/Streaming` |
| Checkpoints, resume, MCP binding checks | [Checkpointing](architecture/checkpointing.md) | `Tests/AgentHarnessKitTests/Core/Checkpointing` |
| Message and history types, chat wire shapes | [Messages and history](architecture/messages-and-history.md) | `Tests/AgentHarnessKitTests/Messages` |
| Tool definitions, schema generation, tool results | [Tools and schema](architecture/tools-and-schema.md) | `Tests/AgentHarnessKitTests/Tools` |
| Context compression, folding, nudges, persistence | [Hierarchical context store](context/hierarchical-context-store.md) | `Tests/AgentHarnessKitContextTests` |
| AnyLanguageModel provider mapping and errors | [AnyLanguageModel adapter](integrations/alm-adapter.md) | `Tests/AgentHarnessKitALMTests` |
| MCP servers, transports, tool discovery | [MCP integration](integrations/mcp.md) | `Tests/AgentHarnessKitMCPTests` |
| Foundation Models or MLX adapters | [Local model adapters](integrations/local-model-adapters.md) | `Tests/AgentHarnessKitFoundationModelsTests`, `Tests/AgentHarnessKitMLXTests` |
| Offline test doubles | [Testing support](integrations/testing-support.md) | `Tests/AgentHarnessKitTests/Support` |

For the testing approach across targets, read the [test strategy](testing/test-strategy.md).

## Before you commit

Run these from the repository root:

- `make check` runs the format check, SwiftLint in strict mode, and the test suite with warnings as errors. This is the closest local match to CI.
- `make dev-check` applies SwiftFormat and then runs lint and tests. Use it while editing, because it rewrites files.
- `make acceptance` runs the release acceptance script. It checks the CI configuration, docs, and committed secrets.

CI also runs a Linux build in the `swift:6.3` Docker image, an iOS Simulator test job, and live provider tests when repository secrets are set. See [build and CI](operations/build-and-ci.md) for the full matrix and [gates and acceptance](operations/gates-and-acceptance.md) for the GRDB gate and the acceptance checks.

## Notes for contributors

- Do not hand-edit files under `openwiki/` that OpenWiki generates. Regenerate them through the OpenWiki lifecycle.
- The ROADMAP and planning documents describe intent. Treat source and tests as the authority on current behavior.
