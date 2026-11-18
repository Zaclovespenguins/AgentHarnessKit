---
type: architecture
title: Tools and Schema
description: The typed Tool and AnyTool contracts, how tool arguments are decoded and results encoded, how JSON Schema is inferred from Decodable parameter types with SchemaDecoder, and how sub-agent tools run a child Agent under a depth limit.
tags: [tools, json-schema, schema-decoder, tool-results, sub-agents, swift]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-eceba73a35b6e740e64fcf46
    resource: repo://Sources/AgentHarnessKit/Core/Context/SubAgentContext.swift
  - id: openwiki-source-8bcc2f9a711439ca805c2a0f
    resource: repo://Sources/AgentHarnessKit/Tools/SchemaProviding.swift
  - id: openwiki-source-f1c45695495993b95f203206
    resource: repo://Sources/AgentHarnessKit/Tools/SubAgentExecutableTool.swift
  - id: openwiki-source-03e6620613ca1176682f093f
    resource: repo://Sources/AgentHarnessKit/Tools/SubAgentTool.swift
  - id: openwiki-source-ca0872e56eec9cae2456fe83
    resource: repo://Sources/AgentHarnessKit/Tools/Tool.swift
  - id: openwiki-source-deaf73cb553e993e4891f9b0
    resource: repo://Sources/AgentHarnessKit/Tools/ToolResult.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Tools and Schema

A tool is anything the model can call. The package models tools as a protocol, `AnyTool`, with a generic typed implementation, `Tool`. Each tool publishes a JSON Schema for its arguments, decodes the model's JSON arguments into a typed parameter value, runs a typed executor, and encodes the typed output back into a string result. Sub-agents are tools too, implemented by `SubAgentTool`.

## The tool contract

`AnyTool` (`Sources/AgentHarnessKit/Tools/AnyTool.swift:6`) is a `Sendable` protocol with an associated `Context`. Its requirements (`AnyTool.swift:9-28`) include `name`, `description`, `parametersSchema`, `isConcurrencySafe`, `isReadOnly`, `maxResultCharacters`, `toolTimeout`, `strict`, and `execute(arguments: Data, context: Context) async throws -> ToolResult`. The agent loop works with this protocol, not with the concrete type.

`ToolResult` (`Sources/AgentHarnessKit/Tools/ToolResult.swift:3-18`) is a `Sendable, Equatable, Codable` value with `content: String` and `isError: Bool`. Its `success(_:)` and `error(_:)` helpers set the flag. A failed tool does not throw to the loop when the failure is part of the tool's result. It returns a `ToolResult` with `isError` set, and the model sees that message.

`ToolContext` (`Sources/AgentHarnessKit/Tools/ToolContext.swift:1-7`) is the dependency-injection protocol for tools. Its `withParentHistory(_:)` method has a default implementation that returns `self`. Sub-agents override it to pass history down to a child run.

## The typed `Tool`

`Tool<P, O, C>` (`Sources/AgentHarnessKit/Tools/Tool.swift:6-17`) takes three generic parameters: `P` is the parameter type, which must be `Codable & SchemaProviding & Sendable`. `O` is the output type, which must be `Codable & Sendable`. `C` is the context type.

Its initializer (`Tool.swift:19-45`) enforces several rules before the tool exists:

- `maxResultCharacters`, when set, must be at least 1.
- `toolTimeout`, when set, must be at least one millisecond.
- `P.validateSchema()` is called. A schema that cannot be inferred throws at construction, not when the model calls the tool.
- `parametersSchema` is fixed to `P.jsonSchema` at construction.

`execute(arguments:context:)` (`Tool.swift:47-74`) runs in four steps:

1. It decodes `arguments` with `JSONDecoder`. A decoding failure throws `AgentError.toolDecodingFailed(tool:message:)`.
2. It calls the executor. `CancellationError` is rethrown unchanged. An `AgentError` is rethrown unchanged. Any other error is wrapped as `AgentError.toolExecutionFailed(tool:message:)`.
3. It encodes the output with `encodeDeterministicJSON`, a package function in `Sources/AgentHarnessKit/Messages/JSONEncoding.swift`. Encoding failures throw `toolEncodingFailed`.
4. It converts the bytes to UTF-8 text and returns `ToolResult(content:)`. Non-UTF-8 output throws `toolEncodingFailed`.

The output goes through deterministic encoding (`encodeDeterministicJSON`), so the same output value is encoded the same way each time.

## JSON Schema

`JSONSchema` (`Sources/AgentHarnessKit/Tools/JSONSchema.swift:6-14`) is an indirect enum with cases `string`, `integer`, `number`, `boolean`, `array(items:)`, `object(properties:required:)`, `null`, and `anyOf`. Its encoder writes the standard keys `type`, `description`, `items`, `properties`, `required`, `anyOf`, `additionalProperties`, and `enum`.

`SchemaProviding` (`Sources/AgentHarnessKit/Tools/SchemaProviding.swift:2-9`) requires a static `jsonSchema` and a `validateSchema()` method that throws `AgentError`. Types that are also `Decodable` receive both from an extension (`SchemaProviding.swift:11-31`). The `jsonSchema` default calls `SchemaDecoder.decode(Self.self)`. If that fails, it traps with `preconditionFailure` and a message suggesting manual implementation or an earlier `validateSchema()` call. `validateSchema()` converts the same failure to `AgentError.schemaInferenceFailed(type:message:)`.

`SchemaDecoder` (`Sources/AgentHarnessKit/Tools/SchemaDecoder.swift:5`) infers a `JSONSchema` by running the type's `Decodable` initializer against a custom `Decoder`, `SchemaDecoderImpl` (`SchemaDecoder.swift:29`). Its container types are in `SchemaDecoderContainers.swift` and `SchemaKeyedContainer.swift`. Inference records each keyed property into `properties` and collects the `required` list in `SchemaKeyedContainer.swift`. The `SchemaDecoderError` type (`SchemaDecoder.swift:18`) reports inference failures.

Hand-written schemas are the escape hatch. A type can implement `jsonSchema` directly and skip inference.

## Sub-agent tools

`SubAgentTool<P, InnerContext>` (`Sources/AgentHarnessKit/Tools/SubAgentTool.swift:9-58`) wraps an `Agent` as a tool. Its context is `SubAgentContext<InnerContext>`. That context carries the inner context, `currentDepth`, `maxDepth` (default 3), and `parentHistory`. Its initializer requires `currentDepth <= maxDepth` and `maxDepth >= 1` (`Sources/AgentHarnessKit/Core/Context/SubAgentContext.swift:15-21`).

When the child tool runs (`SubAgentTool.swift:60-88`):

1. It decodes the parameters.
2. It checks depth. If `currentDepth >= maxDepth`, it throws `AgentError.maxDepthExceeded(depth:)`.
3. When `inheritParentMessages` is true, it passes the parent history without system messages. Otherwise the child starts with empty history.
4. It calls `agent.run` with a message built by `messageBuilder`, an optional system prompt from `systemPromptBuilder`, an optional `tokenBudget`, and the descended context.

`SubAgentExecutableTool` (`Sources/AgentHarnessKit/Tools/SubAgentExecutableTool.swift:8-21`) is an internal protocol. The agent loop dispatches to `executeSubAgent` or `executeSubAgentStreaming` for these tools rather than to `execute`. This lets the loop forward approvals to the child and, when streaming, wrap child events as `subAgentEvent`. The child always runs under a newly minted `SessionID`. The parent session is never reused. Streaming and event propagation are described in [Streaming pipeline](streaming.md).

## Operational consequences

- Schema errors surface at tool construction. A parameter type that cannot be inferred fails when the tool is created, before any model call.
- Argument errors and executor errors reach the model as tool failures rather than crashing the run. Only `CancellationError` and `AgentError` values propagate unchanged.
- Sub-agent recursion is bounded by `maxDepth`. A depth violation is an error, not a silent cap.

## Related pages

- [Agent loop](agent-loop.md) dispatches tool calls, runs approvals, and enforces the reserved tool names.
- [MCP integration](../integrations/mcp.md) produces `AnyTool` values from remote servers.
