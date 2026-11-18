import AgentHarnessKit
@testable import AgentHarnessKitMCP
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct M4SelfTests {
    private func collect(_ transport: HTTPMCPTransport) async throws -> [String] {
        var out: [String] = []
        for try await message in transport.messages() {
            out.append(String(decoding: message, as: UTF8.self))
        }
        return out
    }

    private func failure(of body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    private func payload(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// Point 1 and 2: init does no I/O, connect sends nothing.
    @Test func initAndConnectDoNoNetworkRequests() async throws {
        let server = MockHTTPServer { _ in (200, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        #expect(server.requests.isEmpty)
        try await transport.connect()
        #expect(server.requests.isEmpty)
        await transport.disconnect()
    }

    /// Point 3: send before connect and after disconnect throws transportClosed.
    @Test func sendBeforeConnectOrAfterDisconnectThrows() async throws {
        let server = MockHTTPServer { _ in (200, ["Content-Type": "application/json"], Data("{}".utf8)) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        let beforeConnect = await failure(of: { try await transport.send(payload("{}")) })
        #expect((beforeConnect as? MCPError) == .transportClosed)
        try await transport.connect()
        await transport.disconnect()
        let afterDisconnect = await failure(of: { try await transport.send(payload("{}")) })
        #expect((afterDisconnect as? MCPError) == .transportClosed)
        #expect(server.requests.isEmpty)
    }

    /// Point 3: request shape, and a plain JSON 2xx body is yielded whole.
    @Test func postsRequiredHeadersAndYieldsJSONBody() async throws {
        let server = MockHTTPServer { request in
            (200, ["Content-Type": "application/json"], request.body)
        }
        let transport = HTTPMCPTransport(
            endpoint: server.endpoint,
            headers: ["Authorization": "Bearer t", "X-Extra": "1"],
            session: server.session
        )
        try await transport.connect()
        try await transport.send(payload("{\"id\":1}"))
        await transport.disconnect()
        let messages = try await collect(transport)

        #expect(messages == ["{\"id\":1}"])
        let post = try #require(server.requests.first)
        #expect(post.method == "POST")
        #expect(post.body == payload("{\"id\":1}"))
        #expect(post.header("Content-Type") == "application/json")
        #expect(post.header("Accept") == "application/json, text/event-stream")
        #expect(post.header("MCP-Protocol-Version") == "2025-06-18")
        #expect(post.header("Authorization") == "Bearer t")
        #expect(post.header("X-Extra") == "1")
        #expect(post.header("Mcp-Session-Id") == nil)
    }

    /// Point 3 and 4: session id captured case-insensitively, then sent on every later request.
    @Test func capturesAndReusesSessionID() async throws {
        let server = MockHTTPServer { request in
            if request.header("Mcp-Session-Id") == nil {
                return (200, ["mcp-session-id": "abc"], payload("{}"))
            }
            return (200, [:], Data())
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(payload("{\"n\":1}"))
        try await transport.send(payload("{\"n\":2}"))
        #expect(server.requests.count == 2)
        #expect(server.requests[1].header("Mcp-Session-Id") == "abc")
        await transport.disconnect()
    }

    /// Point 3: 202 yields nothing; an empty 200 body yields nothing.
    @Test func acceptedAndEmptyResponsesYieldNothing() async throws {
        let server = MockHTTPServer { request in
            request.body == payload("202") ? (202, [:], payload("ignored")) : (200, [:], Data())
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(payload("202"))
        try await transport.send(payload("empty"))
        await transport.disconnect()
        #expect(try await collect(transport).isEmpty)
    }

    /// Point 3: SSE content type with parameters yields each event payload in order.
    @Test func sseResponseYieldsEachPayloadInOrder() async throws {
        let body = "event: message\ndata: {\"a\":1}\n\n: keepalive\n\ndata: {\"b\":2}\n\n"
        let server = MockHTTPServer { _ in
            (200, ["Content-Type": "Text/Event-Stream; charset=utf-8"], payload(body))
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(payload("{}"))
        await transport.disconnect()
        #expect(try await collect(transport) == ["{\"a\":1}", "{\"b\":2}"])
    }

    /// Point 3: non-2xx throws connectionFailed with the status code.
    @Test func nonSuccessStatusThrowsWithCode() async throws {
        let server = MockHTTPServer { _ in (500, [:], payload("boom")) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        let error = await failure(of: { try await transport.send(payload("{}")) })
        guard case let .connectionFailed(message) = error as? MCPError else {
            Issue.record("expected connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("HTTP 500"))
        await transport.disconnect()
    }

    /// Point 3: a 404 clears the stored session id, so the next request starts without it.
    @Test func notFoundClearsSessionID() async throws {
        let server = MockHTTPServer { request in
            if request.body == payload("expire") {
                return (404, [:], Data())
            }
            return (200, ["Mcp-Session-Id": "abc"], payload("{}"))
        }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        try await transport.send(payload("first"))
        #expect(await failure(of: { try await transport.send(payload("expire")) }) != nil)
        try await transport.send(payload("after"))
        #expect(server.requests.count == 3)
        #expect(server.requests[1].header("Mcp-Session-Id") == "abc")
        #expect(server.requests[2].header("Mcp-Session-Id") == nil)
        await transport.disconnect()
    }

    /// Point 3: a URLSession error becomes connectionFailed.
    @Test func urlSessionErrorBecomesConnectionFailed() async throws {
        let server = MockHTTPServer { _ in throw URLError(.notConnectedToInternet) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        let error = await failure(of: { try await transport.send(payload("{}")) })
        guard case .connectionFailed = error as? MCPError else {
            Issue.record("expected connectionFailed, got \(String(describing: error))")
            return
        }
        await transport.disconnect()
    }

    /// Point 4: disconnect sends DELETE with the session id, is idempotent, and finishes the stream.
    @Test func disconnectSendsDeleteOnceAndFinishesStream() async throws {
        let server = MockHTTPServer { request in
            request.method == "POST" ? (200, ["Mcp-Session-Id": "abc"], payload("hi")) : (500, [:], Data())
        }
        let transport = HTTPMCPTransport(
            endpoint: server.endpoint,
            headers: ["Authorization": "Bearer t"],
            session: server.session
        )
        try await transport.connect()
        try await transport.send(payload("{}"))
        await transport.disconnect()
        await transport.disconnect()

        let deletes = server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.header("Mcp-Session-Id") == "abc")
        #expect(deletes.first?.header("Authorization") == "Bearer t")
        // Buffered messages are still delivered, then the stream ends without error.
        #expect(try await collect(transport) == ["hi"])
    }

    /// Point 4: disconnect without a session id sends no DELETE.
    @Test func disconnectWithoutSessionSendsNoDelete() async throws {
        let server = MockHTTPServer { _ in (200, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        try await transport.connect()
        await transport.disconnect()
        #expect(server.requests.isEmpty)
    }

    /// Point 4: disconnect before connect is a no-op that still ends the stream.
    @Test func disconnectBeforeConnectIsNoOp() async throws {
        let server = MockHTTPServer { _ in (200, [:], Data()) }
        let transport = HTTPMCPTransport(endpoint: server.endpoint, session: server.session)
        await transport.disconnect()
        #expect(server.requests.isEmpty)
        #expect(try await collect(transport).isEmpty)
    }

    /// Point 6: SSE parsing edge cases.
    @Test func parsesSingleEvent() {
        let events = HTTPMCPTransport.parseServerSentEvents(payload("data: hello\n\n"))
        #expect(events == [payload("hello")])
    }

    @Test func joinsMultipleDataLinesWithNewline() {
        let events = HTTPMCPTransport.parseServerSentEvents(payload("data: line1\ndata: line2\n\n"))
        #expect(events == [payload("line1\nline2")])
    }

    @Test func handlesCRLFLineEndings() {
        let events = HTTPMCPTransport.parseServerSentEvents(payload("data: a\r\n\r\ndata: b\r\n\r\n"))
        #expect(events == [payload("a"), payload("b")])
    }

    @Test func stripsOnlyOneLeadingSpace() {
        let events = HTTPMCPTransport.parseServerSentEvents(payload("data:  two\n\ndata:none\n\n"))
        #expect(events == [payload(" two"), payload("none")])
    }

    @Test func ignoresCommentsIdAndRetry() {
        let body = ": comment\nid: 7\nretry: 1000\ndata: x\n\n"
        #expect(HTTPMCPTransport.parseServerSentEvents(payload(body)) == [payload("x")])
    }

    @Test func dropsNonMessageEventTypes() {
        let body = "event: ping\ndata: p\n\nevent: message\ndata: m\n\ndata: plain\n\n"
        #expect(HTTPMCPTransport.parseServerSentEvents(payload(body)) == [payload("m"), payload("plain")])
    }

    @Test func skipsEventsWithoutData() {
        let body = "event: message\n\n: only a comment\n\ndata: real\n\n"
        #expect(HTTPMCPTransport.parseServerSentEvents(payload(body)) == [payload("real")])
    }

    @Test func dispatchesFinalEventWithoutBlankLine() {
        let events = HTTPMCPTransport.parseServerSentEvents(payload("data: first\n\ndata: tail"))
        #expect(events == [payload("first"), payload("tail")])
    }

    @Test func emptyBodyParsesToNothing() {
        #expect(HTTPMCPTransport.parseServerSentEvents(Data()).isEmpty)
    }
}
