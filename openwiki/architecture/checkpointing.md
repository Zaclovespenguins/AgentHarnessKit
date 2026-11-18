---
type: architecture
title: Checkpointing and Resume
description: How the agent loop persists per-iteration AgentCheckpoint snapshots through an AgentCheckpointer, and how Agent.resume validates and replays a checkpoint before continuing the loop live.
tags: [checkpointing, resume, agent-loop, persistence, swift]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-a863199a4a97b4179ed36360
    resource: repo://Sources/AgentHarnessKit/Core/Checkpointing/Agent%2BCheckpointing.swift
  - id: openwiki-source-2f4d92fbd4a19e1cf0ad0883
    resource: repo://Sources/AgentHarnessKit/Core/Checkpointing/Agent%2BResume.swift
  - id: openwiki-source-562b1e119c9aa22e15ff68ec
    resource: repo://Sources/AgentHarnessKit/Core/Checkpointing/FileCheckpointer.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Checkpointing and Resume

Checkpointing lets a run be stopped in one process and continued in another. The agent loop saves an `AgentCheckpoint` after each iteration through an `AgentCheckpointer`. `Agent.resume` loads a checkpoint, validates it against the live agent, replays the checkpointed iteration to the caller, and then continues the loop from the next iteration.

## Components

- **`AgentCheckpoint`** (`Sources/AgentHarnessKit/Core/Checkpointing/AgentCheckpoint.swift`) is a `Sendable, Codable, Identifiable` snapshot. Its `id` is `checkpointID`. It stores the message history, iteration number, cumulative `tokenUsage`, the last `iterationUsage`, the `sessionAllowlist` of approved tool names, the `sessionID`, `runID`, `timestamp`, the `mcpToolBindings` in use, an optional `terminalOutcome`, and an optional `contextStateVersion`.
- **`MCPToolBinding`** (same file) is a `Codable, Hashable` pair of `serverName` and `toolName`. Tools that conform to `MCPBindingProviding` expose one. Checkpoints record which MCP tools the history used, so resume can detect a missing server.
- **`AgentCheckpointer`** (`AgentCheckpointer.swift`) is the storage protocol: `save`, `load(_:)`, and `list(session:)`.
- **`InMemoryCheckpointer`** (`InMemoryCheckpointer.swift`) is an actor that keeps checkpoints in a dictionary. It is process-local and has no durability.
- **`FileCheckpointer`** (`FileCheckpointer.swift`) is an actor that writes one JSON file per checkpoint under `<directory>/checkpoints/<checkpointID>.json`. It is the mechanism that supports cross-process resume.
- **`AgentCheckpointError`** (`AgentCheckpoint.swift`) has five cases: `notFound`, `fileSystem`, `mcpBindingMismatch`, `completionToolMismatch`, and `contextStateMismatch`.

## Writing checkpoints

`Agent.checkpointIfConfigured` (`Agent+Checkpointing.swift`) is the write path. It returns `nil` without saving when no checkpointer is configured, or when the event factory lacks a session or run ID. Otherwise it reads the context store's `stateVersion` for the session, derives `mcpToolBindings` from the assistant tool calls and tool-result names in the history, and saves one checkpoint. The checkpoint captures the state after the iteration, so a later resume starts from `iteration + 1`.

Two details matter for correctness:

- The checkpoint is stored with the context store's state version at save time. Resume compares it with the live store and fails on a mismatch, which prevents replaying history into a context that has changed.
- Terminal iterations can store a `terminalOutcome`. Resume then replays that outcome instead of calling the model again.

## Resuming a run

`Agent.resume(from:checkpointer:context:...)` (`Agent+Resume.swift:5-19`) loads the checkpoint by ID and calls an internal overload. The internal overload performs checks in a fixed order:

1. If `contextStateVersion` is set, it reads the live `stateVersion` and throws `contextStateMismatch` when the two differ (`Agent+Resume.swift:36-41`).
2. It validates the checkpointed messages with `validateForAgentHistory()` (`Agent+Resume.swift:42`).
3. If a `terminalOutcome` exists, it validates the completion identity with `completionPolicy.validateIdentity(of:)` and returns `replayTerminalOutcome` without running the loop (`Agent+Resume.swift:43-48`).
4. It validates the invocation options, then checks `mcpToolBindings` against the live tools. A missing binding throws `mcpBindingMismatch` with the missing bindings sorted by server and tool name (`Agent+Resume.swift:98-107`).
5. It returns a stream whose task runs `replayAndContinueResume`.

`replayAndContinueResume` (`Agent+Resume.swift:109-131`) first yields a replayed `iterationCompleted` event with `origin: .replayed(from:)`. It then rebuilds `AgentLoopState` from the checkpoint messages and allowlist. If `earlyFinishEvent` returns an event, the stream ends there. Otherwise the loop resumes at `target.iteration + 1`.

`earlyFinishEvent` (`Agent+Resume.swift:133-149`) ends the resumed run without a model call in two cases. The first is when the checkpoint's cumulative tokens already exceed the new `tokenBudget`, which finishes with `.tokenBudgetExceeded`. The second is when `target.iteration >= configuration.maxIterations`, which finishes with `.maxIterationsReached`. The iteration limit is described in [Agent loop](agent-loop.md).

## Storage behavior

- `FileCheckpointer.save` creates the base directory when needed and writes the JSON with `.atomic` (`FileCheckpointer.swift:20-29`). It encodes dates as ISO 8601 with sorted keys and pretty printing.
- `FileCheckpointer.load` returns `notFound` when the file is absent. Decode failures are wrapped as `fileSystem`.
- `FileCheckpointer.list(session:)` decodes every `.json` file in the directory and skips files that fail to decode. It keeps checkpoints whose `sessionID` matches, then sorts by `iteration` and then by `timestamp` (`FileCheckpointer.swift:44-67`).
- `InMemoryCheckpointer` uses the same ordering for `list(session:)` (`InMemoryCheckpointer.swift:20-28`).

## Failure behavior and limits

- A checkpoint whose context version changed is rejected, not repaired. The caller must restart the run or provide a matching context.
- A checkpoint that references an MCP tool that is not registered in the resuming agent is rejected before any replay.
- `FileCheckpointer.list` silently skips corrupt files. A corrupt checkpoint therefore appears as missing rather than as an error.
- The file checkpointer writes one file per iteration and never prunes old files in the code surveyed here.

## Cross-process verification

`Tests/CheckpointResumeProbe/main.swift` is a child-process probe. It runs one streamed iteration with a `FileCheckpointer`, where the `echo` tool is approved with `approveAlways`. It exits when the second model request starts, after the loop has saved the iteration checkpoint. It prints the checkpoint ID to stdout. The usage is `CheckpointResumeProbe <directory> <sessionUUID>`. The probe's header comment says it exists for `CrossProcessResumeTests`; that test file was not inspected for this page.

## Related pages

- [Agent loop](agent-loop.md) describes the iteration, completion, and termination rules that create the checkpoints.
- [Streaming](streaming.md) describes the stream events that replayed checkpoints emit.
