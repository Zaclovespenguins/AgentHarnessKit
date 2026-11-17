import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An MCP transport for the Streamable HTTP protocol (MCP 2025-06-18), on every platform.
public actor HTTPMCPTransport: MCPTransport {
    private let endpoint: URL
    private let headers: [String: String]
    private let urlSession: URLSession
    private var connected = false
    private var sessionID: String?
    private nonisolated let stream: AsyncThrowingStream<Data, Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.endpoint = endpoint
        self.headers = headers
        urlSession = session
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        let wasConnected = connected
        let id = sessionID
        connected = false
        sessionID = nil
        if wasConnected, let id {
            var request = makeRequest(method: "DELETE")
            request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await urlSession.data(for: request)
        }
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard connected else { throw MCPError.transportClosed }
        var request = makeRequest(method: "POST")
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let result: (Data, URLResponse)
        do {
            // shortcut: buffers each response body; no server-initiated GET stream or resumability. Upgrade when server notifications or long-running streamed calls matter.
            result = try await urlSession.data(for: request)
        } catch {
            throw MCPError.connectionFailed(String(describing: error))
        }
        let (body, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.connectionFailed("non-HTTP response")
        }

        let priorSession = sessionID
        if let id = Self.header("Mcp-Session-Id", in: http) { sessionID = id }
        let status = http.statusCode
        guard (200..<300).contains(status) else {
            // The server expired the session we were using; the next request must start a new one.
            if status == 404, let priorSession, sessionID == priorSession { sessionID = nil }
            throw MCPError.connectionFailed("HTTP \(status)")
        }
        if status == 202 || body.isEmpty { return }

        let contentType = Self.header("Content-Type", in: http)?.lowercased() ?? ""
        if contentType.hasPrefix("text/event-stream") {
            for payload in Self.parseServerSentEvents(body) { continuation.yield(payload) }
        } else {
            continuation.yield(body)
        }
    }

    public nonisolated func messages() -> AsyncThrowingStream<Data, Error> { stream }

    /// Splits a `text/event-stream` body into the `data` payloads of its `message` events.
    static func parseServerSentEvents(_ body: Data) -> [Data] {
        var events: [Data] = []
        var dataLines: [String] = []
        var eventType: String?

        func dispatch() {
            defer {
                dataLines = []
                eventType = nil
            }
            guard !dataLines.isEmpty, eventType == nil || eventType == "" || eventType == "message" else { return }
            events.append(Data(dataLines.joined(separator: "\n").utf8))
        }

        for var line in body.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if line.last == 0x0D { line = line.dropLast() }
            if line.isEmpty {
                dispatch()
                continue
            }
            if line.first == 0x3A { continue } // comment line

            let text = String(decoding: line, as: UTF8.self)
            let field: Substring
            var value: Substring
            if let colon = text.firstIndex(of: ":") {
                field = text[..<colon]
                value = text[text.index(after: colon)...]
                if value.first == " " { value = value.dropFirst() }
            } else {
                field = text[...]
                value = ""
            }
            switch field {
            case "data": dataLines.append(String(value))
            case "event": eventType = String(value)
            default: break // id and retry are not used by this transport
            }
        }
        dispatch() // a final event with no trailing blank line still counts
        return events
    }

    private func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
    }
}
