# AgentHarnessKit Roadmap

Expands the phases in [AGENTHARNESSKIT_PARITY_SPEC.md](AGENTHARNESSKIT_PARITY_SPEC.md). The spec is the source of truth for behavior; this file is the work plan. Platforms: iOS, macOS, Linux. Swift 6.3+.

## Starting point

- Spike done, decision: **build on AnyLanguageModel (ALM)**. Evidence: `docs/spike/SPIKE_REPORT.md` (S1-S6 pass on Anthropic; S1-S5 on mock + local endpoint across platforms).
- Spike code is not in the tree. It is tagged `spike-final` (`git show spike-final:Sources/SpikeCore/MockServer.swift`). Reuse from it: `MockServer` (Phase 2 tests), `RecordingTransport` (request-body inspection), and the resume/stop/deny helpers in `Scenarios.swift` as reference for the adapter.
- Spike quirks to design around: `.stop` leaves an empty trailing `.response`; `respond(to:)` always appends a user prompt; swift-syntax macros prompt for trust in `xcodebuild`.
- Option A proven on mock (macOS, Linux); see `docs/ARCHITECTURE.md`. Still unverified: the iOS `xcodebuild` macro prompt with code that expands ALM macros, GRDB on Linux/iOS.

## Dependency graph

```
P0 ──► P1 ──► P2 ──► P3 ──► P4 ──► P5
 │             │      │      └──► P4b (also needs GRDB gate)
 │             │      └──► P6 (MCP protocol can start after P1)
 │             └──► P7
 ├──► GRDB gate (parallel with P1-P3)
 └──► CI skeleton (P8 starts here, not at the end)
```

Parallel lanes once P0 is done: (a) P1 types, (b) GRDB gate, (c) CI skeleton. After P1: P2 and the MCP protocol layer (P6) are independent. P7 needs only P2.

## Phase 0: Architecture decision and skeleton

**Goal:** record the Option A/B/C decision and get an empty package building on all three platforms.

- Prove Option A with a throwaway test: one ALM request with tools declared, delegate returns `.stop`, tool calls come back unexecuted, and a full message history can be sent in. Decide A (expected), B or C.
- Write `docs/ARCHITECTURE.md`: option chosen with spike evidence; `ChatMessage` stays our own Codable type, converted to/from ALM `Transcript`; adapter workarounds for the two quirks; GRDB layout (one DB per session or shared); thread of `sessionID` through the loop.
- Package skeleton: targets `AgentHarnessKit`, `AgentHarnessKitALM`, `AgentHarnessKitContext`, `AgentHarnessKitMCP`, `AgentHarnessKitTesting`; `swift-tools-version: 6.3`; ALM `.upToNextMinor(from: "1.3.0")`; strict concurrency on; ALM traits opt-in.
- `LICENSE` + `NOTICE` (MIT, AgentRunKit attribution).
- Minimal CI (macOS, `swift:6.3` Linux container) building the empty package.
- Resolve the iOS Simulator build: `xcodebuild` with `-skipMacroValidation` (human decision) or documented Xcode trust step.

**Exit:** `ARCHITECTURE.md` merged; skeleton builds on macOS and Linux; iOS Simulator build result recorded (pass or documented blocker).

## Phase 1: Core data types

**Goal:** the provider-free core compiles and its ported tests pass.

- Port (Foundation-only): Messages/*, Tools/* (incl. `SchemaProviding`, `JSONSchema`, `SchemaDecoder*`), `TokenUsage*`, `AgentError` (add `missingContextWindowSize`), `ToolApproval` types, `StreamEvent` type definitions (new context event kinds instead of `compacted`).
- Decide `SchemaProviding`/`ResponseFormat` vs ALM `@Generable` (spec section 4). Default: keep ours, bridge schemas into ALM tool declarations.
- Port tests with each file (swift-testing). Add the `FoundationNetworking` guard wherever `URLRequest` appears (should be none in core).

**Exit:** core tests green on macOS and Linux; no provider or Apple-only imports in the core target.

## Phase 2: Model adapter (`HarnessModelClient`)

**Goal:** the stateless `LLMClient` seam over ALM.

- `LLMClient` protocol per spec; `HarnessModelClient.generate` and `.stream` mapping `ChatMessage` history to a `Transcript`, tool definitions to ALM tools that never auto-execute, results back to `AssistantMessage`/`StreamDelta`.
- Map ALM errors to `AgentError.llmError`; port `RetryPolicy` semantics only if ALM lacks them.
- Provider options ALM does not expose: Anthropic/OpenAI `toolChoice`, `parallelToolCalls`, Gemini function-calling mode, Responses hosted tools, `extraFields`.
- Continuity replay: Anthropic thinking blocks (spike S6 passed for `respond`), plus the gaps S6 left: **redacted thinking, streaming, other models/adaptive thinking, OpenAI Responses opaque items**. OpenRouter reasoning replay.
- Mock-server tests (restore `MockServer` from `spike-final`) covering text, tool calls, parallel calls, streaming, cancel.
- Usage mapping into `TokenUsage` with coverage (nil stays nil, not zero).

**Exit:** adapter tests pass against the mock on macOS and Linux; continuity replay tests pass on Anthropic (needs a key, gated by env var, skipped in CI without it).

## Phase 3: Agent loop

**Goal:** `Agent`, `Chat`, finish/completion tools.

- Port `Agent`, `Agent+Run`, `Agent+StreamingLoop`, `Agent+ToolExecution`, `AgentConfiguration` (drop compaction fields, add `contextStore`), `AgentResult`, `Chat`, terminal outcomes.
- Behaviors from the spec's "easy to get wrong" list: reserved names (`finish` + four context tools), single-finish rule, content-only termination, malformed-history checks, middle-out tool-result truncation, tool timeouts and concurrency, iteration and token limits.
- Port `TestLLMClient` as `AgentHarnessKitTesting` first, so every loop test can be scripted.
- `ContextStore` protocol and in-memory implementation land here as a no-op pass-through so P4b only swaps the implementation.

**Exit:** ported loop tests green on macOS and Linux; one streaming tool-call run against a real provider on macOS.

## Phase 4: Approval and checkpointing

- Port `ToolApprovalPolicy`/`Handler`/decisions; loop suspends in place without closing the stream; `approveAlways` persisted in the session allowlist and checkpoints.
- Port `Core/Checkpointing/*`: `InMemoryCheckpointer`, `FileCheckpointer` (explicit directory, no `TMPDIR` assumption), snapshot at end of each iteration (streaming only), resume validates MCP tool bindings and completion tool identity.
- Buffered-event replay on resume (replayed events do not fire live callbacks).
- Cross-process resume test (spike S3 pattern) on macOS and Linux.

**Exit:** ported approval/checkpoint tests green; resume works across processes.

## Phase 4b: Context management (billion-context design on GRDB)

Starts after P3 and the GRDB gate. Needs P4 only for the checkpoint integration step.

1. **GRDB gate** (can run any time after P0): build, `DatabasePool` in an explicit directory + migration, FTS5, second-process open. Run on macOS, Linux, iOS Simulator; record SQLite version/FTS5 flags in `docs/ARCHITECTURE.md`. If Linux fails: custom SQLite, in-memory fallback on Linux, or another SQLite wrapper behind `ContextStore`.
2. Schema + migrations: `message`, `block`, `block_source`, FTS5 index; transitive `effectiveMessageIds`.
3. Pure-function pipeline (each unit-tested alone): assign refs, sync blocks, merge adjacent, prune to budget, filter visibility, hide compression calls, inject nudge, emergency truncate, render with ref tags.
4. The four reserved tools (`compress`, `decompress`, `search_context`, `context_status`) with range validation and model-readable errors.
5. Enforced rules: protected zones, nudge gating (floor ~0.45 + growth gate), doctrine in system prompt, tool-pair-safe emergency truncate. Thresholds and prompt text are configuration.
6. Integration: `render` before each request, record messages + usage after; checkpoint stores `sessionID` + block-state version and fails clearly on mismatch; sub-agents get their own session id (finished in P5); `contextFolded`/`contextRestored`/`contextStatus` events.
7. Verify the paper-derived numbers (0.45 floor, 5-message/5K-token protected zone) against `acp-kernel` source; update config defaults.
8. Long-session test: thousands of synthetic messages stay under the window; append-only render (prefix bytes identical before/after a fold).

**Exit:** tests pass on macOS and Linux with GRDB; iOS reported honestly from the gate.

## Phase 5: Sub-agents and event streaming

- Port `SubAgentTool`, `SubAgentExecutableTool`, `SubAgentContext` (max depth 3); child events wrapped as `subAgentEvent`; child token use reported separately; child gets its own context session.
- Port the streaming pieces: `StreamEventBuffer`, `StreamEventFactory`, `StreamEventJSONCodec`, `StreamProcessor`, `ToolCallAccumulator`, `HistoryEmissionLimit`, `StreamCompletion`.
- `AgentStream` (`@Observable`): test Observation on Linux; gate with `#if canImport(Observation)` if unavailable.
- `StreamEvent` Codable round trip for every kind.

**Exit:** sub-agent and streaming tests green on macOS and Linux; `AgentStream` verified or gated per platform.

## Phase 6: MCP

- Protocol layer (independent of the loop; can start after P1): `JSONRPCMessage`, `MCPClient`, `MCPTool*`, `MCPContent`, `MCPError`, `MCPServerConfiguration`, `MCPSession.withTools`.
- New HTTP transport (Streamable HTTP/SSE) on all platforms, using ALM's transport or AsyncHTTPClient, not `URLSession.bytes`.
- Stdio transport: widen guard to `os(macOS) || os(Linux)`; unavailable on iOS.
- Tool-binding validation hooks used by checkpoint resume.

**Exit:** protocol + HTTP tests on all three platforms; stdio tests on macOS and Linux.

## Phase 7: Apple Foundation Models and MLX adapters

- `AgentHarnessKitFoundationModels` (Apple platforms only) and MLX (trait or separate target, Apple Silicon only) behind `HarnessModelClient`.
- Both stay opt-in so the core and Linux builds never pull them.
- Verify tool calling and streaming on-device where possible; mark anything not run as NOT RUN.

**Exit:** both build under their guards; smoke test per adapter on a real device/simulator, recorded honestly.

Status: in progress; results in docs/ARCHITECTURE.md section 7.

## Phase 8: CI and release

Skeleton starts in P0; this phase completes it.

- GitHub Actions: macOS, Linux (`swift:6.3` container), iOS Simulator (`xcodebuild`, macro trust flag decided in P0).
- `-warnings-as-errors`; SwiftFormat + SwiftLint with the reference's `Mintfile` and `Makefile` settings.
- Real-provider tests gated behind secrets (never committed keys).
- README, `docs/` index, tagged release.

**Definition of done for parity:** ported suite passes on macOS and Linux; core + ALM targets build and pass the mock-server tests on the iOS Simulator; a streaming tool-call run works against at least one real provider on each platform.

## Deferred

`Examples/AgentCode`, DocC articles, Wasm, Android (spike showed ALM works on an emulator; GRDB, MCP and CI untested there).
