# Changelog

All notable changes to AgentHarnessKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `PartialTurnRecorder` is public, and `Agent.stream` and `Agent.resume` take an optional `partialTurnRecorder:`. Code that consumes the event stream directly, without `AgentStream` or Observation, can call `snapshot()` when it stops a turn and resend the result as `history:` (0.2.1 known gap 6.5). `Chat.stream` still does not record.

### Changed

- **Breaking:** `Agent` no longer offers the built-in `finish` tool by default. It ends when the model replies with plain text and no tool calls, so the final answer streams as `.delta` events instead of arriving all at once in `.finished`. Pass `AgentConfiguration(offersFinishTool: true)` to restore the old behavior. A `finish` call is still honored when the tool isn't offered, so existing histories and checkpoints keep working.
- Documented that cancelling a turn while a sub-agent runs keeps only the synthetic cancelled result for the sub-agent call, not the sub-agent's own messages (0.2.1 known gap 6.6).
- Doc comments for `AgentStream.init`, both `AgentStream.send` overloads and `PartialTurnRecorder`.

## [0.2.1] - 2026-11-18

### Fixed

- `MCPClient` reports version 0.2.1 to MCP servers. The 0.2.0 tag still reported 0.1.0, and the README install snippet still said `from: "0.1.0"`.
- `partialHistory` after a cancel between the `finish` commit and `.finished` restores the answer as plain assistant text, the same as a finished turn, instead of a `finish` call with a synthetic cancelled result (0.2.0 known gap 6.1).
- `ToolApprovalQueue.denyAll(reason:)` no longer publishes an unchanged empty snapshot when nothing is parked.

### Changed

- The recommended Stop flow is now `stream.cancel()` first, then `denyAll(reason:)`, so `partialHistory` is captured before any parked approval resumes (0.2.0 known gap 6.2). README, spec and `ToolApprovalQueue` docs are updated.
- Documented that request ids must be unique across runs sharing a `ToolApprovalQueue`; `resolve(id:decision:)` takes the oldest match (6.4).
- `partialHistory` after an error is kept and documented, and pinned by a test (6.3).
- The 0.2.0 changelog entry now includes its Changed, Notes and Known gaps sections.
- New `make check-local` target runs SwiftFormat, SwiftLint and the tests without `mint`.

### Known gaps

- Partial history is only available through `AgentStream`. `Chat.stream` and `Agent.stream` do not expose it (6.5).
- Sub-agent work in progress is lost on cancel (6.6).

## [0.2.0] - 2026-11-18

### Added

- `AgentStream.partialHistory`, the interrupted turn as valid history after `cancel()`. Pass it as `history:` to the next `send`. A parked approval cancelled this way gets the synthetic result `"Cancelled by user before this tool returned."`.
- `ToolApprovalQueue`, a `ToolApprovalHandler` provider that parks approval
  requests in FIFO order for a UI to resolve. Requests resolve by id in any
  order (`resolve(id:decision:)`), `denyAll(reason:)` clears every waiting
  request on stop or cancel, and a request whose task is cancelled resolves as
  deny with reason `"Cancelled"`. `pending()` and `updates` expose the queue
  without `Observation`, so it builds on Linux. `.approveAlways` resolves only
  the request it is given; the allowlist then skips later calls to that tool.
  Within one run the loop asks approvals one at a time, so several requests
  wait together only when runs or sub-agents share a queue.

### Changed

- Terminal `finish` answers are kept in history as an assistant message. The merge of assistant text and finish content follows the "Terminal answer in history" rule in `AGENTHARNESSKIT_PARITY_SPEC.md`.
- **Consumers that re-add the finish answer themselves (for example, a `TerminalAnswer.restore` step) will now see it twice. Delete that step.**
- The restored terminal answer message drops its provider continuity, so adapters that replay continuity verbatim (for example `HarnessModelClient` with `replaySubstrate`) rebuild that turn from its fields instead of resending a dangling `finish` call. That one turn is no longer replayed verbatim.

### Notes

- The v0.2 history summarizer (roadmap item 3) is closed as won't-do in favor of `HierarchicalContextStore` and `compress`.

### Known gaps

- Cancel between the `finish` commit and `.finished` (6.1): `partialHistory` can hold the `finish` call with the synthetic `"Cancelled by user before this tool returned."` result, although the answer was already given. A resend still completes.
- `denyAll(reason:)` followed by `cancel()` is racy (6.2): the loop can record the deny text or the synthetic cancelled text. Call `stream.cancel()` first, then `denyAll(reason:)`.
- Duplicate `toolCallId` across runs that share a `ToolApprovalQueue` (6.4): `resolve(id:)` takes the oldest request. Use ids that are unique across runs sharing a queue.
- Partial history is only available through `AgentStream` (6.5). `Chat.stream` and `Agent.stream` do not expose it.

## [0.1.0] - 2026-11-17

First release. It covers the work in ROADMAP.md Phases 0 to 8, built on
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) (ALM) 1.3.0
as the provider and transport layer.

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
  SwiftLint). `-warnings-as-errors` is set. A `live` job runs `LiveEndpointTests` on
  macOS, Linux and iOS Simulator when the `AHK_LIVE_*` repository secrets are set, and
  skips otherwise. README, `docs/README.md` index and this changelog.

### Known gaps

Copied from the NOT RUN rows of `docs/ARCHITECTURE.md` section 7 and its Phase 7 table.
Nothing in this list has been run.

- Real Anthropic S1 to S6 on iOS Simulator and Linux (macOS only).
- Option A one-request adapter proof on iOS Simulator.
- Core and adapter mock tests on Linux: NOT RUN locally; the Linux CI job runs them. (iOS Simulator passed 715 core + 45 ALM tests locally.)
- Phase 2 live tool loop on iOS Simulator and Linux (macOS only).
- Phase 2 live Anthropic signed-thinking replay through the adapter, on all platforms.
- OpenAI proper and Responses opaque-item replay, on all platforms.
- App sandbox and App Transport Security on iOS.
- Foundation Models on-device smoke test on an iOS device or simulator. Its tests on iOS are NOT RUN; only the build passed.
- MLX construction and smoke tests on macOS. They need an `xcodebuild` host because `swift build` does not compile MLX's metallib.
- MLX tool call, on any platform.
- Redacted thinking, streaming replay, and adaptive thinking for models other than the tested ones (spike S6 gaps).
