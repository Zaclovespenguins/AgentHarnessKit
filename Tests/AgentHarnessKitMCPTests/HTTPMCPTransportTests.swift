import AgentHarnessKit
@testable import AgentHarnessKitMCP
import Foundation
import Testing

private func sse(_ events: String) -> Data { Data(events.utf8) }
private func strings(_ items: [Data]) -> [String] { items.map { String(decoding: $0, as: UTF8.self) } }

/// Collects the first `count` messages from a transport stream, failing after a timeout.
private func collect(_ transport: HTTPMCPTransport, count: Int) async throws -> [String] {
    try await withThrowingTaskGroup(of: [String].self) { group in
        group.addTask {
            var out: [String] = []
            for try await message in transport.messages() {
                out.append(String(decoding: message, as: UTF8.self))
                if out.count == count { break }
            }
            return out
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw MCPError.requestTimeout(method: "collect")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct SSEParsingTests {
    @Test func singleEvent() {
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(sse("data: {\"a\":1}\n\n"))) == [#"{"a":1}"#])
    }

    @Test func multipleEventsInOrder() {
        let body = sse("data: one\n\ndata: two\n\ndata: three\n\n")
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(body)) == ["one", "two", "three"])
    }

    @Test func multiLineDataJoinedWithNewline() {
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(sse("data: a\ndata: b\n\n"))) == ["a\nb"])
    }

    @Test func crlfLineEndings() {
        let body = sse("event: message\r\ndata: x\r\n\r\ndata: y\r\n\r\n")
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(body)) == ["x", "y"])
    }

    @Test func onlyOneLeadingSpaceStripped() {
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(sse("data:  two\n\ndata:none\n\n"))) == [" two", "none"])
    }

    @Test func commentsIdAndRetryIgnored() {
        let body = sse(": keepalive\nid: 7\nretry: 100\ndata: payload\n\n")
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(body)) == ["payload"])
    }

    @Test func nonMessageEventTypesSkipped() {
        let body = sse("event: ping\ndata: skip\n\nevent: message\ndata: keep\n\ndata: plain\n\n")
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(body)) == ["keep", "plain"])
    }

    @Test func eventTypeResetsAfterDispatch() {
        let body = sse("event: ping\ndata: skip\n\ndata: keep\n\n")
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(body)) == ["keep"])
    }

    @Test func eventsWithoutDataSkipped() {
        #expect(HTTPMCPTransport.parseServerSentEvents(sse("event: message\n\n: only comment\n\n")).isEmpty)
    }

    @Test func trailingEventWithoutBlankLineDispatched() {
        #expect(strings(HTTPMCPTransport.parseServerSentEvents(sse("data: first\n\ndata: last"))) == ["first", "last"])
    }

    @Test func emptyBody() {
        #expect(HTTPMCPTransport.parseServerSentEvents(Data()).isEmpty)
    }
}

struct HTTPMCPTransportTests {
    @Test func sendBeforeConnectThrowsTransportClosed() async {
        let server = MockHTTPServer { _ in (200, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        await #expect(throws: MCPError.transportClosed) { try await transport.send(Data("{}".utf8)) }
        #expect(server.requests.isEmpty)
    }

    @Test func connectDoesNoNetworkIO() async throws {
        let server = MockHTTPServer { _ in (200, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        #expect(server.requests.isEmpty)
    }

    @Test func postsWithRequiredAndCustomHeaders() async throws {
        let server = MockHTTPServer { _ in (202, [:], Data()) }
        let transport = HTTPMCPTransport(
            endpoint: server.endpoint, headers: ["Authorization": "Bearer t0k"], session: server.session
        )
        try await transport.connect()
        let payload = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        try await transport.send(payload)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.body == payload)
        #expect(request.header("Content-Type") == "application/json")
        let accept = try #require(request.header("Accept"))
        #expect(accept.contains("application/json"))
        #expect(accept.contains("text/event-stream"))
        #expect(request.header("MCP-Protocol-Version") == "2025-06-18")
        #expect(request.header("Authorization") == "Bearer t0k")
        #expect(request.header("Mcp-Session-Id") == nil)
    }

    @Test func jsonResponseYieldedAsOneMessage() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        let server = MockHTTPServer { _ in (200, ["Content-Type": "application/json"], Data(body.utf8)) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("{}".utf8))
        #expect(try await collect(transport, count: 1) == [body])
    }

    @Test func sseResponseYieldsEachMessageInOrder() async throws {
        let server = MockHTTPServer { _ in
            (200, ["Content-Type": "text/event-stream; charset=utf-8"],
             Data("data: {\"n\":1}\n\nevent: ping\ndata: x\n\ndata: {\"n\":2}\n\n".utf8))
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("{}".utf8))
        #expect(try await collect(transport, count: 2) == [#"{"n":1}"#, #"{"n":2}"#])
    }

    @Test func acceptedAndEmptyResponsesYieldNothing() async throws {
        let server = MockHTTPServer { request in
            let marker = String(decoding: request.body, as: UTF8.self)
            if marker == "202" { return (202, [:], Data()) }
            if marker == "empty" { return (200, ["Content-Type": "application/json"], Data()) }
            return (200, ["Content-Type": "application/json"], Data("last".utf8))
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("202".utf8))
        try await transport.send(Data("empty".utf8))
        try await transport.send(Data("final".utf8))
        #expect(try await collect(transport, count: 1) == ["last"])
    }

    @Test func sessionIdCapturedCaseInsensitivelyAndReused() async throws {
        let server = MockHTTPServer { _ in (200, ["mcp-session-id": "sess-42", "Content-Type": "application/json"], Data("{}".utf8)) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("first".utf8))
        try await transport.send(Data("second".utf8))
        #expect(server.requests.count == 2)
        #expect(server.requests[0].header("Mcp-Session-Id") == nil)
        #expect(server.requests[1].header("Mcp-Session-Id") == "sess-42")
    }

    @Test func non2xxThrowsConnectionFailedWithStatus() async throws {
        let server = MockHTTPServer { _ in (500, [:], Data("boom".utf8)) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        do {
            try await transport.send(Data("{}".utf8))
            Issue.record("expected failure")
        } catch let MCPError.connectionFailed(message) {
            #expect(message.contains("500"))
        }
    }

    @Test func notFoundClearsSessionId() async throws {
        let server = MockHTTPServer { request in
            switch String(decoding: request.body, as: UTF8.self) {
            case "init": (200, ["Mcp-Session-Id": "old", "Content-Type": "application/json"], Data("{}".utf8))
            case "expired": (404, [:], Data())
            default: (202, [:], Data())
            }
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("init".utf8))
        await #expect(throws: MCPError.self) { try await transport.send(Data("expired".utf8)) }
        try await transport.send(Data("after".utf8))
        #expect(server.requests[1].header("Mcp-Session-Id") == "old")
        #expect(server.requests[2].header("Mcp-Session-Id") == nil)
    }

    @Test func networkErrorThrowsConnectionFailed() async throws {
        let server = MockHTTPServer { _ in throw URLError(.notConnectedToInternet) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        do {
            try await transport.send(Data("{}".utf8))
            Issue.record("expected failure")
        } catch let error as MCPError {
            guard case .connectionFailed = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func disconnectDeletesSessionFinishesStreamAndBlocksSends() async throws {
        let server = MockHTTPServer { request in
            request.method == "DELETE"
                ? (500, [:], Data()) // errors on DELETE must be ignored
                : (200, ["Mcp-Session-Id": "s1", "Content-Type": "application/json"], Data("{}".utf8))
        }
        let transport = HTTPMCPTransport(
            endpoint: server.endpoint, headers: ["Authorization": "x"], session: server.session
        )
        try await transport.connect()
        try await transport.send(Data("init".utf8))
        await transport.disconnect()
        await transport.disconnect()
        let deletes = server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.header("Mcp-Session-Id") == "s1")
        #expect(deletes.first?.header("Authorization") == "x")
        var drained = 0
        for try await _ in transport.messages() { drained += 1 }
        #expect(drained == 1)
        await #expect(throws: MCPError.transportClosed) { try await transport.send(Data("{}".utf8)) }
    }

    @Test func disconnectWithoutSessionSendsNoDelete() async throws {
        let server = MockHTTPServer { _ in (202, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(Data("{}".utf8))
        await transport.disconnect()
        #expect(server.requests.allSatisfy { $0.method == "POST" })
    }

    @Test func messagesReturnsSameStream() async throws {
        let server = MockHTTPServer { _ in (200, ["Content-Type": "application/json"], Data("m".utf8)) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        _ = transport.messages()
        try await transport.connect()
        try await transport.send(Data("{}".utf8))
        await transport.disconnect()
        var seen: [String] = []
        for try await message in transport.messages() { seen.append(String(decoding: message, as: UTF8.self)) }
        #expect(seen == ["m"])
    }
}

/// End to end: MCPClient and MCPSession speaking Streamable HTTP to a scripted server.
struct HTTPMCPEndToEndTests {
    /// A minimal MCP server: JSON for initialize (with session id), SSE for tools/list and tools/call, 202 for notifications.
    private static func makeServer() -> MockHTTPServer {
        MockHTTPServer { request in
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let method = object["method"] as? String
            else { return (400, [:], Data()) }
            guard let id = object["id"] as? Int else { return (202, [:], Data()) }
            if method != "initialize", request.header("Mcp-Session-Id") != "e2e" { return (400, [:], Data()) }
            func reply(_ result: JSONValue) throws -> Data {
                try JSONEncoder().encode(JSONRPCResponse(id: .int(id), result: result, error: nil))
            }
            switch method {
            case "initialize":
                return try (200, ["Content-Type": "application/json", "Mcp-Session-Id": "e2e"],
                            reply(MCPTestHelpers.initializeResult()))
            case "tools/list":
                let tools = MCPTestHelpers.toolsListResult(tools: [.init(
                    name: "echo", description: "Echo",
                    schema: MCPTestHelpers.toolSchema(properties: ["text": .object(["type": .string("string")])])
                )])
                let line = try String(decoding: reply(tools), as: UTF8.self)
                return (200, ["Content-Type": "text/event-stream"], Data(": hi\n\ndata: \(line)\n\n".utf8))
            case "tools/call":
                let line = try String(decoding: reply(MCPTestHelpers.callToolResult(text: "echoed")), as: UTF8.self)
                return (200, ["Content-Type": "text/event-stream"], Data("data: \(line)\n\n".utf8))
            default:
                return (404, [:], Data())
            }
        }
    }

    @Test func clientInitializesListsAndCallsOverHTTP() async throws {
        let server = Self.makeServer()
        let client = MCPClient(
            serverName: "web",
            transport: HTTPMCPTransport(endpoint: server.endpoint, session: server.session),
            initializationTimeout: .seconds(5), toolCallTimeout: .seconds(5)
        )
        try await client.connectAndInitialize()
        #expect(await client.listTools().map(\.name) == ["echo"])
        let result = try await client.callTool(name: "echo", arguments: Data(#"{"text":"x"}"#.utf8))
        #expect(result.toToolResult().content == "echoed")
        await client.shutdown()
        #expect(server.requests.contains { $0.method == "DELETE" && $0.header("Mcp-Session-Id") == "e2e" })
    }

    @Test func sessionExposesHTTPToolsWithBindings() async throws {
        let server = Self.makeServer()
        let config = MCPServerConfiguration(name: "web", endpoint: server.endpoint)
        let session = MCPSession(configurations: [config]) { _ in
            HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        }
        let output = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) in
            let tool = try #require(tools.first)
            #expect((tool as? any MCPBindingProviding)?.mcpToolBinding == MCPToolBinding(serverName: "web", toolName: "echo"))
            return try await tool.execute(arguments: Data("{}".utf8), context: EmptyContext()).content
        }
        #expect(output == "echoed")
    }
}

struct MCPServerConfigurationTests {
    @Test func httpConfigurationBuildsHTTPTransport() {
        let url = URL(string: "https://example.test/mcp")!
        let config = MCPServerConfiguration(name: "web", endpoint: url, headers: ["A": "b"])
        #expect(config.transport == .http(endpoint: url, headers: ["A": "b"]))
        #expect(config.makeTransport() is HTTPMCPTransport)
        #expect(MCPClient(configuration: config).serverName == "web")
    }

    #if os(macOS) || os(Linux)
        @Test func stdioConfigurationBuildsStdioTransport() {
            let config = MCPServerConfiguration(name: "local", command: "/bin/cat", arguments: ["-u"])
            #expect(config.transport == .stdio(command: "/bin/cat", arguments: ["-u"], environment: nil, workingDirectory: nil))
            #expect(config.makeTransport() is StdioMCPTransport)
        }
    #endif
}
