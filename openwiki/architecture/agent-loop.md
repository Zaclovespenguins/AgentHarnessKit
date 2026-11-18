---
type: architecture
title: Agent Loop
description: How the Agent run loop iterates model calls, classifies completion (plain-text answers by default, an opt-in built-in finish tool, or a custom completion tool), executes tools in approval-gated concurrency waves, and terminates with an AgentResult.
tags: [agent, loop, tools, approval, completion]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:07:55.531Z
sources:
  - id: openwiki-source-26d1376d6a0db56292077f3f
    resource: repo://Sources/AgentHarnessKit/Core/AgentLoop/Agent.swift
  - id: openwiki-source-3b578330c6a32a7dca2e0122
    resource: repo://Sources/AgentHarnessKit/Core/AgentLoop/Agent%2BRun.swift
  - id: openwiki-source-af8e64e1ed1f751877987924
    resource: repo://Sources/AgentHarnessKit/Core/AgentLoop/Agent%2BToolExecution.swift
  - id: openwiki-source-a70d5c9fea93cb35fa769c6a
    resource: repo://Sources/AgentHarnessKit/Core/AgentLoop/AgentCompletionPolicy.swift
  - id: openwiki-source-6ea3ae96710e960b9f9810aa
    resource: repo://Sources/AgentHarnessKit/Core/AgentLoop/AgentConfiguration.swift
generated: { by: "claude-code", at: "2026-11-18T22:07:55.531Z" }
---

# Agent Loop

`Agent<C: ToolContext>` in `Sources/AgentHarnessKit/Core/AgentLoop/Agent.swift` is a `final class` that repeats a generate, tool-call, repeat cycle. It talks to a model only through the `LLMClient` seam.

## Construction and reserved names

- The convenience initializer takes an `LLMClient`. By default the agent finishes when the model replies with plain text and no tool calls; it finishes through the built-in `finish` tool only when `AgentConfiguration.offersFinishTool` is `true` (default `false`). A second initializer takes a `ToolCallSurfacingClient` plus an explicit `completionTool`.
- The private designated initializer appends the completion tool, then enforces preconditions: tool names are non-empty and unique, and none collide with `finish`, `compress`, `decompress`, `search_context`, `context_status`.
- Context-store tool names from `configuration.contextStore` must be a subset of `compress`, `decompress`, `search_context`, `context_status`.
- The built-in finish definition is advertised to the model only when no custom completion tool is supplied and `configuration.offersFinishTool` is `true` (`Agent.swift:62-65`). Both of those agents use the `builtInFinish` completion policy; `offersFinishTool` changes only what the model is offered.
- The default is off because tool-call arguments are not streamed: a final answer passed through `finish` reaches `stream(...)` consumers only in the `.finished` event, while a plain-text answer streams as `.delta` events.

## Run loop

`run(...)` builds `AgentLoopState` from the system prompt, history, and user message, validates it with `validateForAgentHistory()`, then loops `for iteration in 1 ... configuration.maxIterations`. `maxIterations` defaults to 10 and must be at least 1. Each iteration:

1. Checks cancellation with `Task.checkCancellation()`.
2. `executeRunIteration` renders messages, calls `client.generate(messages:tools:responseFormat:requestContext:)`, records token usage, and appends the assistant message.
3. `resolveRunIteration` classifies the tool calls through `completionPolicy.classify`.
4. `recordNewMessages` sends only the not-yet-recorded tail of history to `contextStore.record` when a context store is configured.

If no terminal result is produced, the loop continues. Exhausting the loop returns `reason: .maxIterationsReached(limit:)`.

## Completion classification

`AgentCompletionPolicy` has two cases, `builtInFinish` and `executableTool(name:)`. `classify` returns `none`, `builtInFinish`, `executableCompletion`, or `exclusivityViolation`:

- The reserved finish call must be the only call in its assistant message. Mixing it with other calls throws `AgentError.malformedHistory(.finishMustBeExclusive)`.
- With a custom completion tool, that tool must be the only call. Otherwise the result is `exclusivityViolation`, and feedback goes back to the model instead of ending the run.
- Content-only termination (no tool calls, non-empty content) is allowed only under `builtInFinish`, and it is the default way a run ends. Custom completion policies never end on content alone.
- A reserved `finish` call is classified as `builtInFinish` by name even when the tool was not offered, so histories and checkpoints recorded with the finish tool keep resolving.

## Tool execution

`Agent+ToolExecution.swift` handles approvals, then execution:

- `resolveApprovals` asks the `ToolApprovalHandler` one call at a time. Calls whose tool is in the run's allowlist skip the prompt. Denied calls become `IndexedToolResult` values with the denial result.
- `executionWaves` groups consecutive calls whose tools report `isConcurrencySafe` into one concurrent wave. Every other call forms its own serial wave, so a non-safe tool splits a batch. Waves run in order.
- The parallel path constructs a `ToolCallRunner` with `configuration.toolTimeout` and `subAgentDispatch: .blocking`.
- Results are truncated by `ToolResultTruncation.truncateToolResult` when `maxToolResultCharacters` is set (`ToolExecutionHelpers.swift`).

## Termination

Terminal results are `AgentResult` values with `finishReason`, `content`, `totalTokenUsage`, `iterations`, and `history`. `parseFinishResult` reads built-in finish arguments. The custom completion path appends a `.tool` message and validates history before returning.

## Failure behavior

- Cancellation is checked at the top of every iteration and throws rather than returning a result.
- Malformed history throws `AgentError`. Exclusivity violations are returned to the model as feedback so it can correct the call.
- Per `ToolApprovalQueue` documentation, cancelling an awaiting task resolves its parked request as denied with reason `"Cancelled"`.

## Related

- [Streaming Pipeline](streaming.md) mirrors this loop for `stream(...)`.
- [Checkpointing and Resume](checkpointing.md) persists state.
- [Tools and Schema](tools-and-schema.md) defines the tool protocol.
