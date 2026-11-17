import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Serves canned HTTP responses to a `URLSession`. Each test registers a handler under a unique host,
/// so parallel tests never share state. Use `MockHTTPServer.make()` to get an endpoint and session.
final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let (status, headers, body) = try handler(request, Self.body(of: request))
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before a protocol sees it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A recorded request seen by a mock server.
struct RecordedHTTPRequest: Sendable {
    let method: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A unique mock endpoint plus a `URLSession` routed to it, with every request recorded.
final class MockHTTPServer: @unchecked Sendable {
    let endpoint: URL
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [RecordedHTTPRequest] = []

    var requests: [RecordedHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// `respond` gets each request (method, headers, body) and returns status, headers, body.
    init(respond: @escaping @Sendable (RecordedHTTPRequest) throws -> (Int, [String: String], Data)) {
        let host = "mcp-\(UUID().uuidString.lowercased()).test"
        endpoint = URL(string: "https://\(host)/mcp")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        MockURLProtocol.register(host: host) { [weak self] request, body in
            let recordedRequest = RecordedHTTPRequest(
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            )
            self?.record(recordedRequest)
            let (status, headers, responseBody) = try respond(recordedRequest)
            return (status, headers, responseBody)
        }
    }

    private func record(_ request: RecordedHTTPRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }
}
