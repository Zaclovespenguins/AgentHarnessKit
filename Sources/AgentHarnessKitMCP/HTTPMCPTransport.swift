import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// TASK M5: implement every `fatalError` in this file. New code (no reference). Behaviour contract is in
// the task brief and Tests/AgentHarnessKitMCPTests/HTTPMCPTransportTests.swift.

/// An MCP transport for the Streamable HTTP protocol (MCP 2025-06-18), on every platform.
public actor HTTPMCPTransport: MCPTransport {
    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        fatalError("M5: HTTPMCPTransport.init")
    }

    public func connect() async throws { fatalError("M5: connect") }
    public func disconnect() async { fatalError("M5: disconnect") }
    public func send(_ data: Data) async throws { fatalError("M5: send") }
    public nonisolated func messages() -> AsyncThrowingStream<Data, Error> { fatalError("M5: messages") }

    /// Splits a `text/event-stream` body into the `data` payloads of its `message` events.
    static func parseServerSentEvents(_ body: Data) -> [Data] {
        fatalError("M5: parseServerSentEvents")
    }
}
