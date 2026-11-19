# Test suite audit — 2026-11-18

Scope: every test target in `Package.swift`, plus `Gates/GRDBGate` and `CheckpointResumeProbe`. ~1,250 tests across 6 targets; full suite green on macOS before the audit.

**Evidence tags**
- **MUTATION** — I broke the source in a throwaway worktree and ran the *whole* test target. "Survived" = every test still passed.
- **COVERAGE** — from `swift test --enable-code-coverage`.
- **READ** — from reading code only; not executed.

---

## 1. Tests that don't test what they say

### Confirmed by mutation (the whole target stayed green)

| # | Mutation (source) | Test(s) that claim to cover it | Why they miss it |
|---|---|---|---|
| 1 | `StreamProcessor.swift:287` delete `try Task.checkCancellation()` | `AgentStreamingTests:214 cancellationRespected`, `ChatTests:208 respectsCancellation` | Mock yields 2 deltas and never finishes; `events.count <= 2` holds no matter what. Consumer loop exits on its own cancel. |
| 2 | `Chat.swift:173` `onTermination` no longer cancels the producer task | `ChatTests:208`, `ChatSubAgentStreamingTests:359 cancellationDuringSubAgentTerminatesStream` | Same pattern — consumer can't observe a leaked producer. `try? await task.value` swallows outcome. |
| 3 | `AgentStream.swift:172` resume no longer calls `cancel()` on the in-flight send | `AgentStreamResumeObserverTests:402 resumeCancelsInFlightSendBeforePerformingAwaits` | Asserts `sendGeneration` bump + `sessionID`, both set unconditionally elsewhere. |
| 4 | `AgentStream.swift:216` `replay(from:)` swallows errors (`finish()` instead of `finish(throwing:)`) | (none — only `bufferDisabled` is tested, which returns before this path) | A trimmed/future cursor becomes a silent empty replay. |
| 5 | `StreamEvent.swift:124` rename coding key `request` → `"approvalRequest"` | `StreamEventCodableTests` round-trips for approval events | Round-trip only; no golden JSON for ~11 event kinds (toolCallStarted/Completed, audio*, subAgent*, context*, toolApproval*). A symmetric rename breaks stored archives with no test failure. |
| 6 | `Agent+ToolExecution.swift:225` unknown tool treated as concurrency-safe (`?? true`) | `ConcurrencySafeSchedulingTests:190 unresolvedToolTreatedAsUnsafe` | Nonexistent tool never runs the overlap detector, so `overlaps.isEmpty` is vacuous. |
| 7 | `Agent+Run.swift:157` budget check `>` → `>=` | `AgentTests:490 budgetExactlyEqualToUsageSucceeds` | Usage hits 100 only on the finish turn, which skips the check. Equality never reached. |
| 8 | `ToolResultTruncation.swift:19` drop the tail (`headBudget = contentBudget`) | `PerToolResultLimitTests`, `ChatToolResultTruncationTests`, `ToolApprovalTests:540` | Every expected value is computed *by calling the function under test*. No fixed expected string anywhere. |
| 9 | `MCPClient.swift:144` send `{}` instead of the real tool arguments | All of `MCPToolTests`/`MCPIntegrationTests` | Every handler ignores args (`{ name, _ in`). **Tool arguments are never verified on the wire.** |
| 10 | `HierarchicalContextStore.swift:404` allow `\` in export filenames | `H8SelfTests:68 toFileRejectsPathsAndDisabledExport` | Session has no blocks, so every call fails with `unknownBlock` regardless. `"a\\b"` interpolated into JSON becomes `\b` (backspace). "Disabled export" half never exercised (store has an export dir). |
| 11 | `HierarchicalContextStore.swift:281` `tokensSaved: 0` | `HierarchicalContextStoreTests:117` | `#expect(fold.tokensSaved >= 0)` is always true (`max(0, …)`). `tokensRestored` never asserted. |
| 12 | `ContextPersistenceStores.swift:81,201` `prefix(limit)` → `suffix(limit)` | `PersistenceTests:114`, `H6SelfTests:78`, `HierarchicalContextStoreTests:243` | Limit tests check `.count` only; result ordering under a limit is never pinned. |
| 13 | `HarnessModelClient.swift:174` stream errors map to `.other("x")` | `HarnessModelClientTests:250 streamFailureMapsToLLMError` | `catch AgentError.llmError {}` accepts any case. |

### Caught by the suite, but the named test is still weak (MUTATION)

- **`per-tool timeout ignored`** (`ToolExecutionHelpers.swift:98`) — caught by `perToolTimeoutOverrideRespected` and Chat variants, but `AgentTests:313 perToolTimeoutWiderThanGlobalCompletes` alone wouldn't catch it (asserts scripted `"done"`).
- **`MCPTool` returns empty result** — caught by `MCPToolTests` unit tests, but `MCPIntegrationTests` `agentWithMCPTool:77`, `mixedLocalAndMCPTools:167`, `parallelMCPCalls:204`, `mcpToolTimeout:235` all passed: they assert only the mock LLM's scripted final text. Parallelism and timeout are never checked.
- **`MCPSession` no shutdown on error** — caught by `M2SelfTests`, but `MCPSessionTests:103/127/144` passed (they check only the error type, never a disconnect).

### Suspected from reading (not mutated)

- `MCPClientTests:327 cancellationCleanup` / `MCPToolTests:151 cancellationPropagates` — accept `requestTimeout`; pass only because the 200 ms timeout fires. Related real gap: `MCPClient.swift:177` continuation has no cancellation handler, so a cancelled MCP call waits the full 60 s.
- `MCPSessionTests:57 multipleServersParallel` — checks tool names only; a sequential loop passes.
- `MCPClientTests:360 shutdownResumesAllPending` — only one pending call; reader-stream finish drains it anyway.
- `MCPClientTests:300 notificationInterleaved` — notification arrives before any request is pending; nothing is interleaved.
- `HTTPMCPTransportTests:143` — 202 *with empty body* can't distinguish the 202 branch from the empty-body branch.
- `JSONRPCMessageTests:145 idNullDoesNotCollideWithIntNegOne` — compares two enum constants (tautology).
- `AgentStreamTests:246 cancelStopsStreaming`, `AgentStreamReplayTests:200/235` — assert only what `cancel()` itself sets; no leak or invalidation is measured.
- `AgentStreamIdentityTests:58` + envelope tests — run-ID checks are `!= nil` / `isDisjoint`; a fresh RunID per event would pass.
- `StreamEventCodableTests:149 legacyCompactionEventTypesAreRejected` — `throws: DecodingError.self` without checking the case.
- `StreamEventBufferTests:139 concurrentRecordersPreserveCursorOrdering` — checks `Set` equality (uniqueness), not ordering.
- `AgentResumeTests:235 resumeAtMaxIterationsDoesNotCallClient` — never checks the client wasn't called (exhausted mock returns an empty stream silently).
- `AgentResumeTests:354 resumeRestoresMessagesWithoutRepeatingCompletedTool` — asserts `toolInvocationCount == 0` only; restored history never checked.
- `AgentResumeSubAgentTests:174` — 50 ms sleep, never asserts `.subAgentStarted`; can pass vacuously.
- `ContextToolLoopTests:123 contextToolsWithoutAStoreAreUnknown` — never checks `isError` / not-found message.
- `ToolApprovalTests:99 approvedToolExecutesNormally` — nothing checks the tool actually ran.
- `ToolApprovalTests:605 mixedBatchPreservesOriginalOrder`, `ConcurrencySafeSchedulingTests:154/324` — inputs already in order; the sorts are never exercised.
- `nudgeIsGatedByFloorAndGrowth` (`HierarchicalContextStoreTests:309`) — suppressed by the floor, not the baseline reset it claims to test.
- `SchemaTests:273 onlyOptionalFields`, `SchemaDecoderAdvancedTests:50,81` — check counts / top-level type only.
- `TestLLMClientTests:572,603` — assert `finished` non-empty; `finishContent` set but never asserted.
- Unsupported-media tests (`MappingTests:108,113`, `HarnessModelClientTests:149`) — `throws: AgentError.self` only.
- Silent waits: `waitForBufferedCursor` (Replay:13) and `awaitBufferedCursor` (ResumeObserver:13) time out without recording an issue; `awaitStreamCompletion` and `CrossProcessResumeTests` `waitUntilExit` have no timeout (hang instead of fail).

### Empty / misplaced (READ, confirmed)

- `AgentTruncationTests {}` (`AgentHistoryTests.swift:175`), `SubAgentConcurrencySafeTests {}` (`ConcurrencySafeSchedulingTests.swift:367`) — empty suites.
- `TerminalOutcomeIdentityTests` (`AgentCompletionPolicyTests.swift:115`) — fixture, no tests.
- Two sibling sub-agent tests live inside `private struct NoopParams` (`ConcurrencySafeSchedulingTests.swift:446`). They do run (shows as "Suite NoopParams"), just misfiled.

---

## 2. Gaps (untested behavior)

### Tests that never run in CI (READ)

- **MLX**: CI never enables the `MLX` trait, so `MLXClientTests` compiles to an empty `mlxTestTargetBuilds() {}`. Coverage confirms MLX source isn't built at all. Even with the trait, suites need `AHK_MLX_RUNTIME=1`.
- **FoundationModels**: empty on Linux; on-device suite disabled without Apple Intelligence (likely on macos-26 runners); `guard #available else { return }` passes silently on older macOS.
- **`Gates/GRDBGate`** tests are not run by `ci.yml`.
- **iOS job** (`ci.yml:139`) runs only `AgentHarnessKitTests` + `AgentHarnessKitALMTests` — MCP HTTP transport (the only one available on iOS) and Context/GRDB never run on iOS.

### Low coverage, ranked by risk (COVERAGE)

| File | Line cov. | What's untested |
|---|---|---|
| `Tools/SchemaDecoderContainers.swift` | 24% | most container paths |
| `Tools/SchemaKeyedContainer.swift` | 66% | `nestedContainer`/`nestedUnkeyedContainer`/`superDecoder` (:185-206). READ: these appear to reset the parent schema — likely a real bug producing wrong tool schemas. |
| `Core/Transport/TransportError.swift` | 32% | `isPromptTooLong` (:160-247) has no tests **and no callers** — dead or unwired. |
| `Core/AgentLoop/AgentError.swift` | 59% | descriptions/feedback for many cases |
| `Core/Checkpointing/AgentCheckpoint.swift` | 70% | decode guards for negative iteration (:130) and empty MCP binding names (:27-38). If they regress, the `precondition`s at :15/:106 **trap the process** inside `FileCheckpointer.load` instead of throwing. |
| `ALM/ProviderOptions.swift` | 74% | Gemini branches (:102-117) |
| `Messages/AssistantContinuity.swift` | 19% | |
| `Messages/JSONValue.swift` | 56% | `.double(2.0)` likely round-trips as `.int(2)`; `fromJSONObject` has no callers |
| `LLM/ResponsesHostedToolDefinition.swift`, `Messages/ReasoningConfig.swift`, `LLM/OpaqueResponseItem.swift` | 0% | public encodings unverified (snake_case keys) |

MCP (85–100%) and Context (90–100%) have high line coverage; their gaps are about *assertions*, not reachability.

### Behavioral gaps worth a test (READ, ranked)

1. **Approval handler blocked + run cancelled** (`ToolApproval.swift:113-124`) — the "Stop button" path; untested anywhere.
2. **MCP tool-call cancellation** does nothing (`MCPClient.swift:177`) — cancelled calls wait out the 60 s timeout.
3. **Stdio child exits mid-request** — EOF finish (`StdioMCPTransport.swift:179`) is never the path that ends the stream in tests; also untested: SIGPIPE ignore (:70), >64 KB stderr drain, `workingDirectory`, env *merging* (only override is checked).
4. **Unmatched / null-id JSON-RPC responses** silently dropped (`MCPClient.swift:237`) → server parse errors become timeouts. **Server-initiated requests** (`ping`, sampling) dropped with no reply (:242).
5. **MCP init/list errors**: JSON-RPC error collapses to `invalidResponse("Missing result")`; repeating cursor loops forever (:278-293); init timeout untested.
6. **ALM `ErrorMapping`**: only 500 → `httpError` tested. 429 → `rateLimited`, provider/decoding/invalidResponse/default branches untested; `retryAfter` is always nil.
7. **`ToolBridging` validation** (`:24-29`, `:55`) never exercised; `:63` skips verification when `items` missing.
8. **Context persistence**: rejected save leaves state intact (never reloaded after the throw); GRDB corruption paths; `deleteSession` with blocks (orphan `block_source` rows); store-level partial compress success.
9. **Structured output decode failure** (`Chat.swift:113`) and malformed finish args on the non-streaming `run` path (`Agent+Run.swift:174`).
10. **Denied tool result truncation** on the non-streaming path (`Agent+ToolResults.swift:79`).
11. **Stream timestamp validation**: impossible dates (`StreamEvent.swift:371`) and the 4-digit-year guard (:423) — deleting the guard would write archives that can't be read back.
12. **`FileCheckpointer`** same-iteration tie-break is only tested on the in-memory checkpointer; `.iso8601` drops fractional seconds, so same-second saves likely tie.
13. **`ToolCall` `.custom` kind** never round-tripped (silently decodes as `.function`).

---

## 3. Redundant tests

Strict bar: same code path, same inputs, same (or subsumed) assertions.

**Exact / near-exact duplicates (safe to delete one)**
- `ChatTests:150 handleToolNotFoundGracefully` ≡ `ChatTests:180 unknownToolFeedbackSurvivesContentOnlyTermination` (only the user text differs) — verified.
- `HTTPMCPTransportTests` vs `M4SelfTests`: `emptyBody:83`≡`:247`, `onlyOneLeadingSpaceStripped:56`≡`:222` (verified), `networkErrorThrowsConnectionFailed:206`≡`:153`, `non2xxThrows…:177`≡`:120`, `notFoundClearsSessionId:189`≡`:134`. **The whole SSE block in M4 (:206-249) is subsumed by `SSEParsingTests`.**
- `H8SelfTests:32 renderWithoutWindowThrows` ≡ `HierarchicalContextStoreTests:46 missingWindowSizeIsAnError`.
- `H1SelfTests:6 tokenLabelTruncates` ⊂ `RefsAndRenderTests:24-30`.
- `ContextToolLoopTests:216 checkpointVersionIsOptionalInJSON` ⊂ `H9SelfTests:212`.
- `StreamEventCodableTests`: `:461` ⊂ `:378`; `:56 finishedRoundTrips` ⊂ `StreamEventWireFormatTests:44`; `:91` ⊂ Wire `:86`; `:555` ⊂ `:597`.
- `V02CrossFeatureTests:356` ⊂ `PartialTurnRecorderTests:130` (and its doc comment is wrong about finish being "unanswered").

**Subsumed (stronger sibling exists)**
- `AgentIterationHistoryTests:18` ⊂ `:62`.
- `ChatApprovalTests:152` ⊂ `ChatSubAgentStreamingTests:191`.
- `ToolApprovalQueueTests:87` ⊂ `:103`.
- `TerminalAnswerHistoryTests:195` ⊂ `AgentHistoryTests:140`.
- MCP client: `M2:128`≈`MCPClientTests:64`, `M2:178`≈`:277`, `M2:193`⊂`:486`, `M2:248`⊂`:509`, `M2:231`≈`MCPIntegrationTests:286`; `MCPSessionTests:57/79/103` weaker than `M2:265/286/308`; `M1:49,82,32` subsumed by `MCPToolTests` param rows.

**Parameterize instead of duplicate**
- `AgentResumeTests:574` / `:617` (differ only in `iterationUsage`).
- `AgentTests:380` / `ContentOnlyTerminationTests:180` — names claim a client-type difference that no longer exists in source.

**Milestone files (`M1–M4`, `H1–H9` SelfTests)**: none is wholly redundant. Each still holds unique coverage (e.g. `M4:94` is the only 202-with-body test, `M4:107` the only `.lowercased()` header test, `M1:57` the only `isError ?? false` decode, all of `M3` is the real stdio coverage). Recommend folding their unique tests into the topical files and deleting the rest.

**Checked and *not* redundant**: `PerToolResultLimit` vs `ChatToolResultTruncation` (Agent vs Chat), `ToolApproval` vs `ChatApproval`, `PartialTurnRecorder` vs `…Stream`, `AgentStream` vs `AgentStreaming`, `SchemaTests` vs `SchemaDecoderAdvanced`, `MessageTests` vs `ChatMessageHistory`, ALM `Mapping` vs `HarnessModelClient` vs `AgentOverAdapter`.

---

## Suggested order of work
1. Golden-JSON tests for every `StreamEvent` kind (#5 — protects stored archives).
2. Real cancellation tests (#1–3, MCP cancel) with a producer-side probe, not consumer-side counts.
3. Fixed-value truncation test (#8) and MCP argument-on-the-wire test (#9).
4. CI: run `Gates/GRDBGate`, add an MLX-trait compile job, widen the iOS `-only-testing` list.
5. Delete/merge the duplicates above.
