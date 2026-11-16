# Architecture

Status: decision record for Phase 0. Option A is selected and proven against the mock (section 1); the GRDB gate remains open. Evidence references are to `docs/spike/SPIKE_REPORT.md` and `spike-final:Sources/SpikeCore/Scenarios.swift`.

## 1. Decision: ALM is transport, not the agent loop

**Choose Option A.** `HarnessModelClient` implements the existing stateless `LLMClient` seam. Each harness iteration makes one ALM request with a freshly reconstructed `Transcript` through the public `LanguageModel.respond(within:to:...)` / `streamResponse(within:to:...)` seam; a stopping delegate returns tool calls before execution. The existing `Agent` loop remains the only execution path and owns approvals, tool execution, checkpoints, context, and sub-agents. No ALM-owned loop will coexist with it.

Spike evidence:

| Scenario | Evidence and relevance |
| --- | --- |
| S1 | Incremental streaming passed on macOS, iOS Simulator, and Linux with mock and a real local endpoint; the adapter can preserve streaming. |
| S2 | Tool declaration, arguments, outputs, and usage crossed ALM on those platforms. Its automatic execution is not used by Option A. |
| S3 | `.stop` returned tool calls unexecuted; `Transcript` was readable and Codable; reconstruction and cross-process resume passed. This is the main Option A control primitive. |
| S4 | Delegate denial prevented execution and supplied model-visible output. Option A instead emits its own tool-result messages after harness approval. |
| S5 | Cancellation stopped promptly on the tested platforms, so the stateless stream can retain harness cancellation. |
| S6 | Real Anthropic on macOS returned two parallel calls and replayed signed thinking before `tool_use` after JSON reconstruction. Other continuity cases remain open. |

Option B would save some adapter code because S3/S4 prove its session loop can be controlled, but it moves iteration and approval semantics into ALM delegates and abandons the established provider seam. Option C (an ALM contribution or fork) adds an upstream dependency and provider-maintenance burden without evidence that it is needed yet.

**Flip to C if** the proof or subsequent adapter tests show that ALM cannot accept the full required history, stop before every tool execution, return usable streaming calls, or replay required reasoning/continuity data through one request per harness iteration—and a thin adapter cannot recover those semantics. A missing provider feature alone is not grounds for a second harness loop.

### Option A proof

Throwaway package (not in tree), ALM 1.3.0, in-process mock speaking OpenAI Chat Completions, request bodies captured by a recording transport. 11/11 swift-testing tests pass on macOS (Swift 6.4.2) and Linux (`swift:6.3`, Swift 6.3.3).

| Check | Result |
| --- | --- |
| `session.respond` + tools + `.stop` delegate | 1 request; `tools=["add"]` in body; call `call_mock_1 add {"a":2,"b":3}` returned; tool body not run |
| Same with `streamResponse` | 1 request; stopped snapshot carries the `.toolCalls`; tool not run |
| Hand-built transcript as full history | 1 request; body order `system → user → assistant(tool_calls) → tool("5", tool_call_id) → user("")` |
| Two-iteration harness loop | 2 requests total; tool run once by the caller; final answer correct |
| `model.respond(within:to:)` with a session built from the transcript | 1 request; body is exactly the transcript, **no appended prompt**; `to:` is ignored by providers |
| Same + `.stop` | `response.transcriptEntries == [.toolCalls]`, **no trailing empty `.response`**; session transcript unchanged |
| Same with `streamResponse(within:to:)` | 1 request; tool calls in snapshot; not run |

Source refs (ALM 1.3.0, `Sources/AnyLanguageModel/`): seam `LanguageModel.swift:35-55`; providers build the body from `session.resolvedRequestContext().transcript` (`Models/OpenAILanguageModel.swift:570,748,936`, `Models/AnthropicLanguageModel.swift:527-537`; Ollama falls back to the prompt only when the transcript is empty, `Models/OllamaLanguageModel.swift:193-200`); delegates are read from the session (`ProfileToolExecution.swift:237-240`). Only the OpenAI Chat path ran; Anthropic, Gemini, Responses and Ollama claims are source reads.

## 2. `ChatMessage` remains canonical

Core keeps AgentRunKit's Codable `ChatMessage`, `AssistantMessage`, `ToolCall`, and continuity types. ALM `Transcript` is an adapter-local, per-request representation, never the checkpoint schema or a core public API. `AgentHarnessKitALM` owns both conversion directions.

| Core value | ALM `Transcript` representation | Fidelity notes |
| --- | --- | --- |
| `.system(String)` | `.instructions` with text | Multiple/interleaved system messages may not retain distinct provider semantics. |
| `.user(String)` / `.userMultimodal` | `.prompt` with text and supported media segments | Provider/ALM media support is per-type; unsupported segments must not silently disappear. |
| Assistant content | `.response` text segments | Empty stop artifacts are filtered as in section 3. |
| Assistant tool calls | One `.toolCalls` entry for that assistant turn | Preserve id, name, order, and JSON arguments; JSON formatting/key order need not be byte-stable. |
| `.tool(id:name:content)` | `.toolOutput` with the same id/name and text | Core text results cannot represent every possible ALM media output losslessly. |
| Assistant reasoning | `.reasoning` entries, including `signature` when present | Preserve original entry order and signed bytes for replay; do not regenerate signatures. |

One core assistant can correspond to adjacent reasoning, response, and tool-call entries. Preserve the generated suffix and provider-native ordering in `AssistantContinuity` when semantic fields alone would lose it, especially for multiple signed/redacted blocks and opaque Responses items. Known unproven or potentially lossy paths are redacted thinking, streaming thinking, adaptive/other Anthropic models, OpenAI Responses opaque items, OpenRouter reasoning details, custom tool kinds, and multimodal variants. Nil usage remains nil rather than becoming zero.

## 3. Adapter workarounds

**Final choice: call the model directly, not the session.** Per request, `HarnessModelClient` builds `LanguageModelSession(model:tools:transcript:)` from the converted history, sets a delegate that returns `.stop` for every call, and calls `model.respond(within: session, to: Prompt(""), ...)` (or `streamResponse(within:...)`). Both quirks disappear: the session commits nothing, so there is no empty trailing `.response`, and the transcript is the whole request, so no prompt is appended. Costs: `session.usage` does not accumulate (read `response.usage` / snapshot usage per request, which is what `TokenUsage` wants anyway), and the empty `Prompt` argument is a dummy.

Fallback only if a provider turns out to read the `to:` prompt:

- **Empty trailing response:** after `.stop`, `session.respond` commits `[toolCalls, response("")]` (`LanguageModelSession.swift:1911`). It is not cosmetic: `Transcript.replayEntries` (`Shared/ToolContinuation.swift:309,372,380`) then inserts `"The tool call was not executed."` and an empty assistant turn. Drop it only when it is empty text directly after `.toolCalls`.
- **Mandatory user prompt:** `respond(to:)` always appends one (`LanguageModelSession.swift:441`); an empty prompt is sent as `user: ""`. Avoid it on Anthropic: empty text blocks are not filtered (`Models/AnthropicLanguageModel.swift:1383-1392`) and the API rejects them (source read, not run).

## 4. GRDB layout

**Choose one shared database keyed by `SessionID`, at a caller-supplied directory and file URL.** A single migration/version domain and one `DatabasePool` serve parent and child sessions; per-session databases would multiply pools/files and make lifecycle management harder without improving resume. The trade-off is shared writer contention and a stronger need for scoped queries.

- Production uses `DatabasePool` with WAL; tests may use `DatabaseQueue`. Callers create/select the persistent directory explicitly. Neither context storage nor `FileCheckpointer` assumes `TMPDIR`, a home directory, or an iOS-writable global location.
- Every message, block, source relationship, and state-version lookup is session-scoped. Sub-agents use independent ids in the same database; no lineage join or search may cross sessions.
- FTS5 indexes raw message text and summaries. Search joins hits back to scoped rows and filters by `sessionID`; FTS5 itself is not the isolation boundary. Originals are archived, not deleted.
- Cross-process resume requires reopening the same configured database URL. WAL permits concurrent readers but still has one writer; this is preferred here over uncoordinated per-session stores.
- The checkpoint identifies the expected context state, while the database owns folded text and originals. No folded snapshot is duplicated into checkpoint JSON.

The GRDB gate is **still pending**: dependency resolution alongside ALM, migrations/read-write, `DatabasePool`, FTS5 capabilities/SQLite version, and second-process open must be measured separately on macOS, Linux, and iOS before `AgentHarnessKitContext` is accepted.

## 5. Session identity, loop, checkpoints, and sub-agents

1. `SessionID` identifies durable conversation/context state; `RunID` identifies one invocation. Public entry points may omit a session id and generate one, but the loop always carries a concrete id through `InvocationOptions` and `StreamEventFactory`. `Chat` retains its id across sends.
2. Before every model request the loop calls `ContextStore.render(sessionID:)`; after assistant/tool completion it records those messages and usage for the same id. `LLMClient` remains stateless and receives only the rendered `[ChatMessage]`.
3. Streaming checkpoints retain the existing end-of-iteration boundary and loop fields, including messages and approval allowlist. Replace compaction state with `sessionID` plus an opaque block-state version from `ContextStore`; the core does not expose GRDB types.
4. Resume restores the checkpoint's session id, creates a new run id, and validates the live store's version before replay or another model call. Missing stores, wrong sessions, and stale versions fail explicitly. Existing MCP-binding and completion-tool identity checks remain. Replayed events keep their original run/checkpoint provenance and do not fire live callbacks.
5. Each sub-agent invocation mints a child `SessionID` and uses it for context and checkpoints. Parent history inheritance copies messages only. The outer `subAgentEvent` retains parent/tool-call correlation while the nested event carries the child session/run identity; child usage remains separate from parent usage.

## 6. Targets and dependency rules

| Target | Owns | May depend on |
| --- | --- | --- |
| `AgentHarnessKit` | Messages, tools, `LLMClient`, `ContextStore`, loop, streaming, approval, checkpoints, sub-agents | Foundation only; no ALM, GRDB, provider, or Apple-only target |
| `AgentHarnessKitALM` | `HarnessModelClient`, transcript/schema mapping, ALM provider options | Core + AnyLanguageModel |
| `AgentHarnessKitContext` | GRDB context implementation and migrations | Core + GRDB |
| `AgentHarnessKitMCP` | MCP protocol, HTTP everywhere, stdio on macOS/Linux | Core + platform networking/process facilities |
| `AgentHarnessKitTesting` | Scripted `TestLLMClient` and test support | Core |
| `AgentHarnessKitFoundationModels` / MLX targets | Future opt-in Apple adapters | Core and only their guarded provider dependencies |

Agent code depends on protocols, never concrete adapters. Context, ALM, and MCP do not depend on one another. Core declares context events and storage contracts without database types. Apple-only source is isolated or guarded; Observation is verified or gated. Swift 6.3+ strict concurrency remains enabled. ALM is pinned `.upToNextMinor(from: "1.3.0")`; CoreML, MLX, Llama, and AsyncHTTPClient traits are off by default and selected only by opt-in products/targets.

## 7. Platform status

These are spike results, **not AgentHarnessKit acceptance results**. The spike used ALM 1.3.0, traits off; macOS used Swift 6.4.2 and Linux used Swift 6.3.3.

| Capability | macOS | iOS Simulator | Linux |
| --- | --- | --- | --- |
| Spike S1–S5, mock | PASS | PASS, SwiftPM command-line binary | PASS |
| Spike S1–S5, real local OpenAI-compatible endpoint | PASS | PASS | PASS |
| Real Anthropic S1–S6 | PASS | NOT RUN | NOT RUN |
| Option A one-request adapter proof (mock) | PASS | NOT RUN | PASS |
| Package skeleton `swift build` + `swift test` | PASS | build PASS (SwiftPM `--triple arm64-apple-ios17.0-simulator`) | PASS |
| AgentHarnessKit core/adapters and ported tests | NOT RUN | NOT RUN | NOT RUN |
| GRDB pool, migration, FTS5, second process | NOT RUN | NOT RUN | NOT RUN |
| OpenAI proper and Responses opaque replay | NOT RUN | NOT RUN | NOT RUN |
| Apple Foundation Models / MLX adapters | NOT RUN | NOT RUN | N/A |
| App sandbox and ATS | N/A | NOT RUN | N/A |
| `xcodebuild` package build | N/A | PASS (skeleton, no `-skipMacroValidation`) | N/A |

The iOS simulator pass used `simctl spawn`, not a host app. Android spike evidence is intentionally deferred with Android.

**Macro trust:** the maintainer enabled `AnyLanguageModelMacros` in Xcode locally. The skeleton expands no ALM macro, so the trust prompt is not exercised yet. CI runners cannot click the trust prompt: when code first expands an ALM macro (e.g. `@Generable`), the iOS CI job needs `-skipMacroValidation`; record that change when it happens.
