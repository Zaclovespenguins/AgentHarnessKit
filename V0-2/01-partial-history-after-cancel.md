# 1. Partial history after Cancel — sub-tasks

**Roadmap goal:** after Stop/Cancel, `AgentStream` exposes the interrupted turn as valid history (text so far, tool calls issued, tool results received), so the app can delete `StoppedTurnReply`.

**Why the stream events are not enough:** `AgentStream` only sets `history` from `.finished` (`AgentStream.swift` `handleFinished`) and from replayed `.iterationCompleted`. `.toolCallStarted(name:id:)` carries no arguments, so a reply rebuilt from events cannot reproduce the assistant tool-call message. The loop already holds the exact messages (`state.messages`), so the design below has the loop write into a recorder that `AgentStream` reads on cancel, the same pattern as `SaveObservingCheckpointer` in `AgentStream.swift`.

**Fixed design (tasks below implement it):**

- `PartialTurnRecorder`: a `Sendable` final class backed by `NSLock`, in `Sources/AgentHarnessKit/Core/Streaming/PartialTurnRecorder.swift`. Package-visible API:
  - `begin(baseHistory: [ChatMessage])` — messages as of the start of the turn (system + history + user message).
  - `appendText(_:)` — assistant text deltas for the in-flight response.
  - `commitAssistant(_ message: AssistantMessage)` — the full assistant message once the stream drains (has tool calls with complete arguments).
  - `appendToolResult(id:name:result:)` — each tool result as it is appended to `state.messages`.
  - `markIterationComplete(messages: [ChatMessage])` — replaces state with the loop's validated messages.
  - `snapshot() -> [ChatMessage]` — sealed history (see 1.2 rules).
- Dangling-call policy (spec text in 1.0): a tool call whose arguments were fully received but has no result gets a synthetic error result `"Cancelled by user before this tool returned."`; a call still streaming arguments is dropped. Empty assistant messages (the `.stop` empty trailing `.response` quirk) are dropped.
- `AgentStream` gets `public private(set) var partialHistory: [ChatMessage]?`, set on cancel/stop, cleared on next `send`/`reset()`. `history` keeps its current meaning.

---

## 1.0 Write the cancel rules into the spec

- **Depends on:** nothing. **Parallel-safe** with 2.0 and 4.0.
- **Read first:** `AGENTHARNESSKIT_PARITY_SPEC.md` ("Behavioral details that are easy to get wrong"), `docs/ARCHITECTURE.md` section 3 (adapter quirks, `.stop` empty `.response`).
- **Do:** add a bullet **Partial history after cancel** stating: what `partialHistory` contains; the dangling-call policy above (synthesize for complete calls, drop incomplete ones) and why (keeps `validateForLLMRequest` green and keeps what the model asked for); empty trailing assistant messages are dropped; cancel during a parked approval synthesizes the cancelled result for the parked call; `partialHistory` is nil after a turn that finished normally.
- **Done when:** spec diff only.

## 1.1 `PartialTurnRecorder` type (no wiring)

- **Depends on:** 1.0.
- **Read first:** `Sources/AgentHarnessKit/Messages/ChatMessage.swift`, `AssistantMessage.swift`, `ToolCall.swift`, `Sources/AgentHarnessKit/Tools/ToolResult.swift`, `Sources/AgentHarnessKit/Core/Streaming/ToolCallAccumulator.swift`.
- **Do:** create `PartialTurnRecorder.swift` with the API in the design above. Foundation-only, `package` access, `Sendable`, no `Observation`. Use `NSLock` (`final class … : @unchecked Sendable` with all state behind the lock). Do not use `Mutex`: the package targets macOS 14 / iOS 17 and `Synchronization.Mutex` needs macOS 15 / iOS 18.
- **Done when:** `swift build` passes.

## 1.2 `snapshot()` sealing logic + unit tests

- **Depends on:** 1.1.
- **Do:**
  - Implement `snapshot()`: start from committed messages; if there is uncommitted text, add it as an assistant message with no tool calls; add synthetic results for committed calls missing a result, in call order; drop empty assistant messages; return a history that passes `validateForLLMRequest()`.
  - Create `Tests/AgentHarnessKitTests/Core/Streaming/PartialTurnRecorderTests.swift`: text only; committed calls with no results; some results; all results; empty trailing assistant; `markIterationComplete` then new text; every case asserts `validateForLLMRequest()` does not throw.
- **Done when:** `swift test --filter PartialTurnRecorderTests` green.

## 1.3 Wire the recorder into the streaming loop

- **Depends on:** 1.2.
- **Read first:** `Sources/AgentHarnessKit/Core/AgentLoop/Agent.swift` (internal `stream(...)` at ~243/265 and the iteration loop), `Agent+StreamingLoop.swift`, `Agent+ToolResults.swift` (`appendToolResults`), `Sources/AgentHarnessKit/Core/Streaming/StreamProcessor.swift`, `InvocationOptions.swift`.
- **Do:**
  - Add an optional `partialTurnRecorder: PartialTurnRecorder?` to `InvocationOptions` (package-visible, default nil).
  - Call `begin` once the initial messages are built; `appendText` where `.delta` is yielded; `commitAssistant` where the drained assistant message is appended to `state.messages`; `appendToolResult` from `appendToolResults`; `markIterationComplete` where `.iterationCompleted` is emitted.
  - Nil recorder must cost nothing and change no behavior.
- **Do not:** touch `AgentStream` yet; do not change public `Agent.stream` signatures.
- **Done when:** `swift test` fully green (no behavior change).

## 1.4 Expose `partialHistory` on `AgentStream`

- **Depends on:** 1.3.
- **Read first:** `Sources/AgentHarnessKit/Core/Streaming/AgentStream.swift` (`send`, `cancel`, `reset`, `SaveObservingCheckpointer`).
- **Do:**
  - In `send`/`resume`, create a recorder per generation and pass it via `InvocationOptions`.
  - In `cancel()`, set `partialHistory = recorder.snapshot()` before bumping `sendGeneration`; only if the turn had not finished.
  - On `.finished`, set `partialHistory = nil`. Clear in `reset()`.
  - Doc comment: "History of the interrupted turn after `cancel()`; pass it as `history:` to the next `send`."
- **Done when:** `swift build` passes and `swift test --filter AgentStreamTests` green.

## 1.5 Cancel tests over `TestLLMClient`

- **Depends on:** 1.4. **Parallel-safe** with 1.6.
- **Read first:** `Tests/AgentHarnessKitTests/Core/Streaming/AgentStreamTests.swift`, `StreamingTestHelpers.swift`, `Tests/AgentHarnessKitTests/Support/GatedCheckpointer.swift` (gating pattern).
- **Do:** create `Tests/AgentHarnessKitTests/Core/Streaming/AgentStreamCancelHistoryTests.swift` (guard with `#if canImport(Observation)`) covering cancel: mid-text; mid-tool-call (arguments still streaming → call dropped); during tool execution (use a tool that waits on a gate → synthetic cancelled result); after a full iteration plus partial second iteration. For each: `partialHistory` is non-nil, passes validation, and passing it as `history:` to a new `send` completes without `malformedHistory`.
- **Done when:** `swift test --filter AgentStreamCancelHistoryTests` green on macOS. Linux: suite is compiled out if `Observation` is missing; 1.6 covers Linux.

## 1.6 Linux-safe and MockServer coverage

- **Depends on:** 1.4. **Parallel-safe** with 1.5.
- **Read first:** `Tests/AgentHarnessKitALMTests/Support/MockServer.swift`, `AgentOverAdapterTests.swift`.
- **Do:**
  - Add a test that drives `Agent.stream` directly with a `PartialTurnRecorder` in `InvocationOptions`, cancels the consuming task, and checks `snapshot()`; this runs on Linux without `Observation`.
  - Add one MockServer test (`AgentOverAdapterTests.swift`) that cancels mid-stream after a `.stop` response and asserts no empty assistant message is in the snapshot.
- **Done when:** `swift test --filter "PartialTurnRecorder|AgentOverAdapterTests"` green; note in the report whether you ran on Linux.

## 1.7 Cancel while an approval is parked

- **Depends on:** 1.4 and 4.3 (queue exists).
- **Read first:** `Sources/AgentHarnessKit/Core/AgentLoop/ToolApproval.swift` (`awaitApprovalDecision` cancel path), `Tests/AgentHarnessKitTests/Core/AgentLoop/ChatApprovalTests.swift`.
- **Do:** add to `AgentStreamCancelHistoryTests.swift`: approval policy `.allTools` with `ToolApprovalQueue.handler`; wait for `.toolApprovalRequested`; call `cancel()`. Assert the parked call has the synthetic cancelled result in `partialHistory`, the queue's pending list is empty, and the next `send` with that history succeeds.
- **Done when:** that test green.

## 1.8 Docs and changelog

- **Depends on:** 1.5, 1.6, 1.7.
- **Do:** `CHANGELOG.md` Unreleased entry; `docs/ARCHITECTURE.md` section 3 notes that the `.stop` empty `.response` is also filtered from partial history.
- **Done when:** `swift test` green.

**Section exit:** tests green on macOS and Linux; the app deletes `StoppedTurnReply` (tracked in 5.6).
