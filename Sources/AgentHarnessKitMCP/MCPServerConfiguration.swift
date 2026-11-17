import AgentHarnessKit
import Foundation

/// Configuration for connecting to an MCP server over stdio (macOS and Linux) or Streamable HTTP (all platforms).
public struct MCPServerConfiguration: Sendable, Equatable {
    public enum Transport: Sendable, Equatable {
        #if os(macOS) || os(Linux)
            case stdio(command: String, arguments: [String], environment: [String: String]?, workingDirectory: String?)
        #endif
        case http(endpoint: URL, headers: [String: String])
    }

    public let name: String
    public let transport: Transport
    public let initializationTimeout: Duration
    public let toolCallTimeout: Duration

    #if os(macOS) || os(Linux)
        /// Launches `command` as a child process and speaks newline-delimited JSON-RPC over its stdin/stdout.
        public init(
            name: String,
            command: String,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: String? = nil,
            initializationTimeout: Duration = .seconds(30),
            toolCallTimeout: Duration = .seconds(60)
        ) {
            precondition(!command.isEmpty, "MCPServerConfiguration command must not be empty")
            self.init(
                name: name,
                transport: .stdio(
                    command: command, arguments: arguments,
                    environment: environment, workingDirectory: workingDirectory
                ),
                initializationTimeout: initializationTimeout,
                toolCallTimeout: toolCallTimeout
            )
        }
    #endif

    /// Connects to a Streamable HTTP MCP endpoint. `headers` are sent on every request (e.g. authorization).
    public init(
        name: String,
        endpoint: URL,
        headers: [String: String] = [:],
        initializationTimeout: Duration = .seconds(30),
        toolCallTimeout: Duration = .seconds(60)
    ) {
        self.init(
            name: name,
            transport: .http(endpoint: endpoint, headers: headers),
            initializationTimeout: initializationTimeout,
            toolCallTimeout: toolCallTimeout
        )
    }

    private init(name: String, transport: Transport, initializationTimeout: Duration, toolCallTimeout: Duration) {
        precondition(!name.isEmpty, "MCPServerConfiguration name must not be empty")
        self.name = name
        self.transport = transport
        self.initializationTimeout = initializationTimeout
        self.toolCallTimeout = toolCallTimeout
    }

    func makeTransport() -> any MCPTransport {
        switch transport {
        #if os(macOS) || os(Linux)
            case let .stdio(command, arguments, environment, workingDirectory):
                StdioMCPTransport(
                    command: command,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory.map { URL(fileURLWithPath: $0) }
                )
        #endif
        case let .http(endpoint, headers):
            HTTPMCPTransport(endpoint: endpoint, headers: headers)
        }
    }
}
