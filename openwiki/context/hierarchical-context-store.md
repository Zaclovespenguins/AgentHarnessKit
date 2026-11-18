---
type: subsystem
title: Hierarchical Context Store
description: How the AgentHarnessKitContext module stores a session's messages, folds finished ranges into summary blocks through the compress, decompress, search_context and context_status tools, decides which messages are protected, nudges the model when the window fills, and persists state through the GRDB-backed or in-memory persistence stores.
tags: [context, compression, folding, grdb, persistence, tools, token-budget]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:32:44.730Z
sources:
  - id: openwiki-source-8d619ab6ba91bd1f164daf00
    resource: repo://Sources/AgentHarnessKitContext/CompressibleRange.swift
  - id: openwiki-source-45c269b4a3ccd7c1d9e49842
    resource: repo://Sources/AgentHarnessKitContext/ContextModel.swift
  - id: openwiki-source-6d5cb97c912391547acf1ead
    resource: repo://Sources/AgentHarnessKitContext/HierarchicalContextStore.swift
  - id: openwiki-source-7ac29602f928656be262a00a
    resource: repo://Sources/AgentHarnessKitContext/Pipeline/NudgeAndTruncate.swift
  - id: openwiki-source-cae9743acd35031a92188c7f
    resource: repo://Sources/AgentHarnessKitContext/Pipeline/ProtectedZones.swift
  - id: openwiki-source-7e4ec1e7081d77f6fc07a833
    resource: repo://Sources/AgentHarnessKitContext/Storage/ContextPersistenceStores.swift
  - id: openwiki-source-f92d9a6deaa3cb8c7696dcbf
    resource: repo://Tests/AgentHarnessKitContextTests/HierarchicalContextStoreTests.swift
  - id: openwiki-source-2ac0c5d75f56c2bf946b8414
    resource: repo://Tests/AgentHarnessKitContextTests/PersistenceTests.swift
generated: { by: "claude-code", at: "2026-11-18T22:32:44.730Z" }
---

# Hierarchical Context Store

`AgentHarnessKitContext` is a separate product that implements the `ContextStore` contract used by the agent loop. Its central type is `HierarchicalContextStore`, an actor (`Sources/AgentHarnessKitContext/HierarchicalContextStore.swift:22`). The store keeps an append-only log of every message in a session, assigns each one a stable `MessageRef` such as `m00001`, and lets the model replace finished ranges of that log with summary blocks. The original messages stay in storage, so a block can be restored or searched later.

## Responsibilities

- Hold per-session state: the message log, the block list, the next block ordinal, a state `version`, a nudge baseline, and the last input token count (`ContextSessionState`, `ContextModel.swift:168`).
- Render the context window for each model call. `render(sessionID:messages:windowSize:)` (`HierarchicalContextStore.swift:96`) builds the message list the model sees from the stored log, the blocks, and the configured doctrine.
- Accept new messages from the loop through `record(sessionID:messages:usage:)` (`HierarchicalContextStore.swift:136`).
- Execute the four reserved context tools through `executeTool(_:sessionID:)` (`HierarchicalContextStore.swift:167`).
- List the ranges an app can fold itself through `compressibleRanges(sessionID:)` (`HierarchicalContextStore.swift:208`).
- Delete a session's stored state through `deleteSession(_:)` (`HierarchicalContextStore.swift:226`).

The tool names are `compress`, `decompress`, `search_context`, and `context_status`. They are the same reserved names listed in [Agent loop](../architecture/agent-loop.md). The protected-zone logic below depends on that list.

## Message log and history checks

`render` treats the caller's `messages` array as the source of truth for the current turn, but it checks that the stored log is still a prefix of it. Any stored message that does not equal the same position in `messages` throws `ContextStoreError.historyDiverged(at:)` (`HierarchicalContextStore.swift:100-103`). A shorter history than the stored log also throws. When the history is consistent, new messages are appended with `ContextPipeline.assignRefs` and the blocks are synchronized with `syncBlocks` once per render.

`record` does the reverse. It finds the largest overlap between the stored tail and the incoming messages, then appends only the non-overlapping suffix (`HierarchicalContextStore.swift:136-148`). It also saves the reported input token count when `usage` is present.

A missing `windowSize` throws `AgentError.missingContextWindowSize` before any state is read.

## Rendering pipeline

`render` runs these steps in order:

1. Compute protected refs (see below).
2. Build render items from the stored log and blocks. Folded ranges are replaced by their block summary, and the compression tool calls are hidden.
3. Apply emergency truncation to fit `windowSize` (`NudgeAndTruncate.swift:49`).
4. Prepend the doctrine to the system message, or insert it as a new system message when the first rendered message is not a system message.
5. Sum the rendered tokens. If `shouldNudge` is true, append a nudge message listing the compressible ranges and set `nudgeBaseline` to the current usage.
6. Save state, remember the window size for `context_status`, and return the rendered messages.

The nudge rule (`NudgeAndTruncate.swift:7-19`) fires when used tokens reach `nudgeFloor * windowSize`, where the default `nudgeFloor` is 0.45 (`ContextModel.swift:134`). After the first nudge, another fires only when usage has grown by `nudgeGrowthTokens` since the baseline. A successful compress resets the baseline to nil (`HierarchicalContextStore.swift` compress path).

## Protected zones

`ContextPipeline.protectedRefs` (`Sources/AgentHarnessKitContext/Pipeline/ProtectedZones.swift:14`) returns the refs the model may not compress. The set is a union of:

- every system message;
- the first and the last user-role message;
- the recent zone, which is the last `k` messages, where `k` is the larger of `protectedRecentMessages` (default 3) and the smallest suffix whose token sum reaches `protectedRecentTokens` (default 5000). If the zone starts with tool messages, it extends backward to include the assistant message that issued those calls;
- every assistant message that calls a context tool, and every tool message produced by a context tool.

`compressibleRanges` (`ProtectedZones.swift:48`) then takes the maximal runs of refs that are neither protected nor inside an active block. It trims each run so it does not start with a tool message or end with an assistant message that has tool calls. Those trims keep tool-call pairs intact.

## Compress, decompress, and search

`compress` takes `{"ranges":[{"startRef","endRef","topic"?,"summary"}]}`. The pipeline's `applyCompress` (`Sources/AgentHarnessKitContext/Pipeline/Compression.swift:54`) validates each range against the protected set and the existing blocks, then creates blocks. Invalid ranges are reported as error lines. When at least one block is created, the store saves the new blocks, increments `version`, and emits a `contextFolded` event with the token savings. When no block is created, the result is `isError: true`.

`decompress` restores a block one tier down, or the full original messages when `full` is true. The `toFile` option writes the original messages to a plain file name inside `exportDirectory`. The store rejects names that contain `/`, `.`, `..`, or are empty. Export is disabled when `exportDirectory` is nil. A file export does not change blocks or `version`.

`search_context` runs `persistence.search`, one line per hit, with a default limit of 5. `context_status` reports used tokens, the window size from the last render, the token breakdown, active blocks, and compressible ranges.

### App-driven folds

`compressibleRanges(sessionID:)` (`HierarchicalContextStore.swift:208`) lets an app run "Compact now" itself. It loads the saved state and runs `protectedRefs` and `ContextPipeline.compressibleRanges` with the same inputs as the `compress` path, so a `compress` call made right after accepts every returned range. Each result is a `CompressibleRange` (`Sources/AgentHarnessKitContext/CompressibleRange.swift`) with `startRef`, inclusive `endRef`, the covered `messages`, and `tokens`, the sum of their stored token estimates. The call is read-only. It does not run `syncBlocks` or save, so block generations and `version` do not change. An unknown or empty session returns an empty array.

The app writes a summary for each range and sends a normal `compress` `ToolCall` to `executeTool`. The call id becomes the block's `createdByCallID`. An app-made id matches no call in history, so `hideCompressionCalls` has nothing to hide and the render matches a model-made fold. Rejections, such as a summary shorter than `minSummaryLength` or a range the model folded in the meantime, come back as error lines in the result.

Model mistakes come back as `isError: true` results rather than thrown errors. Bad JSON, rejected ranges, unknown block ids, export disabled, and unknown tool names are all handled this way (`HierarchicalContextStore.swift:167-190`).

## Persistence

`ContextPersistence` (`ContextModel.swift:216`) is the storage contract. It loads and saves a session's `ContextSessionState` and runs search over stored text. Two implementations exist:

- `InMemoryContextPersistence` (`Sources/AgentHarnessKitContext/Storage/ContextPersistenceStores.swift:38`) is an actor that keeps sessions in a dictionary. It is used for tests and for runs that do not need durable state.
- `GRDBContextPersistence` (`ContextPersistenceStores.swift:92`) is a `final class` backed by GRDB. The file-based initializer opens a `DatabasePool`, which uses WAL mode, at `directory/fileName` (default `context.sqlite`) and runs migrations. The directory must already exist, and the store does not derive paths from `TMPDIR` or the home directory. The in-memory initializer uses a `DatabaseQueue`.

`ContextPersistence` also requires `delete(sessionID:)` (`ContextModel.swift:230`), which removes a session's messages, blocks, block sources, search index rows and meta row. Deleting an unknown session does nothing. The in-memory store drops the dictionary entry (`ContextPersistenceStores.swift:84`). The GRDB store deletes from `block_source`, `block`, `message` and `session_meta` in one write transaction (`ContextPersistenceStores.swift:205`). The FTS5 tables are synchronized with their base tables, so their rows go too, and `PersistenceTests` checks this through search. `HierarchicalContextStore.deleteSession(_:)` calls it and forgets the session's cached window size. A deleted session id can be reused, starting again from `m00001`. Adding this requirement is a breaking change for outside conformers.

`stateVersion(sessionID:)` returns the saved `version` as text. Checkpoint resume compares this value against the checkpoint's `contextStateVersion` (see [Checkpointing](../architecture/checkpointing.md)).

## Configuration

`ContextConfiguration` (`ContextModel.swift:111`) carries the tunable values: `protectedRecentMessages` (3), `protectedRecentTokens` (5000), `nudgeFloor` (0.45), `nudgeGrowthTokens`, `promotionThreshold` (5), `minSummaryLength`, the doctrine text, and the nudge text. A block becomes old after it survives `promotionThreshold` syncs.

## Operational consequences

- The store decides what the model sees. A change to protected-zone thresholds or to the doctrine changes every later render, not only new messages.
- History divergence is an error. A caller that rewrites earlier messages gets `historyDiverged` and must start a new session or rebuild the log.
- Persistence is keyed by `SessionID`. Folded blocks are stored only in the persistence store, so the store's database file is the only copy of the block-to-message mapping.

## Tests

The module's tests live in `Tests/AgentHarnessKitContextTests/`. Test files exist for protected zones (`ProtectedZonesTests.swift`), compression (`CompressionTests.swift`), folding (`FoldingTests.swift`), nudge and truncation (`NudgeAndTruncateTests.swift`), persistence (`PersistenceTests.swift`), and the public store (`HierarchicalContextStoreTests.swift`). `ContextStoreAppAPITests` in that file covers `compressibleRanges` (round trip through `compress`, read-only, protected refs, app-made call ids) and `deleteSession`.

## Related pages

- [Agent loop](../architecture/agent-loop.md) calls `render` and `record` around each iteration and dispatches the context tools.
- [Build and CI](../operations/build-and-ci.md) describes how the context tests run in the standard test targets.
