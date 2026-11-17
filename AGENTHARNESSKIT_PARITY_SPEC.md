# AgentHarnessKit: Feature Parity Spec with AgentRunKit

You are an implementation agent starting in a fresh repo. This document is your brief. Read it fully before writing code.

## Goal

Build **AgentHarnessKit**, a Swift package that matches the features of AgentRunKit v6.1.0 and **builds and runs on iOS, macOS and Linux**. It layers agent features on top of [huggingface/AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) (AnyLanguageModel, or "ALM"), which supplies the cross-platform provider and transport layer.

AgentRunKit does not build on Linux (its Swift Package Index grid shows Linux failing on every Swift version). Most of its agent logic is plain Swift and should port. The problems were in the provider and HTTP layer plus a few Apple-only files, all listed below.

## Reference material

- Reference source (read-only): the AgentRunKit repo, tag `6.1.0`, at `https://github.com/Tom-Ryder/AgentRunKit`. A local checkout is at `/Users/zacharyreyes/Projects/AgentRunKit` (HEAD `a7ac823`). Paths below are relative to its `Sources/AgentRunKit/`.
- It is MIT licensed. If you copy or adapt code, keep the copyright and license notice in the new repo's `LICENSE` or `NOTICE`.
- The reference has about 20,000 lines of source and 185 test files (swift-testing). Port tests together with each feature.
- Per-feature guides live in `Documentation.docc/Articles/` (AgentAndChat, ToolApproval, CheckpointAndResume, SubAgents, TokenAccounting, StructuredOutput, MultimodalAndAudio, MCPIntegration, StreamingAndSwiftUI, LLMProviders, DefiningTools). Read the guide before porting each feature.

## Prerequisite: the spike

A separate spike (see `SPIKE_HANDOFF.md`, if present) must answer whether ALM's session API gives us enough loop control. **Phase 0 below depends on its result. Do not start Phase 2 until the architecture decision in Phase 0 is made and written down.**

Known about ALM (from its README and Swift Package Index, not verified by running code):
- Builds on iOS, macOS and Linux only on **Swift 6.3 and 6.4**. Swift 6.1 and 6.2 fail. Set `swift-tools-version: 6.3`.
- Providers: Anthropic, Gemini, OpenAI (Chat Completions and Responses), Ollama, Apple Foundation Models, MLX, llama.cpp, Core ML.
- It runs the tool loop inside its session. It has `ToolExecutionDelegate` (observe, approve, stop, replace tool calls, inject steering messages), `maximumToolRounds`, streaming snapshots, and `@Generable` structured output.
- It does not mention MCP, checkpointing, sub-agents, or context management in its README.
- Traits (CoreML, MLX, Llama, AsyncHTTPClient) are off by default. A SwiftPM bug can break resolution when traits are used.

## Phase 0: architecture decision (blocking)

AgentRunKit's loop owns the iteration. Its provider seam is the stateless `LLMClient` protocol (`LLM/Core/LLMClient.swift`):

```swift
func generate(messages:[ChatMessage], tools:[ToolDefinition], responseFormat:ResponseFormat?, requestContext:RequestContext?) async throws -> AssistantMessage
func stream(messages:[ChatMessage], tools:[ToolDefinition], requestContext:RequestContext?) -> AsyncThrowingStream<StreamDelta, Error>
```

The harness owns the message history, executes tools itself, and calls the client once per iteration. That is what makes approvals, checkpointing, compaction and sub-agents possible.

Choose one approach and record it in `docs/ARCHITECTURE.md` with evidence from the spike:

- **Option A (recommended default): ALM as a transport only.** Write `HarnessModelClient`, an adapter that sends one request through ALM with tools declared but **never auto-executed**, and returns the assistant message and tool calls to the harness. Port AgentRunKit's `Agent` loop nearly unchanged on top of it. This needs ALM to expose unexecuted tool calls and accept a full message history. If it cannot, see Option C.
- **Option B: use ALM's session loop** with `ToolExecutionDelegate` for approvals and stop conditions. Only viable if the spike proves transcript read-out, serialization and cross-process resume work (spike question 3).
- **Option C: contribute or fork the missing seam** in ALM (for example, a way to get tool calls back without executing them). Only if A and B both fail. Note the maintenance cost.

Also decide: how to represent `ChatMessage` (keep AgentRunKit's own Codable type and convert to and from ALM's transcript, which is what Option A implies).

## Gap analysis: what ALM covers and what we must build

| Capability in AgentRunKit | ALM status | Work |
|---|---|---|
| OpenAI Chat provider (`OpenAIClient`, incl. OpenRouter, Groq, Together, Ollama via compatible endpoints) | Covered (OpenAI, Ollama) | Adapter only. Verify OpenRouter reasoning replay and `extraFields` passthrough. |
| Anthropic Messages (`AnthropicClient`) with same-substrate continuity replay | Covered (Anthropic) | Adapter. **Verify** thinking blocks and their signatures survive a round trip (see "Continuity replay"). |
| Gemini (`GeminiClient`) | Covered | Adapter. |
| OpenAI Responses (`ResponsesAPIClient`) with continuity replay and OpenRouter factory | Covered (Responses) | Adapter. Verify opaque item replay. |
| Apple Foundation Models (`AgentRunKitFoundationModels`) | Covered | Adapter. Apple platforms only. |
| MLX (`AgentRunKitMLX`) | Covered (trait) | Adapter, behind a trait or separate target. Apple Silicon only. |
| SSE streaming, retry, transport errors (`LLM/Transport/*`) | Covered by ALM transport | Map ALM errors to our `AgentError.llmError` or equivalent. Port `RetryPolicy` semantics if ALM lacks them. |
| Agent loop, iteration limit, token budget, finish tool, completion tool | Not covered | Port. |
| Tool approval (policy, handler, allowlist) | Partly (delegate) | Port on top of our loop. |
| Checkpoint and resume | Not covered | Port. |
| Context management (compaction, pruning, budget, prune tool) | Not covered | **Do not port.** Build new from the billion-context design on GRDB.swift. See "Context management" below. |
| Sub-agents with depth control and streaming propagation | Not covered | Port. |
| Streaming events (`StreamEvent`) and `@Observable` `AgentStream` | Not covered | Port. Test Observation on Linux. |
| Structured output | Covered (`@Generable`) | Decide: keep our `SchemaProviding`/`ResponseFormat` or bridge to ALM. |
| Multimodal input (images, audio, video, PDF) | Partly | Verify per provider. |
| Audio output streaming from chat models | Not covered | Port or defer. |
| MCP client | Not covered | Port. Stdio is not available on iOS. |
| Token accounting with coverage | Not covered | Port. |
| Testing client (`AgentRunKitTesting/TestLLMClient.swift`) | n/a | Port as `AgentHarnessKitTesting`. |

## What ports as is (pure Swift, no platform dependencies)

Copy these, adapt names, and port their tests. Imports are `Foundation` only. Where a file uses `URLRequest`, `URLSession` or `HTTPURLResponse`, it needs the `FoundationNetworking` import shown below.

- **Messages/**: `ChatMessage`, `ChatMessageHistory`, `ContentPart`, `AssistantMessage`, `AssistantContinuity`, `ReasoningConfig`, `ReasoningContent`, `TokenUsage`, `TokenUsageTotals`, `TokenUsageCoverage`, `ToolCall`, `JSONValue`, `JSONEncoding`.
- **Tools/**: `Tool`, `AnyTool`, `ToolResult`, `ToolContext`, `SchemaProviding`, `JSONSchema`, `SchemaDecoder` (with `SchemaDecoderContainers`, `SchemaKeyedContainer`), `SubAgentTool`, `SubAgentExecutableTool`.
- **Core/AgentLoop/**: `Agent`, `Agent+Run`, `Agent+StreamingLoop`, `Agent+ToolExecution`, `AgentConfiguration`, `AgentResult`, `AgentError`, `AgentCompletionPolicy`, `AgentTerminalOutcome`, `FinishArguments`, `InvocationOptions`, `ToolApproval`, `ToolExecutionHelpers`, `Chat`.
- **Core/Checkpointing/**: all of it, including `FileCheckpointer`, which uses `FileManager` and `Data.write(.atomic)`.
- **Core/Context/**: `SubAgentContext` only. The rest of the reference's context code is replaced (see "Context management").
- **Core/Streaming/**: `StreamEvent`, `StreamEventBuffer`, `StreamEventFactory`, `StreamEventJSONCodec`, `StreamProcessor`, `ToolCallAccumulator`, `EventOrigin`, `HistoryEmissionLimit`, `StreamCompletion`, `Agent+StreamEvents`.
- **LLM/Parsing/ThinkTagParser** and `LLM/Transport/SSEParser` (only if ALM's streaming does not make it unnecessary).
- **MCP/** protocol layer: `JSONRPCMessage`, `MCPClient`, `MCPContent`, `MCPTool`, `MCPToolInfo`, `MCPError`, `MCPServerConfiguration`, `MCPTransport`, `MCPSession`.

Three known rough edges in those files:
- `Core/Streaming/AgentStream.swift` uses `import Observation` and `@Observable`. Test on macOS, Linux and iOS. If Observation is unavailable on Linux, gate the file behind `#if canImport(Observation)`.
- `Core/Checkpointing/FileCheckpointer.swift` and anything using `FileManager.default.temporaryDirectory` depend on `TMPDIR`, which is not reliable on every platform (iOS is sandboxed). Accept an explicit directory instead of assuming one.

## What must be rewritten or replaced

1. **Provider clients** (`LLM/Providers/*`, about 7,000 lines). Do not port. Replace with `HarnessModelClient` over ALM (Option A). Port only the provider-specific request options that ALM does not expose (see `LLM/Core/RequestContext.swift`): OpenAI Chat `toolChoice`, `parallelToolCalls` and custom tools; Anthropic `toolChoice`; Gemini function calling mode; Responses hosted tools; free-form `extraFields`.
2. **HTTP transport**. The reference uses `URLSession.bytes(for:)`, `URLSession.AsyncBytes` and `bytes.lines` (`LLM/Transport/HTTPRetry.swift`) and `session.upload(for:fromFile:)` (`OpenAIClientStreaming.swift`). These are the main reason it fails on Linux. If you need any HTTP outside ALM, do not reuse them. Use ALM's transport or AsyncHTTPClient.
3. **Stdio MCP transport** (`MCP/StdioMCPTransport.swift`). It is wrapped in `#if os(macOS)` and uses `Process` and `Pipe`. Widen the guard to `os(macOS) || os(Linux)`. On iOS, stdio is not available, so add an HTTP transport (Streamable HTTP or SSE) that works everywhere. This is new code.
4. **Structured output and schema**. Decide whether to keep `SchemaProviding`, `JSONSchema` and `ResponseFormat` (needed so tools keep compile-time schema validation) or bridge to ALM's `@Generable`. Either way, tool parameter schemas must reach ALM's tool declarations correctly.

Add this at the top of every file that uses `URLRequest`, `URLSession` or `HTTPURLResponse`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

## Continuity replay (highest-risk parity item)

AgentRunKit preserves provider-specific state across turns so that reasoning models keep working: `Messages/AssistantContinuity`, `LLM/Core/OpaqueResponseItem`, `OpenAIChatReasoningDetails`, `ResponsesContinuity`, and `AnthropicTurnProjection` ("same-substrate continuity replay"). Examples are Anthropic thinking blocks with signatures and Responses API opaque reasoning items.

If ALM discards these when converting a response to a transcript, multi-turn runs with extended thinking and tool use will fail or degrade silently. In Phase 0, write a test that runs a two-iteration tool loop with thinking enabled on Anthropic, and confirm the second request carries the signed thinking block back. If it does not, either extend through ALM's provider-specific hooks or call the provider directly for that path.

**Spike result (S6, SPIKE_REPORT.md section 7):** passes on Anthropic (claude-haiku-4-5, `respond`, extended thinking, two parallel tool calls): the signed thinking block survives a JSON round trip and is replayed before the `tool_use` blocks. The Phase 0/2 test suite must still cover: (1) redacted thinking blocks (`metadata["isRedacted"]` path), (2) thinking with streaming (`streamResponse`), (3) other models/modes (Sonnet/Opus, adaptive thinking), and (4) OpenAI Responses opaque-item replay.

## Context management (replaces the reference's compaction)

Do **not** port the reference's `ContextBudget`, `ContextCompactor`, compaction cascade, `prune_context` or prompt-too-long recovery. Implement the design from [billion-context](https://github.com/ranxianglei/billion-context) instead, as a new target `AgentHarnessKitContext` backed by [GRDB.swift](https://github.com/groue/grdb.swift). Read the paper first: [Model-Driven Incremental Hierarchical Compression](https://github.com/ranxianglei/billion-context/blob/master/paper/model-driven-incremental-hierarchical-compression-training-free-multi-generational-context-management-for-long-lived-coding-agents.md) (sections 3 and 4 are the design; 3.1 to 3.4 matter most). billion-context is a TypeScript kernel (`acp-kernel`) used through a proxy. We are re-implementing its design in Swift, not calling it.

### Principles to keep

- **The model decides when and what to compress.** The harness only enforces floors and renders. It does not summarize on a fixed threshold.
- **Incremental and append-only.** Compress only the increment the task has already consumed; never rewrite the whole history. The rendered window stays append-only at the tail so the provider's prompt cache prefix is not invalidated.
- **Reversible.** Folded ranges can be restored. Originals are never deleted.
- **Tiered blocks.** Tier-1 blocks summarize message ranges. Tier-2 folds tier-1 blocks, tier-3 folds tier-2 (an "LSM tree over prose"). Lineage must survive re-compression.
- **Per-turn pipeline of pure functions**, each tested alone: assign refs, sync blocks, merge adjacent blocks, prune to budget, filter visibility, hide compression-tool calls, inject nudge, emergency truncate, render with ref tags. The loop never mutates history directly.

### Tools exposed to the model

The harness injects four tools. They are reserved names (see "Behavioral details"). The harness executes them itself, not through the user's tool list:

- `compress`: fold a message range (by ref) into a summary the model writes. One call may carry several ranges.
- `decompress`: restore a folded block into context, or write its original text to a file so the cache prefix is not disturbed.
- `search_context`: keyword search over block summaries and visible messages.
- `context_status`: usage breakdown (system, tools, summaries, text) and which ranges are still compressible.

### Data model (persisted in GRDB)

- `message(ref, sessionID, role, content, tokens, createdAt)`: stable ids such as `m00042`, minted once, never reused. The model sees them as tags on user and tool messages. Do not tag assistant messages (the reference design avoids the model echoing them).
- `block(blockID, sessionID, tier, topic, summary, active, generation, createdAt, survivedCount)`.
- `block_source(blockID, sourceMessageRef | sourceBlockID)` for direct sources, plus a way to resolve every original message a block covers transitively (the paper's `effectiveMessageIds`).
- FTS5 index over summaries and messages for `search_context`.
- Raw message text is kept so `decompress` always works. Archive instead of delete.

Use GRDB migrations for schema changes. Use a `DatabasePool` (WAL) for file databases and a `DatabaseQueue` for tests. One database file per session or one shared file keyed by `sessionID`; decide in `docs/ARCHITECTURE.md`.

### Rules enforced by code, not prompts

- Protected zones: the compression tool calls themselves, the recent zone (at least the last 5 messages or about 5K tokens), the last user message, and the first user message.
- Reject ranges that are protected, already folded, or not contiguous. Return an error the model can read and retry from.
- Trigger a nudge only when context exceeds a floor fraction of the window (reference default about 0.45) **and** has grown past a gate since the last compression. The window size comes from the model, and a missing size is an error (keep `missingContextWindowSize`).
- Keep the doctrine ("compress between task steps, not mid-step; you may refuse") in the system prompt so the model manages context even with no nudge. Prompt text and thresholds are configuration, not constants.
- Emergency truncate is the last resort and must keep tool-call/result pairs intact. Preserve the "malformed history" checks.
- Tool-result truncation (middle-out) stays as in the reference and is separate from this design.

### Integration with the rest of the harness

- The loop calls `ContextStore.render(sessionID:)` before each model request and records every new message and token usage after it. Token usage from `TokenUsageTotals` feeds the nudge.
- Checkpoints store the `sessionID` and block state version, not copies of the folded text. Resume must check that the database still matches the checkpoint and fail clearly if not.
- Sub-agents get their own session id, so their blocks do not mix with the parent's. Child token use stays reported separately.
- Events: `contextFolded`, `contextRestored`, `contextStatus` replace `compacted` and the budget events.
- `ContextStore` is a protocol in the core target. `AgentHarnessKitContext` provides the GRDB implementation, so the core stays database free. An in-memory implementation is needed for tests and for platforms where the GRDB gate fails.

### GRDB gate (blocking for Phase 4b)

GRDB's README lists iOS, macOS, tvOS and watchOS (Swift 6.1+) and says Linux support is contributor-maintained and not automatically tested. So GRDB on Linux is **unverified**, and Linux is a required platform. Before building on it, write a small spike (same rules as `SPIKE_HANDOFF.md`) that, on macOS, iOS and Linux, does the following. Mark anything not run as NOT RUN.

1. Builds with `swift-tools-version: 6.3` and resolves alongside AnyLanguageModel (check for dependency conflicts).
2. Opens a `DatabasePool` in an explicit directory (do not assume `TMPDIR` or a home directory), runs a migration, writes and reads a row.
3. Creates and queries an FTS5 table. Report which SQLite the platform uses and whether FTS5 and the features you need are compiled in.
4. Survives a second process opening the same file (needed for resume).

If Linux fails, choose and record in `docs/ARCHITECTURE.md`: use a custom SQLite build, fall back to the in-memory store on Linux, or switch the store to another SQLite wrapper behind the same `ContextStore` protocol. Do not fork GRDB without a recorded decision.

### Tests and acceptance

- Port the billion-context behaviors, not the reference's compaction tests. Cover: ref minting is stable, protected zones, range validation, tier-2 and tier-3 folding with lineage, decompress restores sources and decompress-to-file leaves the render unchanged, append-only render (the prefix bytes are identical before and after a fold), nudge gating, and emergency truncate keeping tool pairs.
- A long-session test (thousands of synthetic messages) must keep the rendered size under the window.
- Acceptance: tests pass on macOS and Linux with GRDB, and the iOS result is reported honestly from the gate above.

## Public API to preserve

Keep names and shapes where practical so existing AgentRunKit code ports mechanically. The central types:

- `Agent<C: ToolContext>`: `init(client:tools:configuration:)`, `init(client:tools:completionTool:configuration:)`, `run(userMessage:history:context:tokenBudget:requestContext:approvalHandler:)`, `stream(...)` (adds `sessionID:` and `checkpointer:`), and `resume(...)`.
- `Chat<C>`: multi-turn `send(...)` and `stream(...)`, with typed `send<T: Decodable & SchemaProviding>` for structured output.
- `AgentConfiguration`: `maxIterations` (default 10), `toolTimeout` (default 30s), `systemPrompt`, `maxToolResultCharacters`, `contextStore` (see "Context management"), `approvalPolicy`, `historyEmissionDepthLimit`.
- `AgentResult` (`finishReason`, `content`, `totalTokenUsage`, `iterations`, `history`) and `FinishReason` (`completed`, `error`, `maxIterationsReached`, `tokenBudgetExceeded`, `custom`).
- `AgentError` (tool not found, decoding and encoding failures, timeout, execution failure, LLM error, malformed history, schema inference failure, max depth, missing context window size), with `feedbackMessage` text sent back to the model.
- `AnyTool` (concurrency safe, read only, per-tool result limit and timeout, strict schema flag) and typed `Tool<P, O, C>`.
- `StreamEvent` with `Kind`: `delta`, `reasoningDelta`, `toolCallStarted`, `toolCallCompleted`, `audioData`, `audioTranscript`, `audioFinished`, `finished`, `subAgentStarted`, `subAgentEvent`, `subAgentCompleted`, `iterationCompleted`, `contextFolded`, `contextRestored`, `contextStatus`, `toolApprovalRequested`, `toolApprovalResolved`. All `Codable`, with `EventID`, `SessionID`, `RunID` and `EventOrigin`.
- `AgentCheckpointer` (`save`, `load`, `list(session:)`), `InMemoryCheckpointer`, `FileCheckpointer`, `AgentCheckpoint`.
- `ToolApprovalPolicy` (`none`, `allTools`, `tools(Set)`), `ToolApprovalRequest`, `ToolApprovalDecision` (`approve`, `approveAlways`, `approveWithModifiedArguments`, `deny`), `ToolApprovalHandler`.
- `SubAgentContext`, `SubAgentTool`. The context types come from the new design below.
- `MCPClient`, `MCPSession.withTools`, `MCPTool`.
- `LLMClient` protocol as the provider seam, so users can still bring their own client.

## Behavioral details that are easy to get wrong

These are in the reference and covered by its tests. Preserve them:

- **Reserved tool names.** `finish` and the four context tools (`compress`, `decompress`, `search_context`, `context_status`) are reserved. Duplicate and empty tool names are rejected. `finish` must be the only call in its assistant message. A `completionTool` replaces `finish` and ends the run only if it succeeds.
- **Content-only termination.** With the built-in finish tool, a content-only assistant reply can end the run. With a completion tool it cannot. `result.content` is optional.
- **Malformed history checks.** Tool calls must be followed immediately by matching tool results in order. See `MalformedHistoryReason` and `MalformedStreamReason`.
- **Tool result truncation** is middle-out, with a per-tool override.
- **Approval** suspends the loop in place without closing the stream. A handler is required when the policy is not `.none`. `approveAlways` persists in the session allowlist and in checkpoints. The kit provides `ToolApprovalQueue`, a `ToolApprovalHandler` provider with FIFO order (`pending()` and `updates` list parked requests in call order). Requests can be resolved independently in any order by id (`resolve(id:decision:)`, false for an unknown id). `denyAll(reason:)` resolves every parked request as deny and is meant for stop or cancel. A parked request whose awaiting task is cancelled is removed and resolves as deny with reason `"Cancelled"`. In a queue, `approveAlways` resolves only the request it is given. Other parked requests for the same tool name stay parked until resolved; the allowlist applies to later calls only.
- **Checkpointing** is streaming only. A snapshot is written at the end of each iteration, after tools run and before the next request. Resume validates MCP tool bindings and the completion tool identity. `FileCheckpointer` writes one JSON file per checkpoint and skips unreadable files when listing.
- **Token accounting.** `TokenUsageTotals` tracks measurement coverage (`complete`, `partial`, `unavailable`) separately for overall, cache read and cache write. A nil usage makes coverage partial or unavailable and never silently counts as zero. Sums saturate at `Int.max`. A streamed response counts once, after the stream drains and validates. See `Documentation.docc/Articles/TokenAccounting.md`.
- **Sub-agents.** Depth-limited (`SubAgentContext`, default max depth 3). Child events stream to the parent wrapped as `subAgentEvent`. Child token use is reported separately, not in the parent total.
- **Stream event buffer and replay.** Resume replays buffered events. Replayed events do not invoke live callbacks.

## Package layout (suggested)

```
AgentHarnessKit            core: messages, tools, loop, streaming, checkpointing, sub-agents, approval (no database dependency)
AgentHarnessKitContext     billion-context-style context management (depends on GRDB.swift)
AgentHarnessKitALM         HarnessModelClient and provider options (depends on AnyLanguageModel)
AgentHarnessKitMCP         MCP protocol, HTTP transport, stdio transport (macOS and Linux only)
AgentHarnessKitTesting     scripted test client, ported from TestLLMClient
```

Keep the core target free of provider and Apple-only dependencies. ALM traits (MLX, CoreML, Llama) must stay opt-in.

## Phases and acceptance criteria

1. **Phase 0: architecture decision and spike result.** `docs/ARCHITECTURE.md` written. Package skeleton builds on macOS, Linux and iOS.
2. **Phase 1: core data types.** Messages, tools, JSON schema, token accounting, errors. Ported tests pass on macOS and Linux.
3. **Phase 2: model adapter.** `HarnessModelClient` supports generate and stream with tool calls, tested against the mock server from the spike. Continuity replay test (see above) passes for Anthropic.
4. **Phase 3: agent loop.** `Agent.run`, `Agent.stream`, `Chat`, finish and completion tools, iteration and token limits, tool timeouts and concurrency. `TestLLMClient` port available.
5. **Phase 4: approval and checkpointing.** Includes `FileCheckpointer`.
5b. **Phase 4b: context management.** `AgentHarnessKitContext` per the design below, after the GRDB gate passes.
6. **Phase 5: sub-agents and event streaming.** `SubAgentTool`, `StreamEvent` Codable round trip, `AgentStream` where Observation is available.
7. **Phase 6: MCP.** Protocol layer and HTTP transport on all platforms. Stdio on macOS and Linux.
8. **Phase 7: Apple Foundation Models and MLX adapters.**
9. **Phase 8: CI.** GitHub Actions on macOS, Linux (`swift:6.3` container) and the iOS Simulator. Build with `-warnings-as-errors`. Lint with the same SwiftFormat and SwiftLint setup as the reference (`Mintfile`, `Makefile`).

Definition of done for parity: the ported test suite passes on macOS and Linux, the core and ALM targets build and pass the mock-server tests on the iOS Simulator, and a streaming tool-call run works against at least one real provider on each platform.

## Rules

- Never commit API keys. Read them from environment variables. Use obviously fake values in tests and docs.
- Do not modify or fork ALM unless Phase 0 selects Option C. Pin it with `.upToNextMinor`.
- Do not claim a platform works unless you ran tests on it. Mark anything unverified.
- Keep Swift 6 strict concurrency on. No `@unchecked Sendable` without a written justification (the reference documents its few uses).
- Port tests with the code. A feature without its ported tests is not done.
- Prefer a clear negative result recorded in `docs/` over a long workaround.

## Out of scope for now

The `Examples/AgentCode` terminal coding agent, DocC articles (port later), and the Wasm platform (ALM fails to build there). Android is dropped for now; revisit later (the spike showed ALM works on an Android emulator, but GRDB, MCP and CI are untested there).
