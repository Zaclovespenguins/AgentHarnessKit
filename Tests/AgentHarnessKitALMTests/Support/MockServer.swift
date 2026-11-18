import Foundation

#if os(Linux)
    private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
    private let sockStream = SOCK_STREAM
#endif

/// Scripted OpenAI Chat Completions mock on plain BSD sockets (restored from tag `spike-final`,
/// then made scriptable). Each request pops the next enqueued `Reply` and records its body.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the socket sock is immutable.
final class MockServer: @unchecked Sendable {
    enum Step {
        case text(String)
        case toolCall(id: String, name: String, arguments: String)
        case usage(input: Int, output: Int)
    }

    struct Reply {
        var steps: [Step]
        var delayMs: UInt32 = 5
        var status = 200
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var bodies: [Data] = []
    private var aborted = 0

    /// Streams the client dropped mid-flight (a write failed). Proves cancellation reached the socket.
    var abortedStreams: Int {
        lock.withLock { aborted }
    }

    var requestCount: Int {
        lock.withLock { bodies.count }
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1/")!
    }

    init() throws {
        signal(SIGPIPE, SIG_IGN)
        let sock = socket(AF_INET, sockStream, 0)
        guard sock >= 0 else { throw MockError.sys("socket") }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else { throw MockError.sys("bind/listen") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        listenFD = sock
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        close(listenFD)
    }

    func enqueue(_ steps: Step..., delayMs: UInt32 = 5, status: Int = 200) {
        lock.withLock { replies.append(Reply(steps: steps, delayMs: delayMs, status: status)) }
    }

    /// The JSON body of the request at `index`, in arrival order.
    func requestJSON(_ index: Int) -> [String: Any] {
        let data = lock.withLock { index < bodies.count ? bodies[index] : Data() }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                return
            }
            Thread.detachNewThread { [self] in handle(client) }
        }
    }

    private func handle(_ sock: Int32) {
        defer { close(sock) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        while !data.contains(sep) {
            let count = read(sock, &buf, buf.count)
            if count <= 0 {
                return
            }
            data.append(buf, count: count)
        }
        guard let split = data.range(of: sep) else { return }
        let head = String(bytes: data[..<split.lowerBound], encoding: .utf8) ?? ""
        var body = Data(data[split.upperBound...])
        let want = head.lowercased().components(separatedBy: "content-length:").dropFirst().first
            // "\r\n" is one Character in Swift, so stop at the first non-digit rather than at "\r".
            .flatMap { Int($0.drop { $0 == " " }.prefix { $0.isNumber }) } ?? 0
        while body.count < want {
            let count = read(sock, &buf, buf.count)
            if count <= 0 {
                return
            }
            body.append(buf, count: count)
        }
        let reply = lock.withLock {
            bodies.append(body)
            return replies.isEmpty ? Reply(steps: [.text("ok")]) : replies.removeFirst()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard reply.status == 200 else {
            _ = put(sock, http(reply.status, #"{"error":{"message":"mock failure","type":"mock_error"}}"#))
            return
        }
        guard json["stream"] as? Bool == true else {
            _ = put(sock, http(200, completion(reply.steps)))
            return
        }
        guard put(sock, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        else { return }
        if !stream(reply, to: sock) {
            lock.withLock { aborted += 1 }
        }
    }

    private func http(_ status: Int, _ body: String) -> String {
        "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func usageObject(_ input: Int, _ output: Int) -> [String: Any] {
        ["prompt_tokens": input, "completion_tokens": output, "total_tokens": input + output]
    }

    /// Non-streaming Chat Completions JSON.
    private func completion(_ steps: [Step]) -> String {
        var content = ""
        var calls: [[String: Any]] = []
        var usage: [String: Any]?
        for step in steps {
            switch step {
            case let .text(text): content += text
            case let .toolCall(id, name, arguments):
                calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": arguments]])
            case let .usage(input, output): usage = usageObject(input, output)
            }
        }
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty {
            message["tool_calls"] = calls
        }
        let finish = calls.isEmpty ? "stop" : "tool_calls"
        var object: [String: Any] = [
            "id": "mock-1", "object": "chat.completion", "created": 0, "model": "mock",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
        ]
        if let usage {
            object["usage"] = usage
        }
        return jsonString(object)
    }

    private func chunk(_ delta: [String: Any], finish: String? = nil, usage: [String: Any]? = nil) -> String {
        var object: [String: Any] = [
            "id": "mock-1", "object": "chat.completion.chunk", "created": 0, "model": "mock",
            "choices": usage == nil ? [["index": 0, "delta": delta, "finish_reason": finish as Any]] : [],
        ]
        if let usage {
            object["usage"] = usage
        }
        return "data: \(jsonString(object))\n\n"
    }

    private func stream(_ reply: Reply, to sock: Int32) -> Bool {
        guard put(sock, chunk(["role": "assistant", "content": ""])) else { return false }
        var callIndex = 0
        var usage: [String: Any]?
        for step in reply.steps {
            usleep(reply.delayMs * 1000)
            switch step {
            case let .text(text):
                guard put(sock, chunk(["content": text])) else { return false }
            case let .toolCall(id, name, arguments):
                let call: [String: Any] = [
                    "index": callIndex, "id": id, "type": "function",
                    "function": ["name": name, "arguments": arguments],
                ]
                callIndex += 1
                guard put(sock, chunk(["tool_calls": [call]])) else { return false }
            case let .usage(input, output):
                usage = usageObject(input, output)
            }
        }
        guard put(sock, chunk([:], finish: callIndex > 0 ? "tool_calls" : "stop")) else { return false }
        if let usage, !put(sock, chunk([:], usage: usage)) {
            return false
        }
        return put(sock, "data: [DONE]\n\n")
    }

    private func put(_ sock: Int32, _ string: String) -> Bool {
        var bytes = Array(string.utf8)[...]
        while !bytes.isEmpty {
            #if canImport(Darwin)
                let count = bytes.withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
            #else
                // MSG_NOSIGNAL: a client that cancelled must not SIGPIPE the whole process.
                let count = bytes.withUnsafeBytes { send(sock, $0.baseAddress!, $0.count, Int32(MSG_NOSIGNAL)) }
            #endif
            if count <= 0 {
                return false
            }
            bytes = bytes.dropFirst(count)
        }
        return true
    }
}

enum MockError: Error {
    case sys(String)
}
