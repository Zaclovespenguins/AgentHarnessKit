---
type: integration
title: MCP Integration
description: How the AgentHarnessKitMCP module connects to Model Context Protocol servers over stdio or Streamable HTTP, performs the initialize handshake and paged tool discovery, exposes each discovered tool as an AnyTool, and scopes connections to a single closure with guaranteed shutdown.
tags: [mcp, json-rpc, stdio, http, tools, transport, session, timeouts]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T22:07:55.531Z
sources:
  - id: openwiki-source-6fc53b1b2f3d457c0d12a5b4
    resource: repo://Sources/AgentHarnessKitMCP/MCPClient.swift
  - id: openwiki-source-48ca9d54aa0c22ddd1a241eb
    resource: repo://Sources/AgentHarnessKitMCP/MCPSession.swift
  - id: openwiki-source-e343b973b86145ccaa941cee
    resource: repo://Sources/AgentHarnessKitMCP/MCPTool.swift
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# MCP Integration

`AgentHarnessKitMCP` lets an agent use tools that Model Context Protocol (MCP) servers provide. It connects to each configured server, discovers the server's tools, and wraps each tool as an `AnyTool` that the core agent loop can call like any local tool. The module is a separate product that depends only on `AgentHarnessKit`.

## Main types

- `MCPServerConfiguration` (`Sources/AgentHarnessKitMCP/MCPServerConfiguration.swift:5`) describes one server. It has two transports: `stdio`, which launches a child process and talks over its stdin and stdout, and `http`, which uses a Streamable HTTP endpoint with optional headers. The stdio transport is compiled only on macOS and Linux (`MCPServerConfiguration.swift:7`, `:18`, `:68`). Both transports have an initialization timeout (default 30 seconds) and a tool-call timeout (default 60 seconds).
- `MCPSession` (`Sources/AgentHarnessKitMCP/MCPSession.swift:5`) coordinates several servers. Its `withTools` method is the public entry point.
- `MCPClient` (`Sources/AgentHarnessKitMCP/MCPClient.swift:20`) is an actor that owns one server connection. It holds the state machine (`created`, `connecting`, `ready`, `disconnected`, `failed`), pending requests keyed by integer id, a reader task, and the discovered tool list.
- `MCPTransport` (`Sources/AgentHarnessKitMCP/MCPTransport.swift:5`) is the transport protocol with `connect`, `disconnect`, `send`, and `messages`. `StdioMCPTransport` and `HTTPMCPTransport` (`Sources/AgentHarnessKitMCP/HTTPMCPTransport.swift:7`) implement it.
- `MCPTool<C>` (`Sources/AgentHarnessKitMCP/MCPTool.swift:5`) adapts one discovered tool to `AnyTool`. It also conforms to `MCPBindingProviding`, which the checkpoint code uses to verify tool bindings on resume (see [Checkpointing](../architecture/checkpointing.md)).
- JSON-RPC types live in `JSONRPCMessage.swift`: `JSONRPCRequest`, `JSONRPCNotification`, `JSONRPCResponse`, `JSONRPCErrorObject`, and the `JSONRPCMessage` enum.
- `MCPContent`, `MCPCallResult`, and `MCPResourceContent` (`MCPContent.swift`, `MCPResourceContent.swift`) model the content returned by tool calls. `MCPCallResult.toToolResult()` (`MCPContent.swift:138`) converts a call result into a `ToolResult`.

## Session lifecycle

`MCPSession.withTools(_:)` (`MCPSession.swift:23`) is the only public way to use MCP tools. It runs in three phases:

1. It creates one `MCPClient` per configuration, with the configured timeouts.
2. It connects all clients concurrently in a task group (`connectAll`). If one connection fails, the others are cancelled and their results are drained before the error is rethrown.
3. It collects tools from all clients (`collectTools`), then calls the caller's closure with the tool array. After the closure returns or throws, every client is shut down.

Tool names must be unique across servers. `collectTools` throws `MCPError.duplicateToolName(tool:servers:)` when two servers expose the same name (`MCPSession.swift`, `collectTools`). The collected tools are valid only inside the closure. This scoping means a server cannot be used after the call returns.

## Handshake and discovery

`MCPClient.connectAndInitialize()` (`MCPClient.swift:63`) can run only from the `created` state. It connects the transport, sends `initialize`, sends the `notifications/initialized` notification, and then pages through `tools/list` using the returned `nextCursor` until no cursor remains (`MCPClient.swift:284-291`). Any failure moves the client to `failed`.

## Calling a tool

`MCPTool.execute(arguments:context:)` (`MCPTool.swift:20`) forwards to `MCPClient.callTool(name:arguments:)` (`MCPClient.swift:129`). That method:

1. Requires the client to be in `ready`. Otherwise it throws `MCPError.transportClosed`.
2. Sends a `tools/call` request with the tool name and the decoded arguments. Empty arguments and `{}` are sent as an empty object.
3. Waits for the response with the tool-call timeout.
4. Throws `MCPError.jsonRPCError(code:message:)` when the server returns a JSON-RPC error. Otherwise it decodes the result as `MCPCallResult`.

`MCPTool` maps `CancellationError` to itself and every other error to `AgentError.toolExecutionFailed(tool:message:)`, so the agent loop sees the same error shape as for local tools.

## Operational consequences

- Tool discovery happens once, when `withTools` connects. A server that changes its tool list during a session is not seen until the next `withTools` call.
- Tool schemas come from the server's `inputSchema`, which is stored as a `JSONSchema` (`MCPToolInfo.swift:5`).
- Stdio servers run as child processes. Their stdin and stdout carry newline-delimited JSON-RPC frames (`StdioMCPTransport.swift:139-160`).
- Both the initialization and the tool-call timeouts are enforced by `MCPClient`, so a hung server fails its request instead of blocking the agent loop indefinitely.

## Tests

`Tests/AgentHarnessKitMCPTests/` covers each layer. `JSONRPCMessageTests.swift` covers message encoding. `HTTPMCPTransportTests.swift` and `StdioMCPTransportTests.swift` cover the transports. `MCPClientTests.swift` and `MCPSessionTests.swift` cover the handshake, discovery, and shutdown. `MCPToolTests.swift` covers the `AnyTool` adapter. `MCPIntegrationTests.swift` holds integration tests, and `Tests/AgentHarnessKitMCPTests/Support/` holds `MCPTestHelpers`, `MockURLProtocol`, and `MockHTTPServer`.

## Related pages

- [Tools and schema](../architecture/tools-and-schema.md) describes the `AnyTool` contract that `MCPTool` implements.
- [Testing support](testing-support.md) describes the helpers used to test MCP-backed tools.
