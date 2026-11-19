# Handoff: context store API additions in AgentHarnessKit

Date: 2026-11-18. Kit repo: `Zaclovespenguins/AgentHarnessKit`, `main` @ `64f7bfc`. The work happens in the **kit** repo. This file lives in agentz because agentz is the consumer.

## Why

agentz is replacing AgentRunKit with AgentHarnessKit and adopting `HierarchicalContextStore`. See `ROADMAP-HARNESSKIT.md` (findings 13 and 14). Two app features need store API that doesn't exist yet:

1. **App-driven "Compact now".** The app asks the store which ranges can be folded, writes a summary for each with its own model call, and sends them back as a `compress` call through `executeTool`.
2. **Deleting a chat deletes its context data.** Today `ContextPersistence` has no delete, so a deleted chat's messages stay in `context.sqlite`.

agentz pins the kit to `branch: "main"`, so both changes ship when merged to `main`.

## Source of truth

- `Sources/AgentHarnessKitContext/HierarchicalContextStore.swift`: the store actor (`render`, `record`, `executeTool`, `runCompress`).
- `Sources/AgentHarnessKitContext/Pipeline/ProtectedZones.swift`: `ContextPipeline.protectedRefs` and `compressibleRanges`. Both are already public.
- `Sources/AgentHarnessKitContext/Pipeline/Compression.swift`: `applyCompress`, which validates ranges and the summary length.
- `Sources/AgentHarnessKitContext/ContextModel.swift`: `ContextPersistence`, `ContextSessionState`, `MessageRef`, `ContextBlock`, `ContextConfiguration`.
- `Sources/AgentHarnessKitContext/Storage/ContextPersistenceStores.swift`: `InMemoryContextPersistence` and `GRDBContextPersistence`. The latter has the tables `message`, `message_fts`, `block`, `block_fts`, `block_source` and `session_meta`.
- `Tests/AgentHarnessKitContextTests/`: `HierarchicalContextStoreTests.swift` and `PersistenceTests.swift`.

## Change 1: `compressibleRanges(sessionID:)` on the store

### API

```swift
/// A run of stored messages that a `compress` call for this session would accept today.
public struct CompressibleRange: Sendable, Equatable {
    public let startRef: MessageRef
    public let endRef: MessageRef   // inclusive
    /// The covered messages, in ref order.
    public let messages: [ChatMessage]
    /// `ContextTokens` estimate for `messages`.
    public let tokens: Int
}

public extension HierarchicalContextStore {
    /// Ranges the app can fold now, ascending. Read-only: it changes no state and no version.
    func compressibleRanges(sessionID: SessionID) async throws -> [CompressibleRange]
}
```

Put `CompressibleRange` in its own file. Its name doesn't clash with anything in agentz. Don't name it `StoredRange` or anything starting with `Stored`, because agentz has a SwiftData type named `StoredMessage`.

### Behavior

- Load the state from `persistence`. Compute `ContextPipeline.protectedRefs(state.messages, configuration: configuration)`, then `ContextPipeline.compressibleRanges(state.messages, blocks: state.blocks, protected:)`. Use exactly the same inputs as `runCompress`, so every returned range is accepted by a `compress` call made right after.
- **No `syncBlocks`, no save.** `syncBlocks` advances block promotion, which is `render`'s job. A read must not change the block generation or the `version` that checkpoints compare.
- An unknown or empty session returns `[]`.

### Why there's no `messages:` parameter

The roadmap first proposed `compressibleRanges(sessionID:messages:)`, which would record messages before computing ranges. Leave it out:

- Refs are positions in the loop's history, and that history starts with the system message. agentz removes the system message from what it saves. An app-supplied `messages` array would be offset by one and throw `historyDiverged` on the next `render`.
- `record` aligns by suffix overlap, not by position, so it can't catch that offset.
- The loop already records after every iteration, so after any finished turn the store is current. A chat reopened with no turn since the swap has nothing stored, and the app shows "Nothing to fold yet". That is acceptable.

### Contract for the app's `compress` call

Document this in the doc comment, because agentz depends on it:

- Send `ToolCall(id: <unique>, name: ContextToolName.compress, arguments: {"ranges":[{"startRef","endRef","topic"?,"summary"}]})` to `executeTool(_:sessionID:)`.
- The id becomes `ContextBlock.createdByCallID`. An app-made id (for example `app-fold-<UUID>`) matches no call in history, so `hideCompressionCalls` has nothing to hide. Confirm that this is harmless, and pin it with a test.
- A summary shorter than `configuration.minSummaryLength` is rejected in the result's error lines. Other rejections come back the same way, never as a thrown error.
- If a turn runs between `compressibleRanges` and `compress`, refs stay valid, because history is append-only. A range the model folded in the meantime comes back as an error line.

### Tests (`HierarchicalContextStoreTests`)

- An empty session returns `[]`.
- The output matches `ContextPipeline.compressibleRanges` run over the same state, including `messages` and `tokens`.
- **Round trip:** for a scripted session (system, several user/assistant/tool turns, then a recent zone), send every returned range to `compress` with a valid summary. Every range creates a block, and the result has no error lines.
- **Read-only:** the state is unchanged after the call, including `version` and each block's `survivedCount`.
- After a fold, the folded refs are no longer returned.
- Protected refs are never returned: the system message, the first and last user messages, the recent zone, and context-tool calls.
- An app-made `createdByCallID` doesn't break the next `render`. Its output is the same as for a model-made fold, apart from the hidden call.

## Change 2: delete a session

### API

```swift
public protocol ContextPersistence: Sendable {
    // existing load / save / search
    /// Removes every message, block, block source, search index row and the meta row for `sessionID`.
    /// Deleting an unknown session succeeds and does nothing.
    func delete(sessionID: SessionID) async throws
}

public extension HierarchicalContextStore {
    /// Deletes the session's persisted state and forgets its cached window size.
    func deleteSession(_ sessionID: SessionID) async throws
}
```

agentz holds the store, not the persistence object, so it needs the store-level method. It also clears `windowSizes[sessionID]`.

### Implementations

- `InMemoryContextPersistence`: `sessions[sessionID] = nil`.
- `GRDBContextPersistence`: one `write` transaction that deletes `WHERE sessionID = ?` from `block_source`, `block`, `message` and `session_meta`. `message_fts` and `block_fts` are synchronized tables, so their triggers should remove the matching rows. Prove it with a search test; don't assume.

### Breaking change

Adding a protocol requirement breaks any outside `ContextPersistence` conformer. The kit is pre-release. Mark it **Breaking** in the changelog rather than adding a default implementation that silently does nothing.

### Tests (`PersistenceTests`, run against both stores)

- After saving two sessions and deleting one: `load` of the deleted session returns an empty `ContextSessionState()`, and `search` for its words returns no hits. The other session is unchanged and still searchable.
- Deleting an unknown session doesn't throw.
- A deleted session can be reused: saving to the same id starts from ref 1 again.
- The store-level test: `deleteSession` followed by `render` of a fresh history works, with no `historyDiverged`.

## Out of scope

- No typed `compress(sessionID:ranges:)` wrapper. `executeTool` is enough for one caller.
- No change to `record` or `render` alignment.
- Optional, if you are already in the file: remove the stale `// TASK H8. Stubs; replace the bodies...` header in `HierarchicalContextStore.swift`. The bodies are implemented.

## Done when

- Both changes are merged to the kit's `main`.
- `make check-local` passes: SwiftFormat, SwiftLint and the tests. The kit builds with `-warnings-as-errors`.
- `CHANGELOG.md` has `[Unreleased]` entries: Added (`compressibleRanges`, `CompressibleRange`, `deleteSession`) and **Breaking** (`ContextPersistence.delete`).
- The doc comments state the compress contract above.
- OpenWiki pages are refreshed through the repo's own process, not edited by hand.
- Report the merge commit hash back, so agentz can update `Package.resolved`.
