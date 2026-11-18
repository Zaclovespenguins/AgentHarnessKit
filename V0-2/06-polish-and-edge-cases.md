# Phase 6: polish and edge cases after the v0.2 release pass

Findings from the Phase 5 run (5.1 spec pass, 5.2 API audit, 5.3 local check, cross-feature tests) and the final edge-case review. Items marked **Done** below are fixed on `claude/elegant-ride-dihv1s`. Each item is sized for one agent, like the 01–05 files, and follows the rules in [README.md](README.md).

## Where Phase 5 stands

| Task | State | Notes |
|------|-------|-------|
| 5.1 Spec consistency | Done | Cancel text aligned between the Approval and Partial history bullets; one-approval-per-run rule added to the spec; changelog entry for `partialHistory`. Two behavioral findings: 6.1 and 6.2. |
| 5.2 Public API audit | Done | Table in [5.2-public-api-audit.md](5.2-public-api-audit.md). Doc comments added to `ToolApprovalQueue.init()` and `AgentStream.cancel()`. Paste the table into the release PR description. |
| 5.3 Full local check | Done | `swiftformat --lint` 0/222, `swiftlint --strict` 0 violations, `swift test --parallel -Xswiftc -warnings-as-errors` 1116 tests / 191 suites pass, `make acceptance` 0 failures (Linux, Swift 6.3.1). `make check` itself needs `mint`; its three parts were run directly. |
| 5.4 CI | Done | Merged to `main` directly at `3042004`; [CI run 12](https://github.com/Zaclovespenguins/AgentHarnessKit/actions/runs/44185720070) green: Lint (SwiftFormat, SwiftLint, acceptance), macOS, Linux (Swift 6.3), iOS Simulator. Live provider jobs skipped (secret-gated). |
| 5.5 Changelog and version | Not started | Unblocked. |
| 5.6, 5.7 | Human | App-side deletions and the `v0.2.0` tag. |

Branch note: items 1 and 2/3 were on unmerged branches (`claude/v0-2-phase-1-distribution-l20lsp`, `claude/wizardly-thompson-bauhgg`) and were merged into `claude/lucid-wozniak-1149gt` at the start of Phase 5.

## Behavior decisions (need a human call first)

### 6.1 Cancel between the `finish` commit and `.finished` — Done (option a)

- **Found by:** 5.1; reproduced at recorder level by `V02CrossFeatureTests.snapshotWithCommittedFinishCallIsValidHistory`.
- **Problem:** `Agent.swift` commits the assistant message to the recorder (`commitAssistant`, then `markIterationComplete`) before yielding `.iterationCompleted` and before `.finished`. `AgentStream` clears `currentRecorder` only in `handleFinished`. A `cancel()` in that window gives a non-nil `partialHistory` that holds the `finish` call plus the synthetic `"Cancelled by user before this tool returned."` result. The answer the model already gave is presented to it as cancelled, and the spec says `partialHistory` is nil after a turn that finished. The history is valid and a resend completes (`resendAfterCancelAtFinishIterationCompletes`), so this is a semantics gap, not a crash.
- **Options:** (a) in `PartialTurnRecorder.snapshot()`, when the last assistant's only call is `finish`, apply the same restore as `sanitizedTerminalHistory()` (answer as plain text, no synthetic result); (b) mark the recorder sealed once the loop decides `finish` and make `cancel()` report nil; (c) document the window.
- **Recommendation:** (a). It keeps the user's view consistent with item 2 and reuses existing code. Expose the restore as a `package` helper in `ChatMessageHistory.swift` rather than duplicating it.
- **Tests:** recorder unit test: finish-only commit → snapshot ends with the restored assistant text and has no `.tool` for `finish`; finish plus text → merged per the spec rule. A stream-level test that cancels on `.iterationCompleted` for the finish iteration (the pattern in `AgentOverAdapterTests.cancelAfterEmptyStopResponseLeavesNoEmptyAssistantInSnapshot`).

### 6.2 Stop flow order: `denyAll` then `cancel()` is racy — Done (docs, README, spec, test)

- **Found by:** 5.1.
- **Problem:** the `ToolApprovalQueue` doc example (`ToolApprovalQueue.swift`, class comment) and `README.md` tell the app to `await queue.denyAll(...)` and then `stream.cancel()`. Between the two, the loop can record the deny as a tool result, so `partialHistory` holds either the deny text or the synthetic cancelled text depending on timing. `cancel()` first, then `denyAll` (for requests from other runs on the same queue) is deterministic: the snapshot is taken before anything resumes.
- **Do:** change the doc example and README to `stream.cancel()` first, then `await queue.denyAll(reason:)`. Spec wording under Approval if it mentions order.
- **Tests:** `denyAllThenCancelKeepsTheDenyResult` covers the slow path only. Add a test that calls `cancel()` while parked and then `denyAll`, and asserts the synthetic text, the queue empty, and no tool result containing the deny reason.

### 6.3 `partialHistory` after an error — Done (kept, documented, pinned by test)

- **Problem:** when the stream ends with an error, `runStreamTask` sets `error` but leaves `currentRecorder` in place. A later `cancel()` (an app's Stop button that is still enabled, or the next `send`, which calls `cancel()` first) fills `partialHistory` from the failed turn. The spec only describes cancel and normal finish.
- **Decide:** keep it (useful: the app can retry from the failed turn) and document it, or clear the recorder on error.
- **Recommendation:** keep and document; add a test either way so the behavior is pinned.

### 6.4 Duplicate `toolCallId` across runs sharing a queue — Done (documented; token API deferred)

- **Problem:** ids are only unique within one conversation (`TestLLMClient` and many mocks emit `call_1` in every run), so two runs or two sub-agents sharing a queue can park the same id. `resolve(id:)` takes the oldest; a UI cannot target the newer one. Pinned by `V02CrossFeatureTests.duplicateToolCallIdsResolveOldestFirst`.
- **Options:** add `resolve(request:decision:)` keyed by an opaque per-park token exposed on a `ParkedApproval` wrapper in `pending()`/`updates`; or document that ids must be unique across runs that share a queue.
- **Recommendation:** document now (v0.2), add the token-based API in a later minor release, since it changes the `pending()` element type.

## Gaps in scope

### 6.5 Partial history only through `AgentStream` — Done (public recorder)

- `PartialTurnRecorder` and `InvocationOptions.partialTurnRecorder` are `package`. Consumers of `Chat.stream` or `Agent.stream` (non-Observation code, server-side Linux use) get nothing after cancel, which is the case item 1 was meant to remove. `AgentStream` also requires `Observation`.
- **Do (proposal):** a public entry point, e.g. `Agent.stream(..., partialHistory: PartialHistoryHandle)` where the handle is a small public `Sendable` class with `snapshot() -> [ChatMessage]?`. Decide in the spec before coding.
- **Done:** no new wrapper. `PartialTurnRecorder` is public (`init()`, `snapshot()`, `cancelledToolResultContent`; the writers stay `package`), and both public `Agent.stream` overloads and `Agent.resume(from:)` take `partialTurnRecorder:`. `snapshot()` returns an empty array, not nil, before the turn starts. `Chat.stream` is out of scope. Spec bullet updated; covered by `agentResumeRecordsIntoCallerRecorder` and the 6.14 test.

### 6.6 Sub-agent work is lost on cancel — Done (documented)

- Cancelling a parent while a sub-agent runs gives the parent's sub-agent tool call the synthetic cancelled result; the child's own partial history is discarded. Decide whether the synthetic result should carry a short summary of the child's completed iterations, or document the loss. Low priority.
- **Done:** documented the loss in the spec and on `AgentStream.partialHistory`. A summary in the synthetic result would need a recorder per child; left for a later release if anyone asks.

## Tests to add

| # | Test | Where | Why |
|---|------|-------|-----|
| 6.7 | **Done** (`AgentStreamResumeCancelTests`). `partialHistory` after `cancel()` during `resume(from:)`: cancel before the checkpoint loads (nil), and mid-iteration after resume (checkpointed messages plus in-flight text). | `AgentStreamResumeObserverTests` or a new `AgentStreamResumeCancelTests` | 5.2: `resume` body changed and no test asserts `partialHistory` there. |
| 6.8 | **Done, premise corrected.** `resume` rejects such a checkpoint with `malformedHistory(.unfinishedToolCallBatch)` before the turn starts, so there is nothing to synthesize; the test pins that and nil `partialHistory`. Resume from a checkpoint whose history ends with an assistant tool call with no result, then cancel immediately: snapshot synthesizes the cancelled result and validates. | same | `begin(baseHistory:)` gets the checkpointed messages unchanged. |
| 6.9 | **Done.** 6.1 and 6.2 tests above. | `PartialTurnRecorderTests`, `V02CrossFeatureTests` | Behavior fixes. |
| 6.10 | **Done** (in `ToolApprovalQueueTests`). Queue concurrency: `denyAll` while three runs are parked resumes all three with the deny, in FIFO order, and `updates` emits exactly one empty snapshot. | `ToolApprovalQueueConcurrencyTests` | 5.2: concurrency suite never touches `denyAll` or `updates`. |
| 6.11 | **Done** (`parallelSubAgentsParkOnSharedQueueAndResolveOutOfOrder`). Sub-agents in parallel waves both parked on a shared queue (loop level), resolved out of order. | `ToolApprovalQueueConcurrencyTests` | 5.1 confirmed sub-agent tools run in concurrent waves with the shared handler; existing loop-level coverage uses separate top-level runs. |
| 6.12 | **Done** (`package subscriberCount()`). Strengthen `V02CrossFeatureTests.terminatedSubscriberDoesNotBlockOthers`: the dropped iterator going out of scope does not reliably terminate the `AsyncStream`. Cancel a consuming task instead and assert the store drops the subscriber (e.g. via a `package` subscriber count). | `ToolApprovalQueueTests` | Current test passes whether or not removal happens. |
| 6.13 | **Already covered** by `completionToolRunHistoryIsUnchanged` and `completionToolStreamHistoryIsUnchanged`; `Chat` has no completion tool. Terminal answer through `Chat.stream` and non-streaming `Agent.run` with a `completionTool` configured: history unchanged (spec says completion-tool runs are untouched). | `TerminalAnswerHistoryTests` | Only the `finish` paths are covered end to end. |
| 6.14 | **Done** (`cancelWhileParkedInQueueGivesSyntheticResultOverAdapter`, through the public recorder). Mock-server (`MockServer`) cancel-during-parked-approval through `HarnessModelClient`, so item 1 + item 4 are covered over the real adapter on macOS/Linux/iOS. | `AgentOverAdapterTests` | Roadmap item 1 asks for mock-server coverage; the cross-feature tests use a scripted client. |

## Polish

- **6.15 (Done) Doc comments** (5.2): `AgentStream.init`, both `AgentStream.send` overloads (now document that `send` cancels the previous turn and clears `partialHistory`), `PartialTurnRecorder.init()`, `sanitizedTerminalHistory()`.
- **6.16 (No change) `public extension` in the adapters** (5.2): SwiftFormat's default `extensionAccessControl` rule produces this form (see `1c2544f`) and the rest of the sources use it, so explicit member `public` would fail lint. `FoundationModelsClient.swift` and `MLXClient.swift` moved `public` from members to `public extension`. Access is unchanged; restore explicit `public` on members if the project prefers greppable declarations. Not compiled on Linux, so check on macOS.
- **6.17 Stale task text (Done):** `V0-2/04-queued-approval-handler.md` 4.2 describes a token set for cancel-before-enqueue; the shipped code checks `Task.isCancelled` inside `park` instead (`ToolApprovalQueueStore.park`). Update the task text to match. `ROADMAP_V0.2.md` and 04 name `ToolApprovalCoordinator`; say it is the app class.
- **6.18 (Done) `denyAll` on an empty queue** publishes an unchanged empty snapshot to every subscriber. Skip the publish when nothing was parked.
- **6.19 (Won't fix) Commit trailers:** the commits are on `main` and tagged; changing them means rewriting published history. some Phase 5 agent commits carry a Haiku `Co-Authored-By` line, others Opus. Harmless; standardize if the project cares.
- **6.20 (Done: `make check-local`) `make check` without mint:** `swiftformat` 0.60.1 and `swiftlint` 0.63.0 are on PATH in the cloud image. A `make check-local` target calling them directly would let agents run the real target.

## Run order

```
6.1, 6.2, 6.3, 6.4 decisions (human) ─► fixes + their tests (6.9)
6.7, 6.8, 6.10 – 6.14 tests          parallel-safe with each other
6.15 – 6.18 polish                   parallel-safe
5.5 ─► 5.6 ─► 5.7   (5.4 done)
```

6.5 and 6.6 are scope questions; they can move to v0.3 without blocking the release.
