---
type: architecture
title: Streaming Pipeline
description: How the agent loop emits StreamEvent values, how StreamProcessor and ToolCallAccumulator assemble model deltas into assistant messages and tool calls, how AgentStream keeps observable state and a bounded replay buffer, and how events are encoded as JSON.
tags: [streaming, stream-events, replay, tool-calls, observable-state, swift]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:07:55.531Z
sources:
  - id: openwiki-source-8f16d723bc0ce721d7997c9b
    resource: repo://Sources/AgentHarnessKit/Core/Streaming/AgentStream.swift
  - id: openwiki-source-b4e6939a318f72038236fc0d
    resource: repo://Sources/AgentHarnessKit/Core/Streaming/EventOrigin.swift
  - id: openwiki-source-b4ea88b95665f045887dbadd
    resource: repo://Sources/AgentHarnessKit/Core/Streaming/StreamEventBuffer.swift
  - id: openwiki-source-ca1971ac77475b3f4b6eb0d9
    resource: repo://Sources/AgentHarnessKit/Core/Streaming/StreamEventJSONCodec.swift
  - id: openwiki-source-ae022ffacc812e1de156889a
    resource: repo://Sources/AgentHarnessKit/Core/Streaming/StreamProcessor.swift
  - id: openwiki-source-8d9af8b38f14fce98e79c339
    resource: repo://Tests/AgentHarnessKitALMTests/AgentOverAdapterTests.swift
generated: { by: "claude-code", at: "2026-11-18T22:07:55.531Z" }
---

# Streaming Pipeline

Every agent run produces a stream of `StreamEvent` values. The stream is the only channel through which the loop reports progress, tool activity, approvals, checkpoints, and completion. `AgentStream` is the main consumer: it turns events into observable state for UI code and optionally keeps them in a bounded buffer that can be replayed by cursor.

## Event envelope

`StreamEvent` (`Sources/AgentHarnessKit/Core/Streaming/StreamEvent.swift`) is a `Sendable, Identifiable` struct. Each event carries an `EventID`, a `timestamp`, optional `sessionID` and `runID`, an `origin`, and a `kind` payload. The `origin` defaults to `.live` (`StreamEvent.swift` initializer). `EventOrigin` (`EventOrigin.swift:4-6`) has two cases: `live`, and `replayed(from: CheckpointID)`. A replayed event tells the consumer which checkpoint it was reconstructed from. Checkpoint replay is described in [Checkpointing and resume](checkpointing.md).

Events are created through `StreamEventFactory`, which stamps the session and run IDs and the origin. Sub-agent events are nested inside a `subAgentEvent` wrapper. `HistoryEmissionLimit.swift` rewrites the history payload of nested `iterationCompleted` events when the depth exceeds a configured limit, so deep sub-agent trees do not repeat full transcripts at every level.

## Assembling deltas

Model backends emit `StreamDelta` values (`Sources/AgentHarnessKit/LLM/StreamDelta.swift:4-17`). The cases include `content`, `reasoning`, `toolCallStart(index:id:name:kind:)`, `toolCallDelta(index:arguments:)`, `finished(usage:)`, and `streamClosed(terminalMarkerSeen:)`. `StreamDelta.finished` replaces any earlier usage measurement, including with `nil`.

`StreamProcessor.swift` holds the per-iteration accumulator. It applies deltas into a `StreamIteration`, which holds content, tool calls, reasoning, usage, and continuity. `StreamIteration.toAssistantMessage()` converts that into the `AssistantMessage` appended to history. Tool-call fragments are merged by `ToolCallAccumulator` (`ToolCallAccumulator.swift:3-15`), which builds a complete `ToolCall` from the start and argument deltas for each index.

The stream policy decides when an iteration ends (`StreamProcessor.swift:3-44`). `StreamPolicy.agent(_:)` maps each `AgentCompletionPolicy` to a terminal tool name:

- Under `.builtInFinish`, the terminal tool is the reserved `finish` tool and its start event is suppressed (`emitToolStartForTerminalTool: false`).
- Under `.executableTool(name:)`, the named tool is terminal and its start event is emitted.

`shouldTerminateAfterIteration(toolCalls:)` returns true when the terminal tool appears in the batch. The chat policy, `StreamPolicy.chat`, also terminates when an iteration has no tool calls. The completion rules are described in [Agent loop](agent-loop.md).

Only `content` deltas become `.delta` events. Tool-call arguments are accumulated, never surfaced as events, so how the agent ends decides how its final answer streams. A default agent ends on a plain-text reply with no tool calls, and that answer arrives as `.delta` events followed by `.finished` with the same text. An agent with `AgentConfiguration(offersFinishTool: true)` can end through `finish`, and that answer arrives only in the `.finished` event's `content`.

## Observable state in AgentStream

`AgentStream<C>` (`AgentStream.swift:25-41`) is a public `final class` that exposes read-only properties, each with a `private(set)` setter. They include `content`, `reasoning`, `isStreaming`, `error`, `tokenUsage`, `finishReason`, `history`, `toolCalls`, `iterationUsages`, `contextStatus`, `sessionID`, `iterationsReplayed`, `currentCheckpoint`, and `partialHistory`. Each event updates these through `handle(_:)`.

`ToolCallInfo` (`AgentStream.swift:6-23`) tracks each call's `ToolCallState` for UI display. Calls from sub-agents receive composite IDs and names built from the path of enclosing tool calls (`AgentStream.swift:340-348`), which keeps identical local IDs from different sub-agents apart.

`observeEnvelope` (`AgentStream.swift:264-270`) updates `sessionID` from the first event that carries one. It also sets `currentCheckpoint` from a `replayed` origin. The effect is that a UI sees the checkpoint it resumed from without reading the event itself.

## Buffer and replay

`AgentStream` can record events into a `StreamEventBuffer` when constructed with `bufferCapacity` (`AgentStream.swift:50-52`). The buffer is created only when a capacity is supplied. Each event is recorded inside the consuming task before it is handled (`AgentStream.swift:113`). Starting a new send clears the buffer first.

`StreamEventBuffer` (`StreamEventBuffer.swift:11-28`) is an actor holding a fixed-size ring. Its default capacity is 1024 and its precondition requires at least 1. `record(_:)` returns a monotonic `UInt64` cursor. When the ring is full, the oldest entry is overwritten (`StreamEventBuffer.swift:31-42`).

`replay(from:)` on the buffer (`StreamEventBuffer.swift:57-75`) yields events whose cursor is at least the requested cursor. It fails with one of three `BufferReplayError` values:

- `bufferDisabled`, from `AgentStream.replay` when no buffer was configured (`AgentStream.swift:183-188`).
- `cursorInFuture(currentCursor:)`, when the requested cursor is greater than the next cursor.
- `cursorTrimmed(oldestAvailable:)`, when the requested cursor has already been overwritten.

A consumer that is too slow to keep up with the ring will therefore see `cursorTrimmed` on replay. The fix is a larger capacity or faster consumption.

## Wire format

`StreamEventJSONCodec` (`StreamEventJSONCodec.swift:4-30`) is the stable JSON format for persisting and replaying events. The encoder uses sorted keys and base64 for data. The decoder uses the same base64 strategy. `encode(_:)` and `decode(_:)` wrap these encoder and decoder pairs. Sorted keys make the key order of encoded output deterministic.

## Operational notes

- Events from a superseded send are ignored. The loop compares the generation counter before recording and handling each event (`AgentStream.swift:110-115`).
- Buffer capacity bounds memory, not time. A long run with a small capacity loses its earliest events.

## Related pages

- [Agent loop](agent-loop.md) produces the events and defines the termination policy.
- [Checkpointing and resume](checkpointing.md) describes the replayed-origin events.
- [Messages and history](messages-and-history.md) defines the history carried in `iterationCompleted` and `finished` events.
