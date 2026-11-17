import Foundation

// TASK M4: implement every `fatalError` in this file. See the reference
// AgentRunKit Sources/AgentRunKit/MCP/StdioMCPTransport.swift (macOS only there; must also work on Linux here).

#if os(macOS) || os(Linux)
    /// An MCP transport that communicates over a child process's stdin/stdout, one JSON message per line.
    public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: URL? = nil
        ) {
            fatalError("M4: StdioMCPTransport.init")
        }

        public func connect() async throws { fatalError("M4: connect") }
        public func disconnect() async { fatalError("M4: disconnect") }
        public func send(_ data: Data) async throws { fatalError("M4: send") }
        public nonisolated func messages() -> AsyncThrowingStream<Data, Error> { fatalError("M4: messages") }
    }
#endif
