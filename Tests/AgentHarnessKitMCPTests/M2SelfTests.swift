import AgentHarnessKit
@testable import AgentHarnessKitMCP
import Foundation
import Testing

private struct ParsedMessage {
    let id: Int?
    let method: String?
    let cursor: String?
    let text: String
}

private func parse(_ data: Data) -> ParsedMessage {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let params = object?["params"] as? [String: Any]
    return ParsedMessage(
        id: object?["id"] as? Int,
        method: object?["method"] as? String,
        cursor: params?["cursor"] as? String,
        text: String(decoding: data, as: UTF8.self)
    )
}

private actor Recorder {
    private(set) var messages: [String] = []
    func record(_ text: String) {
        messages.append(text)
    }
}

/// Fake MCP server. `pages` maps a `tools/list` cursor ("" for the first page) to its result.
/// `onCall` answers `tools/call` requests; returning nil leaves them unanswered.
private func fakeServer(
    recorder: Recorder? = nil,
    version: String = "2025-06-18",
    failInitialize: Bool = false,
    pages: [String: JSONValue] = ["": MCPTestHelpers.emptyToolsListResult()],
    onCall: @escaping @Sendable (Int) -> Data? = { _ in nil }
) -> DynamicMCPTransport {
    DynamicMCPTransport { data in
        let message = parse(data)
        await recorder?.record(message.text)
        guard let id = message.id, let method = message.method else { return nil }
        switch method {
        case "initialize":
            if failInitialize { throw MCPError.connectionFailed("boom") }
            return MCPTestHelpers.encodeResponse(
                id: id, result: MCPTestHelpers.initializeResult(protocolVersion: version)
            )
        case "tools/list":
            return MCPTestHelpers.encodeResponse(
                id: id, result: pages[message.cursor ?? ""] ?? MCPTestHelpers.emptyToolsListResult()
            )
        case "tools/call":
            return onCall(id)
        default:
            return nil
        }
    }
}

private func mockTool(_ name: String) -> MCPTestHelpers.MockTool {
    MCPTestHelpers.MockTool(
        name: name, description: "\(name) tool", schema: MCPTestHelpers.toolSchema(properties: [:])
    )
}

private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DynamicMCPTransport] = []

    func add(_ transport: DynamicMCPTransport) {
        lock.lock()
        defer { lock.unlock() }
        items.append(transport)
    }

    var all: [DynamicMCPTransport] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Builds a session whose servers answer from `tools` (keyed by server name), recording every transport.
private func makeSession(
    tools: [String: JSONValue],
    failing: Set<String> = [],
    box: TransportBox
) -> MCPSession {
    let factory: @Sendable (MCPServerConfiguration) -> any MCPTransport = { config in
        let transport = fakeServer(
            failInitialize: failing.contains(config.name),
            pages: ["": tools[config.name] ?? MCPTestHelpers.emptyToolsListResult()]
        )
        box.add(transport)
        return transport
    }
    let configurations = tools.keys.sorted().map { name in
        MCPServerConfiguration(name: name, endpoint: URL(string: "https://example.test/mcp")!)
    }
    return MCPSession(configurations: configurations, transportFactory: factory)
}

struct M2SelfTests {
    @Test func connectInitializesAndPagesToolsInOrder() async throws {
        let recorder = Recorder()
        let first = MCPTestHelpers.toolsListResult(tools: [mockTool("alpha")], nextCursor: "page2")
        let second = MCPTestHelpers.toolsListResult(tools: [mockTool("beta")])
        let client = MCPClient(
            serverName: "srv",
            transport: fakeServer(recorder: recorder, pages: ["": first, "page2": second])
        )

        try await client.connectAndInitialize()

        let names = await client.listTools().map(\.name)
        #expect(names == ["alpha", "beta"])
        let messages = await recorder.messages
        // JSONEncoder escapes "/" as "\/", so match on the bare method word.
        #expect(messages.contains { $0.contains("initialized") })
        #expect(messages.contains { $0.contains("\"cursor\":\"page2\"") })
        #expect(messages.contains { $0.contains("AgentHarnessKit") && $0.contains("0.2.0") })
    }

    @Test func protocolVersionMismatchFailsConnect() async throws {
        let client = MCPClient(serverName: "srv", transport: fakeServer(version: "1999-01-01"))
        do {
            try await client.connectAndInitialize()
            Issue.record("expected protocolVersionMismatch")
        } catch let error as MCPError {
            #expect(error == .protocolVersionMismatch(requested: "2025-06-18", supported: "1999-01-01"))
        }
    }

    @Test func initializeErrorFailsConnect() async throws {
        let client = MCPClient(serverName: "srv", transport: fakeServer(failInitialize: true))
        do {
            try await client.connectAndInitialize()
            Issue.record("expected connection failure")
        } catch let error as MCPError {
            #expect(error == .connectionFailed("boom"))
        }
    }

    @Test func jsonRPCErrorResponseMapsToMCPError() async throws {
        let client = MCPClient(
            serverName: "srv",
            transport: fakeServer(onCall: { id in
                MCPTestHelpers.encodeErrorResponse(id: id, code: -32602, message: "bad args")
            })
        )
        try await client.connectAndInitialize()
        do {
            _ = try await client.callTool(name: "echo", arguments: Data("{\"x\":1}".utf8))
            Issue.record("expected jsonRPCError")
        } catch let error as MCPError {
            #expect(error == .jsonRPCError(code: -32602, message: "bad args"))
        }
    }

    @Test func emptyArgumentsAreSentAsEmptyObject() async throws {
        let recorder = Recorder()
        let client = MCPClient(
            serverName: "srv",
            transport: fakeServer(recorder: recorder, onCall: { id in
                MCPTestHelpers.encodeErrorResponse(id: id, code: 1, message: "done")
            })
        )
        try await client.connectAndInitialize()
        _ = try? await client.callTool(name: "echo", arguments: Data())
        let messages = await recorder.messages
        #expect(messages.contains { $0.contains("\"arguments\":{}") })
    }

    @Test func unansweredCallTimesOut() async throws {
        let client = MCPClient(
            serverName: "srv",
            transport: fakeServer(),
            toolCallTimeout: .milliseconds(50)
        )
        try await client.connectAndInitialize()
        do {
            _ = try await client.callTool(name: "slow", arguments: Data())
            Issue.record("expected requestTimeout")
        } catch let error as MCPError {
            #expect(error == .requestTimeout(method: "tools/call"))
        }
    }

    @Test func closingTransportFailsPendingCallsWithTransportClosed() async throws {
        let transport = fakeServer()
        let client = MCPClient(serverName: "srv", transport: transport, toolCallTimeout: .seconds(5))
        try await client.connectAndInitialize()

        let pending = Task { try await client.callTool(name: "hang", arguments: Data()) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.terminateStream()

        do {
            _ = try await pending.value
            Issue.record("expected transportClosed")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test func streamErrorFailsPendingCallsWithConnectionFailed() async throws {
        struct Boom: Error {}
        let transport = fakeServer()
        let client = MCPClient(serverName: "srv", transport: transport, toolCallTimeout: .seconds(5))
        try await client.connectAndInitialize()

        let pending = Task { try await client.callTool(name: "hang", arguments: Data()) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.terminateStreamWithError(Boom())

        do {
            _ = try await pending.value
            Issue.record("expected connectionFailed")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("expected connectionFailed, got \(error)")
                return
            }
        }
    }

    @Test func malformedInboundMessageIsIgnored() async throws {
        let transport = fakeServer(onCall: { id in
            MCPTestHelpers.encodeErrorResponse(id: id, code: 7, message: "still here")
        })
        let client = MCPClient(serverName: "srv", transport: transport)
        try await client.connectAndInitialize()

        await transport.injectMessage(Data("not json".utf8))

        do {
            _ = try await client.callTool(name: "echo", arguments: Data())
            Issue.record("expected jsonRPCError")
        } catch let error as MCPError {
            #expect(error == .jsonRPCError(code: 7, message: "still here"))
        }
    }

    @Test func shutdownDisconnectsTransportAndRejectsFurtherCalls() async throws {
        let transport = fakeServer()
        let client = MCPClient(serverName: "srv", transport: transport)
        try await client.connectAndInitialize()

        await client.shutdown()

        let disconnects = await transport.effectiveDisconnectCallCount()
        #expect(disconnects == 1)
        do {
            _ = try await client.callTool(name: "echo", arguments: Data())
            Issue.record("expected transportClosed")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test func withToolsExposesToolsFromAllServersAndShutsDown() async throws {
        let box = TransportBox()
        let session = makeSession(
            tools: [
                "a": MCPTestHelpers.toolsListResult(tools: [mockTool("alpha")]),
                "b": MCPTestHelpers.toolsListResult(tools: [mockTool("beta")]),
            ],
            box: box
        )

        let names = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) -> [String] in
            tools.map(\.name).sorted()
        }

        #expect(names == ["alpha", "beta"])
        for transport in box.all {
            let disconnects = await transport.effectiveDisconnectCallCount()
            #expect(disconnects == 1)
        }
    }

    @Test func duplicateToolNameAcrossServersThrowsAndShutsDown() async throws {
        let box = TransportBox()
        let session = makeSession(
            tools: [
                "a": MCPTestHelpers.toolsListResult(tools: [mockTool("echo")]),
                "b": MCPTestHelpers.toolsListResult(tools: [mockTool("echo")]),
            ],
            box: box
        )

        do {
            _ = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) -> Int in tools.count }
            Issue.record("expected duplicateToolName")
        } catch let error as MCPError {
            #expect(error == .duplicateToolName(tool: "echo", servers: ["a", "b"]))
        }
        for transport in box.all {
            let disconnects = await transport.effectiveDisconnectCallCount()
            #expect(disconnects == 1)
        }
    }

    @Test func connectFailureOnOneServerShutsDownEveryClient() async throws {
        let box = TransportBox()
        let session = makeSession(
            tools: [
                "a": MCPTestHelpers.toolsListResult(tools: [mockTool("alpha")]),
                "b": MCPTestHelpers.toolsListResult(tools: [mockTool("beta")]),
            ],
            failing: ["b"],
            box: box
        )

        do {
            _ = try await session.withTools { (tools: [any AnyTool<EmptyContext>]) -> Int in tools.count }
            Issue.record("expected connection failure")
        } catch let error as MCPError {
            #expect(error == .connectionFailed("boom"))
        }
        #expect(box.all.count == 2)
        for transport in box.all {
            let disconnects = await transport.effectiveDisconnectCallCount()
            #expect(disconnects == 1)
        }
    }

    @Test func mcpToolExposesInfoBindingAndWrapsErrors() async throws {
        let client = MCPClient(
            serverName: "srv",
            transport: fakeServer(onCall: { id in
                MCPTestHelpers.encodeErrorResponse(id: id, code: -1, message: "nope")
            })
        )
        try await client.connectAndInitialize()
        let info = MCPToolInfo(
            name: "echo", description: "echoes", inputSchema: .object(properties: [:], required: [])
        )
        let tool = MCPTool<EmptyContext>(info: info, client: client)

        #expect(tool.name == "echo")
        #expect(tool.description == "echoes")
        #expect(tool.mcpToolBinding == MCPToolBinding(serverName: "srv", toolName: "echo"))
        do {
            _ = try await tool.execute(arguments: Data(), context: EmptyContext())
            Issue.record("expected toolExecutionFailed")
        } catch let error as AgentError {
            guard case let .toolExecutionFailed(name, _) = error else {
                Issue.record("expected toolExecutionFailed, got \(error)")
                return
            }
            #expect(name == "echo")
        }
    }
}
