import Foundation
#if canImport(Android)
    import Android
#endif

// Minimal OpenAI Chat Completions SSE mock on plain BSD sockets (no extra deps, so it runs
// unchanged on macOS/Linux/Android). Behavior is keyed off markers in the last user message:
//   [add]  -> streams a tool call add(2,3)        [long] -> streams ~forever, 100ms/token
//   other  -> short streamed answer, 50ms/token
// After a tool result: "The sum is N." (or a denial acknowledgement if the output says DENIED).

#if os(Linux)
    private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
    private let sockStream = SOCK_STREAM
#endif

public final class MockServer: @unchecked Sendable {
    public let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var _aborted = 0
    private var _requests = 0
    /// Streams the client dropped mid-flight (a write failed). Proves cancellation reached the socket.
    public var abortedStreams: Int { lock.withLock { _aborted } }
    public var requestCount: Int { lock.withLock { _requests } }

    public init(port requested: UInt16 = 0) throws {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw MockError.sys("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw MockError.sys("bind/listen") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1/")! }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [self] in handle(c) }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        while data.range(of: sep) == nil {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            data.append(buf, count: n)
        }
        let split = data.range(of: sep)!
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        var body = Data(data[split.upperBound...])
        let want = head.lowercased().components(separatedBy: "content-length:").dropFirst().first
            .flatMap { Int($0.prefix { $0 != "\r" }.trimmingCharacters(in: .whitespaces)) } ?? 0
        while body.count < want {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            body.append(buf, count: n)
        }
        lock.withLock { _requests += 1 }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if json["stream"] as? Bool != true { _ = put(fd, completion(plan(json).steps)); return }
        guard put(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n") else { return }
        let ok = stream(plan(json), to: fd)
        if !ok { lock.withLock { _aborted += 1 } }
    }

    private enum Step { case text(String), toolCall(String, String), usage(Int, Int) }

    private func plan(_ req: [String: Any]) -> (steps: [Step], delayMs: UInt32) {
        let msgs = req["messages"] as? [[String: Any]] ?? []
        func text(_ m: [String: Any]?) -> String {
            if let s = m?["content"] as? String { return s }
            return (m?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        }
        let last = msgs.last
        let hasTools = !(req["tools"] as? [Any] ?? []).isEmpty
        let words: (String) -> [Step] = { $0.split(separator: " ").map { .text($0 + " ") } }
        let prompt = text(msgs.last { $0["role"] as? String == "user" })
        // A tool result is "pending" unless a newer [add] prompt asks for a fresh call.
        let freshAdd = last?["role"] as? String == "user" && prompt.contains("[add]")
        if let tool = msgs.last(where: { $0["role"] as? String == "tool" }), !freshAdd {
            let out = text(tool)
            let msg = out.contains("DENIED") ? "The tool call was denied so I cannot compute it." : "The sum is \(out)."
            return (words(msg) + [.usage(30, 8)], 20)
        }
        if prompt.contains("[long]") { return ((1...2000).map { .text("\($0)\n") }, 100) }
        if prompt.contains("[add]"), hasTools { return ([.toolCall("add", #"{"a":2,"b":3}"#), .usage(20, 5)], 20) }
        return (words("Hello from the mock server, streamed one word at a time.") + [.usage(12, 11)], 50)
    }

    /// Non-streaming Chat Completions JSON, used by `respond(...)`.
    private func completion(_ steps: [Step]) -> String {
        var content = "", calls: [[String: Any]] = [], usage = [0, 0]
        for step in steps {
            switch step {
            case .text(let t): content += t
            case .toolCall(let n, let a):
                calls.append(["id": "call_mock_1", "type": "function", "function": ["name": n, "arguments": a]])
            case .usage(let i, let o): usage = [i, o]
            }
        }
        var msg: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty { msg["tool_calls"] = calls }
        let o: [String: Any] = [
            "id": "mock-1", "object": "chat.completion", "created": 0, "model": "mock",
            "choices": [["index": 0, "message": msg, "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]],
            "usage": ["prompt_tokens": usage[0], "completion_tokens": usage[1], "total_tokens": usage[0] + usage[1]],
        ]
        let d = String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(d.utf8.count)\r\nConnection: close\r\n\r\n\(d)"
    }

    private func stream(_ p: (steps: [Step], delayMs: UInt32), to fd: Int32) -> Bool {
        func chunk(_ delta: [String: Any], finish: String? = nil, usage: [String: Any]? = nil) -> String {
            var o: [String: Any] = [
                "id": "mock-1", "object": "chat.completion.chunk", "created": 0, "model": "mock",
                "choices": usage == nil ? [["index": 0, "delta": delta, "finish_reason": finish as Any]] : [],
            ]
            if let usage { o["usage"] = usage }
            let d = try! JSONSerialization.data(withJSONObject: o)
            return "data: \(String(decoding: d, as: UTF8.self))\n\n"
        }
        guard put(fd, chunk(["role": "assistant", "content": ""])) else { return false }
        var finish = "stop"
        for step in p.steps {
            usleep(p.delayMs * 1000)
            switch step {
            case .text(let t): guard put(fd, chunk(["content": t])) else { return false }
            case .toolCall(let name, let args):
                finish = "tool_calls"
                let call: [String: Any] = ["index": 0, "id": "call_mock_1", "type": "function",
                                           "function": ["name": name, "arguments": args]]
                guard put(fd, chunk(["tool_calls": [call]])) else { return false }
            case .usage(let i, let o):
                guard put(fd, chunk([:], finish: finish)),
                      put(fd, chunk([:], usage: ["prompt_tokens": i, "completion_tokens": o, "total_tokens": i + o]))
                else { return false }
            }
        }
        return put(fd, "data: [DONE]\n\n")
    }

    private func put(_ fd: Int32, _ s: String) -> Bool {
        var bytes = Array(s.utf8)[...]
        while !bytes.isEmpty {
            #if canImport(Darwin)
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
#else
            // MSG_NOSIGNAL: a client that cancelled must not SIGPIPE the whole process.
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, Int32(MSG_NOSIGNAL)) }
#endif
            if n <= 0 { return false }
            bytes = bytes.dropFirst(n)
        }
        return true
    }
}

enum MockError: Error { case sys(String) }
