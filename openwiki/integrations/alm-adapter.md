---
type: integration
title: AnyLanguageModel Adapter
description: How the AgentHarnessKitALM module adapts AnyLanguageModel providers to the harness's stateless LLM client seam through HarnessModelClient, including transcript and response mapping, declared-only tool bridging, the stop-before-execution delegate, streaming deltas, error mapping, and provider-specific request options.
tags: [anylanguagemodel, adapter, llm-client, transcript, streaming, tools, errors, provider-options]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:07:55.531Z
sources:
  - id: openwiki-source-35400b9748f800bf925028aa
    resource: repo://Sources/AgentHarnessKitALM/ErrorMapping.swift
  - id: openwiki-source-15a642466aacb496f518bb15
    resource: repo://Sources/AgentHarnessKitALM/HarnessModelClient.swift
  - id: openwiki-source-1d362dd74ab3b15522bad34c
    resource: repo://Sources/AgentHarnessKitALM/ResponseMapping.swift
  - id: openwiki-source-96771c0cb7ae5147137d1dfb
    resource: repo://Sources/AgentHarnessKitALM/StreamDeltaMapper.swift
  - id: openwiki-source-e75f17a0fafd03f86c62b86b
    resource: repo://Sources/AgentHarnessKitALM/ToolBridging.swift
  - id: openwiki-source-b97e36a080d044bce71dd656
    resource: repo://Sources/AgentHarnessKitALM/TranscriptMapping.swift
generated: { by: "claude-code", at: "2026-11-18T22:07:55.531Z" }
---

# AnyLanguageModel Adapter

`AgentHarnessKitALM` is the product that connects the core agent to model providers built on `AnyLanguageModel` (ALM). Its central type is `HarnessModelClient<Model: LanguageModel>` (`Sources/AgentHarnessKitALM/HarnessModelClient.swift:7`). It conforms to `ToolCallSurfacingClient` and `RunStreamingClient`, so the core loop can call it like any other model client.

The design decision is recorded in `docs/ARCHITECTURE.md` section 1. The adapter is a transport. ALM is not allowed to run its own tool loop. Each harness iteration makes one ALM request, and the core `Agent` loop remains the only execution path. It owns approvals, tool execution, checkpoints, context, and sub-agents.

## Responsibilities

- Rebuild an ALM `Transcript` from the harness's `ChatMessage` history for each request (`TranscriptMapping.swift`).
- Declare the harness tools to the provider so it sees their schemas, without letting ALM execute them (`ToolBridging.swift`).
- Stop the provider before any tool call runs, so the harness executes the call itself (`StopDelegate` in `HarnessModelClient.swift`).
- Convert the ALM response, or the stream snapshots, into `AssistantMessage` values or `StreamDelta` values (`ResponseMapping.swift`, `StreamDeltaMapper.swift`).
- Map ALM and transport failures to `AgentError` and `TransportError` (`ErrorMapping.swift`).
- Apply provider-specific request options from `RequestContext` (`ProviderOptions.swift`).

## Non-streaming requests

`generate(messages:tools:responseFormat:requestContext:)` (`HarnessModelClient.swift:29`) performs one request:

1. It maps the messages into a `Transcript` and converts the tool definitions into `DeclaredTool` values.
2. It creates a `LanguageModelSession` with those tools and the transcript, and sets `toolExecutionDelegate` to `StopDelegate`.
3. It applies per-request options from `RequestContext`.
4. It calls `model.respond`. When `responseFormat` is set, it passes a generation schema and returns the structured content as JSON. Otherwise it returns plain `String` content.
5. It converts the response into an `AssistantMessage`, including token usage and the continuity payload when a replay substrate is set.

If the session stops for tool calls, ALM throws `LanguageModelSession.ToolExecutionStopped`. The adapter treats that as the normal outcome. It returns an empty-content assistant message whose tool calls are taken from the stopped transcript, with zero usage (`HarnessModelClient.swift:67-75`). The calls are returned to the loop unexecuted.

Any other error goes through `ErrorMapping.agentError`.

## Streaming requests

`stream(messages:tools:requestContext:)` (`HarnessModelClient.swift:89`) wraps `streamForRun`. `streamForRun` (`HarnessModelClient.swift:114`) iterates `model.streamResponse` snapshots and yields `.delta` values as the content grows. `StreamDeltaMapper` tracks what it has already sent so deltas are not repeated. After the stream ends:

1. Tool-call deltas are yielded from the final transcript entries (`StreamDeltaMapper.toolCallDeltas`).
2. If the turn has replay state, a `.finalizedContinuity` element is yielded before the terminal delta.
3. A `.finished(usage:)` delta is yielded last.

Tool-call arguments are therefore never streamed incrementally. AnyLanguageModel collects a round's tool calls privately and adds them to its snapshots only after the round ends, so the adapter emits each call once, complete, just before `.finished` (a documented `shortcut:` in `StreamDeltaMapper.swift`). This is why the agent's built-in `finish` tool is opt-in: a final answer passed as `finish` arguments reaches `Agent.stream` consumers all at once, while a plain-text answer streams as content deltas.

`stream` keeps only `.delta` elements, so callers that need continuity use `streamForRun` directly (`RunStreamElement`). A cancelled task finishes with `CancellationError`, and any other error becomes an `AgentError` through the same mapping.

## Transcript mapping

`TranscriptMapping.transcript(from:replaySubstrate:)` (`TranscriptMapping.swift:14`) converts each `ChatMessage` case into an ALM entry: `system` becomes `instructions`, `user` becomes `prompt`, `tool` becomes `toolOutput`, and assistant tool calls become `Transcript.ToolCall` values.

When the assistant message's `continuity.substrate` equals the client's `replaySubstrate` and its payload contains `continuityEntriesKey` (`"almEntries"`), the adapter replays the stored entries verbatim. Otherwise it rebuilds the turn from the semantic fields. Verbatim replay is how reasoning state survives across iterations for providers that need it. `ResponseMapping.continuity` writes the same payload when a substrate is configured (`ResponseMapping.swift:26-44`).

## Tool bridging

`ToolBridging.generationSchema(from:)` (`ToolBridging.swift:19`) converts a core `JSONSchema` into ALM's `GenerationSchema` by encoding the schema as JSON and decoding it as a `GenerationSchema`. ALM's decoder accepts more than it preserves, so the adapter then re-encodes the result and checks that each object's property names and `required` list survived (`verifyFields`). A mismatch throws `encodingFailed`.

`DeclaredTool` (`ToolBridging.swift:7`) is the ALM tool type used for declarations. Its `call` always throws `llmError(.other(...))`, because the harness is the only executor.

## Error mapping

`ErrorMapping.agentError(from:provider:)` (`ErrorMapping.swift:11`) passes `CancellationError` and `AgentError` through unchanged. It maps:

- `URLError` with code `.cancelled` to `CancellationError`, and any other `URLError` to `llmError(.networkError)`;
- `HTTPTransportError` by kind: HTTP 429 becomes `rateLimited(retryAfter: nil)`, other HTTP status codes become `httpError(statusCode:body:)`, provider errors become `providerError`, decoding errors become `decodingFailed`, and invalid responses become `invalidResponse`;
- `DecodingError` and `EncodingError` to `decodingFailed` and `encodingFailed`;
- anything else to `llmError(.other(...))`.

## Provider options

`ProviderOptions.apply` (`ProviderOptions.swift:9`) applies `RequestContext.extraFields` through the options type of each known provider: `OpenAILanguageModel`, `AnthropicLanguageModel`, `OpenResponsesLanguageModel`, and `GeminiLanguageModel`. Other model types go through `applyOther`. Extra fields are converted to ALM JSON values first.

## Operational consequences

- Tool execution never happens inside ALM. A provider that ignores the stop delegate would produce a request the harness does not expect, so the adapter depends on the `ToolExecutionStopped` path.
- Replay of verbatim continuity entries requires the same `replaySubstrate` on the client that wrote them. A client with a different substrate rebuilds the turn from semantic fields.
- Zero usage is returned on a stopped tool-call turn, so token accounting for that request is not reported by the provider.

## Tests

`Tests/AgentHarnessKitALMTests/` covers the adapter at several levels. `HarnessModelClientTests.swift` covers the client, `MappingTests.swift` covers transcript and response conversion, `ErrorAndOptionsTests.swift` covers error mapping and provider options, and `AgentOverAdapterTests.swift` runs the core agent over the adapter. `Tests/AgentHarnessKitALMTests/Support/` holds the mock server, step, and error helpers that stand in for provider HTTP responses.

## Related pages

- [Messages and history](../architecture/messages-and-history.md) describes the `ChatMessage` and `AssistantContinuity` types the adapter maps.
- [Overview](../architecture/overview.md) describes the `ALM` product and its place in the package.
