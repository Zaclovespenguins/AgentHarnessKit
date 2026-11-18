---
type: integration
title: Testing Support Library
description: The AgentHarnessKitTesting product, whose TestLLMClient is a deterministic, schema-driven LLM stand-in that calls tools with generated arguments, plus the internal test helpers in Tests/AgentHarnessKitTests/Support that the suites use for gating, counting, and tagging.
tags: [testing, test-double, llm-client, schema, deterministic, test-support]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-164e2da859b5277df81c7d94
    resource: repo://.github/workflows/ci.yml
  - id: openwiki-source-0d86a7e927885c7fd79bc817
    resource: repo://Sources/AgentHarnessKitTesting/TestLLMClient.swift
  - id: openwiki-source-3482e4293bbb18f05c0591da
    resource: repo://Tests/AgentHarnessKitTests/Support/GatedCheckpointer.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Testing Support Library

`AgentHarnessKitTesting` is a public product, separate from the core module. It provides `TestLLMClient`, an offline `LLMClient` that consumers can plug into an `Agent` to run the full loop without a network or model. The test suites in `Tests/AgentHarnessKitTests/Support` hold their own internal helpers, which are not part of the product.

## TestLLMClient

`TestLLMClient` (`Sources/AgentHarnessKitTesting/TestLLMClient.swift:5`) conforms to `LLMClient` and `ToolCallSurfacingClient`. Its initializer takes:

- `seed` (default 0), which drives the generated argument values;
- `callTools: CallToolsMode` (default `.all`), where `CallToolsMode` is `.all` or `.specific([String])`;
- `finishContent` (default `"Test completed"`), the text returned when the client has nothing to call;
- `completionToolName`, an optional tool to call alone once the ordinary tool work is done;
- `contextWindowSize` and `tokenUsage` (default `TokenUsage(input: 1, output: 1)`).

Its provider identifier is `.custom("test")`.

### Turn logic

`generate` (`TestLLMClient.swift:37`) and `stream` (`TestLLMClient.swift:51`) both call a shared `buildResponse` (`TestLLMClient.swift:77`). The decision order is:

1. If the request has a `responseFormat`, the client returns a JSON document generated from that schema and no tool calls.
2. If no tools are offered, it returns `finishContent` as plain text.
3. Otherwise it computes the turn index from the number of assistant messages. It picks the selectable tools, which are the non-reserved, non-completion tools that match `callTools`.
4. If tool results follow the last user message, or nothing is selectable, it returns the completion tool call when one is configured. If the reserved `finish` tool is offered, it returns a `finish` call with `finishContent`. Otherwise it returns `finishContent` as text.
5. Otherwise it returns one tool call per selectable tool, with the ID `test_call_<turn>_<index>` and arguments produced by `SchemaWalker.generateJSON(from:seed:)`.

`hasToolResultsAfterLastUserMessage` (`TestLLMClient.swift:156`) ignores a user message that directly follows a tool result. That case is a budget advisory inside the same turn, not the start of a new one.

`stream` yields, in order: the content if it is non-empty, a `toolCallStart` and `toolCallDelta` pair for each tool call, and a final `finished` event with the usage.

### Schema-driven arguments

`SchemaWalker` (`TestLLMClient.swift:187`) produces argument JSON from a `JSONSchema`. It takes the first value of an enum string, returns `test_<seed>` for other strings, uses the seed for numbers, and recurses into objects, arrays, and `anyOf` branches. The output is deterministic for a given seed, so tests can compare runs. The generated values are not meaningful inputs to a real tool. Tests that need specific arguments should use their own tools.

## Test support helpers

The following helpers live under `Tests/AgentHarnessKitTests/Support` and are used only by the suites:

- `GatedCheckpointer` (`GatedCheckpointer.swift:3`) is an actor that implements `AgentCheckpointer`. It can block a save at a gate, so a test can observe the mid-run state, using `awaitGateEntered` and `release`. It is the main tool for testing checkpoint and resume ordering (see [Checkpointing](../architecture/checkpointing.md)).
- `ToolInvocationCounter` is an actor with an `increment` method. Tests use it to count how many times a tool ran, for example to confirm that a replay did not re-execute a tool.
- `TestTags` (`TestTags.swift:3-10`) defines the Swift Testing tags `smoke`, `provider`, `wireFormat`, `streaming`, `checkpointing`, `slow`, and `requiresNetwork`. The tags let CI or a developer select a subset of tests.
- Other helpers cover agent results (`AgentResultTestHelpers`), custom completion fixtures (`CustomCompletionFixtures`), stream failure diagnostics, token usage, and tool approval. `TestLLMClientTests.swift` tests the client itself.

## Operational consequences

- `TestLLMClient` runs the real `Agent` loop, so it exercises the same completion, tool-execution, and checkpoint code paths as production. It does not model provider errors, rate limits, or streaming fragments, so those need their own tests.
- Because arguments are generated from schemas, a tool whose schema allows only values the generator does not produce, such as a pattern constraint, will get invalid arguments. The tool's own decoding must handle that.
- The `TestTags` are declared, but the Makefile and CI workflow do not select tests by tag. CI runs the live tests by name, `swift test --filter LiveEndpointTests` (`.github/workflows/ci.yml:96`), so the tags do not change what runs (see [Build and CI](../operations/build-and-ci.md)).

## Related pages

- [Test strategy](../testing/test-strategy.md) explains how these helpers fit the wider test plan.
- [Overview](../architecture/overview.md) lists the products.
