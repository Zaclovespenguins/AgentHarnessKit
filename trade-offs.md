# Trade-offs

Decisions where we chose a simpler or safer option and gave something up. Each entry says what we lost, why, and what would undo it.

## Restored terminal answer drops provider continuity (v0.2 item 2)

**Date:** 2026-11-17 · **Commit:** `ecf0e87` · **Spec:** `AGENTHARNESSKIT_PARITY_SPEC.md`, bullet "Terminal answer in history"

### Decision

When the loop restores a built-in `finish` answer as a plain assistant message (`sanitizedTerminalHistory()` in `Sources/AgentHarnessKit/Messages/ChatMessageHistory.swift`), the restored message has `continuity: nil`. Reasoning, reasoning details and token usage are kept.

### Why

`AssistantContinuity` is the provider's raw replay copy of the turn. For the restored message it is wrong in two ways:

1. It still holds the `finish` tool call. Core could only strip that call from Responses-shaped payloads (`output` / `function_call`). The ALM adapter stores its copy as `almEntries`, which core cannot read.
2. It does not hold the restored answer text, which only existed inside the `finish` arguments.

`HarnessModelClient` with `replaySubstrate` set replays that copy as-is. The follow-up request then carried a `finish` tool call with no tool result and no answer text. Anthropic and OpenAI Chat Completions reject an unanswered tool call, so the next turn would most likely fail with HTTP 400. That last step is inferred from the providers' rules, not observed against a live API.

The proper fix belongs in the ALM adapter: make replayed entries agree with the message's own fields. We don't control ALM, so we dropped the copy in core instead.

### What we gave up

- **Verbatim replay of the one turn that called `finish`.** Adapters rebuild it from semantic fields: reasoning (text plus signature) and response text. Earlier turns in history still replay verbatim.
- **Anthropic signed thinking is not verified on this path.** The rebuilt turn sends the thinking text and signature from `ReasoningContent`, not the original block. Whether Anthropic accepts that in a follow-up request has not been tested against the real API.
- **Responses server continuation.** The `response_id` anchor on that turn is gone too. The old code already removed it when stripping `finish`, so this loses nothing in practice.

### Who is affected

Only clients that replay continuity. In this repo that means `HarnessModelClient` with `replaySubstrate` set, on a turn that had reasoning; ALM saves a replay copy only when reasoning is present. Clients without replay, and turns without reasoning, see no difference.

### Revisit if

- Anthropic rejects the rebuilt thinking turn in a live follow-up request. Test this before relying on reasoning replay with `finish`.
- We gain control over the ALM adapter, or ALM grows a hook for this. Then reconcile in `TranscriptMapping.assistantEntries`: drop `toolCalls` entries whose IDs aren't in `message.toolCalls`, add a `.response` entry for the message text if it's missing, and restore `continuity` on the message.
- An outside client produces Responses-shaped continuity and needs verbatim replay. A core edit could strip `function_call` and add an `output_text` item instead of dropping the copy.

### Tests that pin it

- `Tests/AgentHarnessKitTests/Messages/ChatMessageHistoryTests.swift`: the `...DropsContinuity` / `...DropsResponsesContinuity` cases.
- `Tests/AgentHarnessKitALMTests/MappingTests.swift`: `TerminalAnswerReplayTests` checks that the follow-up transcript is `prompt, reasoning, response, prompt`, with no `finish` call.
