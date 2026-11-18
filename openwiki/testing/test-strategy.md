---
type: testing
title: Test Strategy
description: How the package's test targets are organized, which fixtures, scripted transports, and mock servers each target uses, where the Swift Testing tags and the numbered self-test files fit, and which commands run the suites locally and in CI.
tags: [testing, swift-testing, test-targets, fixtures, mock-server, self-tests, ci]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:07:55.531Z
sources:
  - id: openwiki-source-012f2c78e3b1446dfc35803f
    resource: repo://Makefile
  - id: openwiki-source-16a6a536c0a5303df5e05c6c
    resource: repo://Package.swift
  - id: openwiki-source-8d9af8b38f14fce98e79c339
    resource: repo://Tests/AgentHarnessKitALMTests/AgentOverAdapterTests.swift
  - id: openwiki-source-9c4f258ee4c028a2d4d6b02f
    resource: repo://Tests/AgentHarnessKitALMTests/HarnessModelClientTests.swift
  - id: openwiki-source-e6b2ac8a99b82b01de5a99db
    resource: repo://Tests/AgentHarnessKitMCPTests/MCPClientTests.swift
  - id: openwiki-source-6805237b319080a229868595
    resource: repo://Tests/AgentHarnessKitMCPTests/MCPToolTests.swift
  - id: openwiki-source-05ede9942b6a56b8dbe3f5d6
    resource: repo://Tests/AgentHarnessKitMCPTests/SupportSmokeTests.swift
generated: { by: "claude-code", at: "2026-11-18T22:07:55.531Z" }
---

# Test Strategy

The package uses Swift Testing (`import Testing`, `@Test`, `@Suite`) across about 116 Swift test files containing roughly 1,125 `@Test` declarations. Tests are split into one test target per product or area, plus a child-process probe for cross-process checkpoint resume. Most tests run offline, against scripted or mock dependencies. Live provider tests are the exception, and they run only when CI has credentials.

## Test targets

`Package.swift` declares the following test targets, each depending on the library it covers.

| Target | Path | Covers |
|---|---|---|
| `AgentHarnessKitTests` | `Tests/AgentHarnessKitTests` | Core loop, streaming, checkpointing, messages, tools, and the shared `Support` helpers. Depends on `AgentHarnessKitTesting` and the `CheckpointResumeProbe` executable. |
| `AgentHarnessKitContextTests` | `Tests/AgentHarnessKitContextTests` | The hierarchical context store, compression, folding, nudges, protected zones, persistence, and refs. |
| `AgentHarnessKitMCPTests` | `Tests/AgentHarnessKitMCPTests` | JSON-RPC, transports, client, session, and tool adapter, plus MCP support helpers. |
| `AgentHarnessKitALMTests` | `Tests/AgentHarnessKitALMTests` | The AnyLanguageModel adapter: mapping, errors and options, the client, and agent-over-adapter runs. Its `Support` directory holds `MockServer`, `Step`, and `MockError`. |
| `AgentHarnessKitFoundationModelsTests` | `Tests/AgentHarnessKitFoundationModelsTests` | The Foundation Models client, guarded by `canImport(FoundationModels)`. |
| `AgentHarnessKitMLXTests` | `Tests/AgentHarnessKitMLXTests` | The MLX client, guarded by `#if MLX`. |

`Tests/CheckpointResumeProbe/main.swift` is not a test target. `Package.swift` declares it as an executable target, with a comment that it is "Child process for the cross-process resume test; not a product." The test suite starts it as a child process to check resume across process boundaries (see [Checkpointing](../architecture/checkpointing.md)).

Within `AgentHarnessKitTests`, the directories follow the core layout: `Core/AgentLoop`, `Core/Checkpointing`, `Core/Context`, `Core/Streaming`, `Messages`, and `Tools`.

## Fixtures and test doubles

Tests use four kinds of doubles, and each targets a different boundary.

- **`TestLLMClient`** from the `AgentHarnessKitTesting` product. It is a deterministic model stand-in that generates tool arguments from schemas. The suites use it to run the real agent loop offline. See [Testing support](../integrations/testing-support.md).
- **Scripted transports** in the MCP suite. `ScriptedMCPTransport` and `DynamicMCPTransport` (in `Tests/AgentHarnessKitMCPTests/Support`) replay server responses in scripted or request-dependent form. Tests of the client and session use these instead of a real server process.
- **Mock HTTP.** `MockURLProtocol` intercepts `URLSession` requests, and `MockHTTPServer` runs a local HTTP server that records requests. Both are used by the HTTP transport tests and by `SupportSmokeTests`, which checks that the mock server serves and records a request.
- **Mock provider server** in the ALM suite (`Tests/AgentHarnessKitALMTests/Support/MockServer.swift`), driven by `Step` values and `MockError`. It lets a test script a sequence of provider replies, including failures.

Core test helpers in `Tests/AgentHarnessKitTests/Support` include `GatedCheckpointer` for controlling checkpoint saves, `ToolInvocationCounter` for counting tool runs, and fixtures for custom completion, token usage, approvals, and stream failure diagnostics.

## Tags

`TestTags.swift` files declare Swift Testing tags. The core and MCP support folders each define them. The tag names are `smoke`, `provider`, `wireFormat`, `streaming`, `checkpointing`, `slow`, and `requiresNetwork`. In practice, only a few suites apply them. For example, `MCPToolTests.swift` and `MCPClientTests.swift` apply `.tags(.wireFormat)` to their suites. Nothing in the Makefile or CI filters by tag, so these tags are informational for now.

## Self-test files

Some suites have files named by a prefix and number, such as `M1SelfTests.swift` through `M4SelfTests.swift` in the MCP target, and `H1SelfTests.swift` through `H6SelfTests.swift` plus `H8SelfTests.swift` in the context target. These files are ordinary Swift Testing suites. This page does not establish which requirements each file covers, so read the file before relying on its scope.

## Running the tests

Local commands are in the `Makefile`:

- `make test` runs `swift test`.
- `make test-ci` runs `swift test --parallel -Xswiftc -warnings-as-errors`, which matches the CI build.
- `make check` runs the format check, lint, and `test-ci`.

CI runs the macOS and Linux suites with `--parallel` and warnings as errors. The iOS Simulator job runs only `AgentHarnessKitTests` and `AgentHarnessKitALMTests`. The live job runs only `LiveEndpointTests` by name, and only when `AHK_LIVE_BASE_URL` is set. See [Build and CI](../operations/build-and-ci.md) for the full job matrix.

`LiveEndpointTests` (`Tests/AgentHarnessKitALMTests/HarnessModelClientTests.swift`) points `HarnessModelClient` at any OpenAI-compatible endpoint. `AHK_LIVE_BASE_URL` turns it on, and `AHK_LIVE_MODEL` and `AHK_LIVE_API_KEY` are optional. It covers a generate and a streamed tool loop at the client level, plus `agentStreamsTheFinalAnswer`, which runs a default `Agent.stream` turn and checks that the answer arrives as more than one `.delta` event, spread over at least 100 ms, matching the `.finished` content. Its offline counterpart is `plainTextFinalAnswerStreamsAsDeltas` in `AgentOverAdapterTests`, which checks the same ordering against the mock server.

To run one target or suite, use the standard Swift filter, for example `swift test --filter LiveEndpointTests`.

## What the offline suites do not cover

<!-- openwiki: broken internal link [gates-and-acceptance.md] file "gates-and-acceptance.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- Real provider behavior, including Anthropic and OpenAI. The live job covers this only when credentials exist, and the spike report records those providers as not run (see [Gates and acceptance](gates-and-acceptance.md)).
- The Foundation Models and MLX runtimes. Their suites are gated by availability or trait, so a default build may not compile them.
- Process-level behavior beyond the one child-process resume test.

## Related pages

- [Testing support](../integrations/testing-support.md) documents the `TestLLMClient` API.
- [Build and CI](../operations/build-and-ci.md) describes the commands and jobs that run these targets.
