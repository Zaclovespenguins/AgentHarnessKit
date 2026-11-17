# 4. Queued approval handler — sub-tasks

**Roadmap goal:** the kit ships the FIFO queue behind `ToolApprovalCoordinator` as a `ToolApprovalHandler` provider, Linux-safe, so the app keeps only a thin `@Observable` wrapper.

**What exists:**

- `ToolApprovalHandler` is a closure typealias: `@Sendable (ToolApprovalRequest) async -> ToolApprovalDecision` (`Sources/AgentHarnessKit/Core/AgentLoop/ToolApproval.swift:78`).
- `awaitApprovalDecision` cancels the handler's task when the loop is cancelled (`ToolApproval.swift:117`–`118`). The queue must react to that cancellation or it leaks a parked continuation.
- Allowlisted tools never reach the handler: `ToolApprovalPolicy.requiresApproval(toolName:allowlist:)` short-circuits first (`ToolApproval.swift:11`, called from `Agent+ToolResults.swift:63`). `approveAlways` inserts into the allowlist after the decision (`ToolApproval.swift:152`).
- **Approvals are sequential within one run.** `resolveApprovals` (`Agent+ToolExecution.swift:123`) awaits each request in turn and re-checks the allowlist before each one (line 138). So one run parks at most one request at a time. Several requests are parked together only when several runs share a queue: parallel sub-agents that receive the parent's handler, or several `Agent`/`AgentStream` runs given the same `queue.handler`. This is deliberate and stays as is for v0.2: do not change the loop to request approvals concurrently.

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

Backed by a private actor holding `[(request, CheckedContinuation<ToolApprovalDecision, Never>)]`. `resolve(id:)` matches `ToolApprovalRequest.toolCallId`; if more than one parked entry has that id (two runs sharing a queue can reuse an id), it resolves the oldest one. One decision resolves exactly one request: the queue never resolves other entries on behalf of a decision. No `Observation` import. File: `Sources/AgentHarnessKit/Core/AgentLoop/ToolApprovalQueue.swift`.

---

## 4.0 Spec text for the queue

- **Depends on:** nothing. **Parallel-safe** with 1.0 and 2.0.
- **Do:** in `AGENTHARNESSKIT_PARITY_SPEC.md` under the **Approval** bullet, add: the kit provides `ToolApprovalQueue`; FIFO order; independent resolution in any order; `denyAll` on stop/cancel; a cancelled parked request is removed and resolves as deny with reason `"Cancelled"`; one decision resolves exactly one request, and `approveAlways` is passed through to the loop, which adds the tool to that run's allowlist (the queue does not approve other parked requests for the same tool); the loop asks for approvals one at a time, so a single run has at most one parked request, and several are parked only when runs share a queue; `resolve` matches `toolCallId` and takes the oldest entry on a duplicate id.
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
  - Cancellation can arrive before the entry is enqueued (the loop cancels the handler's task, and `onCancel` runs synchronously, possibly before the actor has stored the continuation). Handle it: give each call a unique token, and have the actor remember tokens cancelled before enqueue so the later enqueue resumes immediately with `.deny(reason: "Cancelled")` instead of parking. Also check `Task.isCancelled` at the start of `handler`.
  - `resolve(id:decision:)` resumes and removes the oldest entry whose `toolCallId == id`, publishes, returns `true`; unknown id returns `false`. Pass the decision through unchanged, including `.approveAlways`; do not touch other entries.
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
  - two runs sharing one queue, each parked on tool `A` → `approveAlways` on one resolves only that one; the other stays in `pending()` until resolved itself.
- **Done when:** tests green.

## 4.6 Concurrent requests resolve independently

- **Depends on:** 4.3. **Parallel-safe** with 4.4 and 4.5.
- **Read first:** `Tests/AgentHarnessKitTests/Core/AgentLoop/ConcurrencySafeSchedulingTests.swift`, the sub-agent overlap tests (grep `explicitSafeSiblingSubAgentsCanOverlap`), `Sources/AgentHarnessKit/Tools/SubAgentTool.swift` (how the approval handler reaches the child).
- **Do:**
  - Queue level: three handler calls started concurrently in separate tasks, for three different tools; wait until `pending()` holds all three; resolve them in order 3, 1, 2 with different decisions (approve, deny, approveWithModifiedArguments). Assert each awaiting call returns its own decision and `pending()` keeps FIFO order after each resolve.
  - Loop level: two sub-agents that run in parallel, each calling a tool that needs approval, with the parent's `queue.handler`. Wait until both are parked; resolve the second first. Assert each child's tool result matches its decision. If sub-agents do not receive the parent's handler, or cannot run in parallel, skip this part and report it.
  - Do not assert concurrent parking within a single run: the loop asks for approvals one at a time by design.
- **Done when:** tests green.

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
