---
type: architecture
title: Messages and History
description: The canonical ChatMessage model, multimodal content parts, token usage accounting, assistant continuity fields, and the history validation and truncation rules that keep conversation state well-formed for the agent loop.
tags: [messages, chat-history, token-usage, content-parts, validation, swift]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-4eb89c98d3ee61cb6bc809df
    resource: repo://Sources/AgentHarnessKit/Messages/ChatMessage.swift
  - id: openwiki-source-51f783ffa1214f96c9b68e92
    resource: repo://Sources/AgentHarnessKit/Messages/ChatMessageHistory.swift
  - id: openwiki-source-a0a9480c000a0078401c8939
    resource: repo://Sources/AgentHarnessKit/Messages/TokenUsageCoverage.swift
  - id: openwiki-source-17de722c51a0c5eee1130276
    resource: repo://Sources/AgentHarnessKit/Messages/TokenUsageTotals.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Messages and History

`ChatMessage` is the single conversation model that the agent loop, the context store, checkpoints, and the provider adapters share. Its shape is intentionally narrow: five cases, a structured assistant payload, and a set of invariants on tool-call batches. Every history that enters the loop is validated against those invariants before a model request or a resume.

## The message model

`ChatMessage` (`Sources/AgentHarnessKit/Messages/ChatMessage.swift:4-9`) is a `Sendable, Equatable, Codable` enum with five cases:

- `system(String)`
- `user(String)`
- `userMultimodal([ContentPart])`
- `assistant(AssistantMessage)`
- `tool(id: String, name: String, content: String)`

Convenience constructors (`ChatMessage.swift:11-33`) build multimodal user messages from text plus image, video, or audio data. Each one only wraps `ContentPart` values; there is no separate multimodal type.

`AssistantMessage` (`AssistantMessage.swift:4-10`) carries the assistant output as `content`, `toolCalls`, `tokenUsage`, `reasoning`, `reasoningDetails`, and `continuity`. The `continuity` field, typed by `AssistantContinuity` and `ReplaySubstrate` (`AssistantContinuity.swift:4-6`), records provider-specific replay anchors. The substrate cases include `openAIChatCompletions` and `responses`. The continuity field exists so that a provider can continue a server-side conversation. It is dropped when history is truncated, which is covered below.

Multimodal input is a `ContentPart` enum (`ContentPart.swift:41-46`) with text, image URL, image base64, video base64, PDF base64, and audio base64 cases. Audio carries an `AudioInputFormat` with the formats wav, mp3, m4a, flac, ogg, opus, and webm (`ContentPart.swift:5-11`). Decoding maps MIME types to these cases by prefix and exact match (`ContentPart.swift:144-148`).

## Token accounting

Usage is tracked at two levels:

- `TokenUsage` describes one model response.
- `TokenUsageTotals` (`TokenUsageTotals.swift:6-16`) accumulates input, output, reasoning, cache-read, and cache-write counts across iterations. Its `total` is a computed value.

Each total carries a coverage state, `TokenUsageCoverage` with `complete`, `partial`, and `unavailable` (`TokenUsageCoverage.swift:2-5`). Coverage matters because a provider may omit some counts. A total whose cache counts are unknown reports `partial` coverage rather than zero. `TokenUsageTotals.record(_:)` (`TokenUsageTotals.swift:53`) merges each response's usage and updates coverage.

## Validation invariants

Validation for conversation histories is implemented in `ChatMessageHistory.swift` and has two entry points. `validateForAgentHistory()` (`ChatMessageHistory.swift:22-24`) checks the history as the loop stores it. `validateForLLMRequest()` (`ChatMessageHistory.swift:18-20`) checks it as a provider will receive it. Both delegate to a shared tool-call check that reports these problems:

- `unfinishedToolCallBatch(ids:)`: an assistant tool-call batch has no matching tool results.
- `unexpectedToolResult(id:)`: a tool result has no preceding call.
- `toolResultOrderMismatch(expectedID:actualID:)`: results arrive out of call order.
- `finishMustBeExclusive`: a `finish` call appears in a batch with other tool calls.

Each problem maps to an `AgentError.malformedHistory` case. This keeps the loop's error handling uniform. The loop is described in [Agent loop](agent-loop.md).

`sanitizedTerminalHistory()` (`ChatMessageHistory.swift:26-50`) handles the terminal case. If the last assistant message contains exactly one `finish` call, it restores the answer text from the decoded `finish` arguments, falling back to the assistant text when the arguments do not decode. If the finish call is mixed with other calls, it throws `finishMustBeExclusive`. The restored message is stored in place. If it becomes empty after removing terminal tools, the message is dropped.

`resolvedPrefixForInheritance()` (`ChatMessageHistory.swift:52-68`) is used when a parent history is inherited by a child run. An unfinished batch at the end is trimmed to the last complete boundary, not rejected. Other problems throw. The `finishMustBeExclusive` case traps with `preconditionFailure`, because a parent history with that shape should never have been stored.

## Truncation

`truncated(to:preservingSystemPrompt:)` (`ChatMessage.swift:103-119`) limits history to a message count. It keeps the first system message when `preservingSystemPrompt` is true, and it drops other messages from the front.

The cut point is chosen by `findSafeCutIndex` (`ChatMessage.swift:121-145`). A cut is safe only at a boundary where no assistant tool call is still waiting for its result. Without this check, truncation could leave a tool result without its call, which the validator would then reject.

When a cut is made (`cutIndex > 0`), the function also removes server continuation anchors from every kept assistant message (`ChatMessage.swift:111-113`, `148-171`). An anchor refers to server-side state that no longer matches the truncated history, so keeping it would replay a continuation that is no longer valid.

## Operational consequences

- Histories that fail validation are rejected at the boundary: before a request, before a checkpoint is resumed, and before a parent history is inherited. They are not silently repaired, except for the documented trim of an unfinished trailing batch.
- Token totals can be reported as partial. Callers that enforce a token budget should check coverage before treating a total as exact.
- Continuity anchors are a provider optimization. They are removed by truncation, so a truncated history is always a self-contained transcript.

## Related pages

- [Agent loop](agent-loop.md) uses these invariants and the `finish` rules.
- [Checkpointing and resume](checkpointing.md) validates persisted histories with `validateForAgentHistory()` before replay.
- [ALM adapter](../integrations/alm-adapter.md) maps these types to and from the external provider representation.
