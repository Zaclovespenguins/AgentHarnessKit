# AgentHarnessKit v0.2 Roadmap

Follows [ROADMAP.md](ROADMAP.md) (v0.1 parity phases). v0.2 moves four pieces of loop-level plumbing out of the consuming app and into the kit, because every consumer needs them and none of them is UI. Behavior stays governed by [AGENTHARNESSKIT_PARITY_SPEC.md](AGENTHARNESSKIT_PARITY_SPEC.md); anything below that changes spec behavior updates the spec in the same PR.

## Scope

| # | Item | Moves from app | Kit surface | Priority |
|---|------|----------------|-------------|----------|
| 1 | Partial history after Cancel | `StoppedTurnReply` | `AgentStream` | High |
| 2 | Terminal-answer handling | `TerminalAnswer.restore` | Agent loop | High |
| 3 | Generic history summarizer | `ManualCompactionService` | Optional target | Conditional |
| 4 | Queued approval handler | `ToolApprovalCoordinator` | `ToolApprovalHandler` impl | Medium |

Items 1, 2 and 4 are independent and can land in any order. Item 3 waits on a decision (see below).

## 1. Partial history after Cancel

**Problem:** the SDK only fills `stream.history` when a turn finishes. A consumer that offers Stop gets nothing for the interrupted turn, so every such consumer reimplements `StoppedTurnReply` to rebuild the partial reply.

- Expose the partial reply on `AgentStream` after cancel/stop: assistant text so far, tool calls issued, and tool results already received.
- Keep it consistent with the loop's malformed-history checks: no dangling tool call without a result (synthesize a "cancelled" result or drop the call; pick one and document it in the spec).
- Spike quirk to handle: `.stop` leaves an empty trailing `.response`. The partial reply must not include it.
- Works for plain cancel and for cancel while an approval is parked (item 4).

**Tests:** cancel mid-text, mid-tool-call, during tool execution, and during a parked approval; resulting history round-trips into the next `run` without a validation error. Mock-server (`MockServer` from `spike-final`) on macOS and Linux.

**Exit:** the app deletes `StoppedTurnReply` and reads the kit's partial reply.

## 2. Terminal-answer handling

**Problem:** the SDK drops a finish-only answer from history, so `TerminalAnswer.restore` re-adds it. That is loop behavior, not app behavior, and it ties into the kit's content-only termination rule.

- Loop re-adds the `finish` answer to history as an assistant message so the next turn sees it.
- Single-finish rule and reserved-name rules from the spec stay intact; restored content is not counted as a second finish.
- Checkpoint resume must not restore twice (idempotent on replay).
- Applies to streaming and non-streaming paths.

**Tests:** finish-only turn, finish plus content, resume from checkpoint after a finish-only turn, and the follow-up request body contains the answer exactly once.

**Exit:** the app deletes `TerminalAnswer.restore`.

## 3. Generic "summarize this history" helper (conditional)

**What exists:** `ManualCompactionService` builds the summary request, trims tool output and mirrors the bridge format.

**Decision gate (before any work):** is the app staying on Option A without `HierarchicalContextStore` for a while?

- **Yes:** move it into `AgentHarnessKitContext` as a standalone helper, `summarize(history:using:)`, over `ChatMessage` and `LLMClient`. Reuse the existing middle-out tool-result truncation instead of a second trimmer. Label it transitional in the docs.
- **No (Phase 4b ships first):** skip. The context store's `compress` tool covers it, and shipping this now means building something we delete.

If built: summary request is a normal `LLMClient` call (no new provider coupling), output is a `ChatMessage` the caller decides how to splice in, and the helper never mutates history itself.

**Tests (if built):** tool-output trimming, bridge format round trip, history under the model's window after summarizing.

**Exit:** decision recorded in `docs/ARCHITECTURE.md`; either the helper ships and the app deletes `ManualCompactionService`, or this item is closed as won't-do.

## 4. Queued approval handler

**Problem:** `ToolApprovalCoordinator` is a FIFO of parked continuations with deny-all on stop. Only its `@Observable` pending property is UI. The queue itself is generic.

- Kit ships the queue as a `ToolApprovalHandler` implementation: parked requests in FIFO order, `resolve(id, decision)`, and deny-all on stop/cancel so the loop never hangs on an abandoned continuation.
- Exposes a pending-requests stream (or snapshot plus change notification) rather than `@Observable`, so it builds on Linux. The app wraps it in its own `@Observable` for the UI.
- Honors `approveAlways` and the session allowlist from Phase 4; the queue never re-prompts for an allowlisted tool.
- Multiple parked requests resolve independently, in any order. The loop asks for approvals one at a time, so a single run parks at most one; several are parked when runs share a queue (parallel sub-agents, several streams). One decision resolves one request.

**Tests:** FIFO order, resolve out of order, deny-all on stop leaves no parked continuation, cancel while parked (ties to item 1), allowlist skip.

**Exit:** the app keeps only a thin `@Observable` wrapper; `ToolApprovalCoordinator` queue logic is deleted.

## Order and dependencies

```
1 ──┐
2 ──┼──► release v0.2
4 ──┘      (3 only if the gate says yes)
```

Suggested order: 2 (smallest, loop-only), 1, 4 (reuses the cancel path from 1), then 3 if applicable.

## Definition of done

- Each item has tests green on macOS and Linux; iOS Simulator builds and passes the mock-server tests.
- The consuming app has deleted the corresponding code (that is the proof the kit surface is sufficient).
- Spec and `docs/ARCHITECTURE.md` updated for any behavior change.
- Tagged `v0.2.0`.

## Not in v0.2

UI types (`@Observable` pending state, views), anything in the v0.1 Deferred list, and new provider options.
