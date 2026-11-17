# Changelog

All notable changes to AgentHarnessKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-17

First release. It covers the work in ROADMAP.md Phases 0 to 8, built on
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) (ALM) 1.3.0
as the provider and transport layer. The tag itself is pending maintainer approval.

### Added

- **Phase 0, architecture and skeleton.** Option A chosen: ALM is transport, and
  the agent loop stays in AgentHarnessKit (`docs/ARCHITECTURE.md`). Package skeleton
  with the core, ALM, Context, MCP, Testing, Foundation Models and MLX targets.
  MIT `LICENSE` and `NOTICE` with AgentRunKit attribution. Initial CI.
- **Phase 1, core types.** Provider-free Messages, Tools, `JSONSchema`, token usage,
  `AgentError`, tool approval types and `StreamEvent` definitions. GRDB gate package
  (`Gates/GRDBGate`).
- **Phase 2, model adapter.** `HarnessModelClient` implements the stateless `LLMClient`
  seam over ALM. Tool calls come back unexecuted. Anthropic thinking replay, usage
  mapping with nil kept as nil, and mock-server tests.
- **Phase 3, agent loop.** `Agent`, `Chat`, `AgentConfiguration`, `AgentResult`,
  terminal outcomes, finish and completion tools, middle-out tool-result truncation,
  tool timeouts and concurrency, and iteration and token limits. `TestLLMClient` in
  `AgentHarnessKitTesting`.
- **Phase 4, approval and checkpointing.** Tool approval policy and handler,
  `approveAlways` session allowlist, `InMemoryCheckpointer` and `FileCheckpointer`,
  resume that validates MCP tool bindings and completion tool identity, and
  buffered-event replay on resume.
- **Phase 4b, context management.** GRDB-backed `HierarchicalContextStore` with
  FTS5 search, the reserved `compress`, `decompress`, `search_context` and
  `context_status` tools, protected zones, nudge gating, emergency truncate, and
  `contextFolded`, `contextRestored` and `contextStatus` events. Checkpoints store the
  session ID and block-state version.
- **Phase 5, sub-agents and streaming.** `SubAgentTool` and `SubAgentExecutableTool`
  (max depth 3), child events wrapped as `subAgentEvent`, `StreamEvent` Codable
  round trip, `StreamProcessor`, `ToolCallAccumulator`, and `AgentStream`.
- **Phase 6, MCP.** `MCPClient`, `MCPTool`, `MCPSession.withTools`, MCP content and
  error types, a Streamable HTTP transport on all platforms, and a stdio transport on
  macOS and Linux (unavailable on iOS).
- **Phase 7, Apple adapters.** `AgentHarnessKitFoundationModels` (Apple platforms) and
  `AgentHarnessKitMLX` (Apple Silicon, behind the `MLX` trait). Both are opt-in, so
  core and Linux builds do not pull them in.
- **Phase 8, CI and docs.** GitHub Actions jobs for macOS, Linux (`swift:6.3`) and iOS
  Simulator (`xcodebuild` with `-skipMacroValidation`), plus a lint job (SwiftFormat and
  SwiftLint). `-warnings-as-errors` is set. `docs/README.md` index and this changelog.

### Known gaps

Copied from the NOT RUN rows of `docs/ARCHITECTURE.md` section 7 and its Phase 7 table.
Nothing in this list has been run.

- Real Anthropic S1 to S6 on iOS Simulator and Linux (macOS only).
- Option A one-request adapter proof on iOS Simulator.
- Phase 2 adapter mock tests on iOS Simulator and Linux. Core tests on iOS Simulator are also NOT RUN.
- Phase 2 live tool loop on iOS Simulator and Linux (macOS only).
- Phase 2 live Anthropic signed-thinking replay through the adapter, on all platforms.
- OpenAI proper and Responses opaque-item replay, on all platforms.
- App sandbox and App Transport Security on iOS.
- Foundation Models on-device smoke test on an iOS device or simulator. Its tests on iOS are NOT RUN; only the build passed.
- MLX construction and smoke tests on macOS. They need an `xcodebuild` host because `swift build` does not compile MLX's metallib.
- MLX tool call, on any platform.
- Redacted thinking, streaming replay, and adaptive thinking for models other than the tested ones (spike S6 gaps).
