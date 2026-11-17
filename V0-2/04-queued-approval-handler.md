# 4. Queued approval handler — sub-tasks

**Roadmap goal:** the kit ships the FIFO queue behind `ToolApprovalCoordinator` as a `ToolApprovalHandler` provider, Linux-safe, so the app keeps only a thin `@Observable` wrapper.

**What exists:**

- `ToolApprovalHandler` is a closure typealias: `@Sendable (ToolApprovalRequest) async -> ToolApprovalDecision` (`Sources/AgentHarnessKit/Core/AgentLoop/ToolApproval.swift:80`).
- `awaitApprovalDecision` cancels the handler's task when the loop is cancelled (`ToolApproval.swift:105`). The queue must react to that cancellation or it leaks a parked continuation.
- Allowlisted tools never reach the handler: `ToolApprovalPolicy.requiresApproval(toolName:allowlist:)` short-circuits first (`ToolApproval.swift:11`, called from `Agent+ToolResults.swift:63`). `approveAlways` inserts into the allowlist after the decision (`ToolApproval.swift:150`).

**Fixed design:**

```swift
public final class ToolApprovalQueue: Sendable {
    public init()
    public var handler: ToolApprovalHandler { get }           // pass to Agent/Chat/AgentStream
    public func resolve(id: String, decision: ToolApprovalDecision) async -> Bool  // false if unknown id
    public func denyAll(reason: String?) async                 // stop/cancel: resumes every parked request with .deny
    public func pending() async -> [ToolApprovalRequest]       // FIFO snapshot
    public var updates: AsyncStream<[ToolApprovalRequest]> { get }  // emits the FIFO snapshot after every change
}
```

Backed by a private actor holding `[(request, CheckedContinuation<ToolApprovalDecision, Never>)]`. No `Observation` import. File: `Sources/AgentHarnessKit/Core/AgentLoop/ToolApprovalQueue.swift`.

---

## 4.0 Spec text for the queue

- **Depends on:** nothing. **Parallel-safe** with 1.0 and 2.0.
- **Do:** in `AGENTHARNESSKIT_PARITY_SPEC.md` under the **Approval** bullet, add: the kit provides `ToolApprovalQueue`; FIFO order; independent resolution in any order; `denyAll` on stop/cancel; a cancelled parked request is removed and resolves as deny with reason `"Cancelled"`; `approveAlways` on one request also approves any other parked request for the same tool name in that queue (decision — flag in your report if you think it is wrong).
- **Done when:** spec diff only.

## 4.1 Queue actor and public type skeleton

- **Depends on:** 4.0.
- **Read first:** `ToolApproval.swift`.
- **Do:** create `ToolApprovalQueue.swift` with the API above. Implement `pending()`, `updates` (one `AsyncStream` per call, each subscriber gets the current snapshot first), and the internal enqueue that parks a continuation and publishes the new snapshot.
- **Done when:** `swift build` passes.

## 4.2 `handler`, `resolve`, `denyAll`

- **Depends on:** 4.1.
- **Do:**
  - `handler` enqueues and awaits; wrap the wait in `withTaskCancellationHandler` so cancellation removes the entry and resumes it with `.deny(reason: "Cancelled")`.
  - `resolve(id:decision:)` resumes and removes that entry, publishes, returns `true`; unknown id returns `false`. If `decision == .approveAlways`, also resolve every other parked entry with the same `toolName` as `.approve` (per 4.0).
  - `denyAll(reason:)` resumes every entry with `.deny(reason:)` in FIFO order, empties the queue, publishes once.
  - Every continuation is resumed exactly once on every path.
- **Done when:** `swift build` passes.

## 4.3 Unit tests: order, out-of-order resolve, denyAll

- **Depends on:** 4.2.
- **Read first:** `Tests/AgentHarnessKitTests/Support/ToolApprovalTestHelpers.swift`.
- **Do:** create `Tests/AgentHarnessKitTests/Core/AgentLoop/ToolApprovalQueueTests.swift`:
  - three handler calls → `pending()` lists them in call order;
  - resolve the middle one first → it returns that decision; the other two are still pending in order;
  - `denyAll` → all awaiting handlers return `.deny`, `pending()` is empty;
  - `resolve` of an unknown id returns `false`;
  - `updates` emits a snapshot after enqueue, resolve and denyAll.
- **Done when:** `swift test --filter ToolApprovalQueueTests` green.

## 4.4 Cancellation leaves nothing parked

- **Depends on:** 4.3. **Parallel-safe** with 4.5 and 4.6.
- **Do:** in `ToolApprovalQueueTests.swift`: start a handler call in a `Task`, cancel the task, assert it returns `.deny(reason: "Cancelled")` and `pending()` is empty. Then the same through the loop: `Agent.stream` with `.allTools` and `queue.handler`, cancel the consumer after `.toolApprovalRequested`, assert `pending()` becomes empty (poll with a short timeout, no sleeps longer than needed).
- **Done when:** tests green, repeated 20 times with `swift test --filter ToolApprovalQueueTests --repeat 20` (or a loop if `--repeat` is unsupported) with no flakes.

## 4.5 Allowlist and `approveAlways`

- **Depends on:** 4.3. **Parallel-safe** with 4.4 and 4.6.
- **Read first:** `Tests/AgentHarnessKitTests/Core/AgentLoop/ToolApprovalTests.swift`, `ChatApprovalTests.swift`.
- **Do:** loop-level tests with `TestLLMClient`:
  - after `approveAlways` for tool `A`, a later call to `A` in the same run never enters the queue (`updates` never shows it);
  - resuming from a checkpoint whose allowlist contains `A` → `A` never enters the queue;
  - two parallel `A` calls parked → `approveAlways` on one approves both.
- **Done when:** tests green.

## 4.6 Concurrent tool calls resolve independently

- **Depends on:** 4.3. **Parallel-safe** with 4.4 and 4.5.
- **Read first:** `Tests/AgentHarnessKitTests/Core/AgentLoop/ConcurrencySafeSchedulingTests.swift`.
- **Do:** one model response with three parallel calls to three tools needing approval; resolve them in order 3, 1, 2 with different decisions (approve, deny, approveWithModifiedArguments). Assert each tool result matches its decision and the history order matches the call order.
- **Done when:** test green.

## 4.7 `AgentStream` and `Chat` convenience

- **Depends on:** 4.4.
- **Read first:** `AgentStream.swift`, `Chat.swift`, how `approvalHandler` is passed today.
- **Do:** no new API on `AgentStream` beyond what already accepts an `approvalHandler`. Add a doc comment example on `ToolApprovalQueue` showing: create queue, pass `queue.handler`, call `await queue.denyAll(reason: nil)` from the app's Stop button before `stream.cancel()`. Add a short DocC-style paragraph to `README.md` "Approval" section if one exists.
- **Done when:** `swift build` passes; docs diff reviewed.

## 4.8 Changelog

- **Depends on:** 4.4 – 4.7.
- **Do:** `CHANGELOG.md` Unreleased entry for `ToolApprovalQueue`.
- **Done when:** `swift test` green.

**Section exit:** tests green on macOS and Linux; the app keeps only an `@Observable` wrapper over `queue.updates` and deletes the `ToolApprovalCoordinator` queue logic (tracked in 5.6).
