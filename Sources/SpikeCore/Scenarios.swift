import AnyLanguageModel
import Foundation
import HTTPTypes

public final class Locked<T>: @unchecked Sendable {
    private let l = NSLock()
    private var v: T
    public init(_ v: T) { self.v = v }
    public func with<R>(_ f: (inout T) -> R) -> R { l.lock(); defer { l.unlock() }; return f(&v) }
}

public struct AddTool: Tool {
    public let name = "add"
    public let description = "Add two integers and return the sum."
    public let calls: Locked<[[Int]]>
    public init(calls: Locked<[[Int]]> = .init([])) { self.calls = calls }

    @Generable
    public struct Arguments {
        @Guide(description: "first addend") public var a: Int
        @Guide(description: "second addend") public var b: Int
    }

    public func call(arguments: Arguments) async throws -> String {
        calls.with { $0.append([arguments.a, arguments.b]) }
        return String(arguments.a + arguments.b)
    }
}

/// Wraps the default transport and keeps every request body so a scenario can inspect what was sent.
struct RecordingTransport: HTTPTransport {
    let inner: any HTTPTransport = makeDefaultTransport()
    let bodies = Locked<[Data]>([])
    func send<R>(request: HTTPRequest, body: Data?, timeout: Duration?, responseHandler: (HTTPResponse, HTTPResponseBody) async throws -> R) async throws -> R {
        if let body { bodies.with { $0.append(body) } }
        return try await inner.send(request: request, body: body, timeout: timeout, responseHandler: responseHandler)
    }
}

public struct Provider: Sendable {
    public let model: any LanguageModel
    public let label: String
    public let mock: MockServer?

    /// SPIKE_PROVIDER = mock (default) | openai | anthropic.
    /// mock: SPIKE_MOCK_URL points at an external mock (e.g. http://10.0.2.2:8080/v1/ from an Android emulator);
    ///       otherwise one is started in-process.
    /// openai: OPENAI_API_KEY, OPENAI_BASE_URL (optional, any compatible endpoint), SPIKE_MODEL.
    /// anthropic: ANTHROPIC_API_KEY, SPIKE_MODEL.
    public static func fromEnvironment() throws -> Provider {
        let env = ProcessInfo.processInfo.environment
        switch env["SPIKE_PROVIDER"] ?? "mock" {
        case "anthropic":
            let m = AnthropicLanguageModel(apiKey: env["ANTHROPIC_API_KEY"] ?? "", model: env["SPIKE_MODEL"] ?? "claude-haiku-4-5")
            return .init(model: m, label: "anthropic", mock: nil)
        case "openai":
            let base = env["OPENAI_BASE_URL"].flatMap(URL.init(string:)) ?? OpenAILanguageModel.defaultBaseURL
            let m = OpenAILanguageModel(baseURL: base, apiKey: env["OPENAI_API_KEY"] ?? "", model: env["SPIKE_MODEL"] ?? "gpt-4o-mini")
            return .init(model: m, label: "openai-compat(\(base.host ?? "?"))", mock: nil)
        default:
            if let u = env["SPIKE_MOCK_URL"].flatMap(URL.init(string:)) {
                return .init(model: OpenAILanguageModel(baseURL: u, apiKey: "fake-key", model: "mock"), label: "mock(\(u.host ?? "?"))", mock: nil)
            }
            let s = try MockServer()
            return .init(model: OpenAILanguageModel(baseURL: s.baseURL, apiKey: "fake-key", model: "mock"), label: "mock(in-process)", mock: s)
        }
    }
}

public struct Result: Sendable {
    public var id: String, name: String, pass: Bool, ms: Int, detail: String
    public var line: String { "\(pass ? "PASS" : "FAIL") \(id) \(name) \(ms)ms \(detail)" }
}

private func time(_ id: String, _ name: String, _ body: () async throws -> (Bool, String)) async -> Result {
    let t0 = ContinuousClock.now
    var r: (Bool, String)
    do { r = try await body() } catch { r = (false, "threw: \(error)") }
    let d = ContinuousClock.now - t0
    return Result(id: id, name: name, pass: r.0, ms: Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000), detail: r.1)
}

let addPrompt = "What is 2 + 3? You must use the add tool. [add]"

// MARK: S1
public func s1Stream(_ p: Provider) async -> Result {
    await time("S1", "stream") {
        let s = LanguageModelSession(model: p.model)
        let t0 = ContinuousClock.now
        var first: Duration?, n = 0, last = ""
        for try await snap in s.streamResponse(to: "Say hello in about ten words. [short]") {
            if first == nil, !snap.content.isEmpty { first = ContinuousClock.now - t0 }
            n += 1; last = snap.content
        }
        let total = ContinuousClock.now - t0
        let ttft = first ?? total
        // Incremental = several snapshots spread over time (not all at the end). ttft includes any model
        // reasoning time, so it is reported but not part of the pass criterion.
        let spread = (total - ttft).ms
        let ok = n > 2 && spread > 0 && !last.isEmpty
        return (ok, "ttft=\(ttft.ms)ms spread=\(spread)ms total=\(total.ms)ms snapshots=\(n) text=\"\(last.prefix(40))\"")
    }
}

// MARK: S2
public func s2ToolRoundTrip(_ p: Provider) async -> Result {
    await time("S2", "tool round trip") {
        let calls = Locked<[[Int]]>([])
        let s = LanguageModelSession(model: p.model, tools: [AddTool(calls: calls)])
        var text = ""
        for try await snap in s.streamResponse(to: addPrompt) { text = snap.content }
        let kinds = s.transcript.map(\.kind)
        let ok = calls.with { $0 } == [[2, 3]] && text.contains("5") && kinds.contains("toolCalls") && kinds.contains("toolOutput")
        return (ok, "toolCalls=\(calls.with { $0 }) usage.total=\(s.usage.totalTokenCount) text=\"\(text.prefix(40))\" transcript=\(kinds)")
    }
}

// MARK: S3 loop control
/// Stops the loop after the model emits tool calls; records them so we can run them ourselves.
struct StopAfterRound: ToolExecutionDelegate {
    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async -> ToolExecutionDecision { .stop }
}

/// Rebuild a session from checkpoint JSON in the current process, run the pending tool calls ourselves
/// (this is where an approval UI would sit), append the outputs, and let the model continue.
public func resumeFromCheckpoint(_ data: Data, provider p: Provider, calls: Locked<[[Int]]>) async throws -> (String, [String]) {
    let saved = try JSONDecoder().decode(Transcript.self, from: data)
    var entries = Array(saved)
    // Finding: after `.stop` the session appends an empty `.response` after the toolCalls entry; drop it
    // or the tool outputs would not follow their calls.
    if case .response(let r) = entries.last, r.segments.allSatisfy({ if case .text(let t) = $0 { t.content.isEmpty } else { false } }) { entries.removeLast() }
    if case .toolCalls(let tc) = entries.last {
        for call in tc {
            let out = try await AddTool(calls: calls).call(arguments: .init(call.arguments))
            entries.append(.toolOutput(.init(id: call.id, toolName: call.toolName, segments: [.text(.init(content: out))])))
        }
    }
    let s = LanguageModelSession(model: p.model, tools: [AddTool(calls: calls)], transcript: Transcript(entries: entries))
    let r = try await s.respond(to: "Continue and give me the final answer.")
    return (r.content, s.transcript.map(\.kind))
}

public func s3LoopControl(_ p: Provider, checkpoint: URL) async -> Result {
    await time("S3", "loop control") {
        let calls = Locked<[[Int]]>([])
        let s = LanguageModelSession(model: p.model, tools: [AddTool(calls: calls)])
        s.toolExecutionDelegate = StopAfterRound()
        _ = try await s.respond(to: addPrompt)
        let afterOne = s.transcript.map(\.kind)
        let stoppedBeforeExec = calls.with { $0.isEmpty }          // (a) one round, tool not run
        let data = try JSONEncoder().encode(s.transcript)          // (b)+(c) read + serialize
        try data.write(to: checkpoint)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        let roundTrips = decoded == s.transcript
        let (final, kinds) = try await resumeFromCheckpoint(data, provider: p, calls: calls)  // (c) same process
        let ok = stoppedBeforeExec && roundTrips && afterOne.contains("toolCalls") && final.contains("5") && calls.with { $0.count } == 1
        return (ok, "afterOneRound=\(afterOne) stoppedBeforeExec=\(stoppedBeforeExec) jsonRoundTrip=\(roundTrips) bytes=\(data.count) resumed=\"\(final.prefix(30))\" finalTranscript=\(kinds) checkpoint=\(checkpoint.path)")
    }
}

/// Phase B of S3: a fresh process loads the checkpoint file and continues.
public func s3Resume(_ p: Provider, file: URL) async -> Result {
    await time("S3-resume", "cross-process resume") {
        let calls = Locked<[[Int]]>([])
        let (final, kinds) = try await resumeFromCheckpoint(Data(contentsOf: file), provider: p, calls: calls)
        return (final.contains("5") && calls.with { $0.count } == 1, "pid=\(ProcessInfo.processInfo.processIdentifier) resumed=\"\(final.prefix(40))\" transcript=\(kinds)")
    }
}

// MARK: S4
/// Denies the first tool call (the model sees the denial text as the tool output), allows later ones.
final class DenyOnce: ToolExecutionDelegate {
    let denied = Locked(0)
    func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async -> ToolExecutionDecision {
        denied.with { $0 += 1; return $0 } == 1 ? .provideOutput([.text(.init(content: "DENIED: the user did not approve this tool call."))]) : .execute
    }
}

public func s4Approval(_ p: Provider) async -> Result {
    await time("S4", "approval/denial") {
        let calls = Locked<[[Int]]>([])
        let s = LanguageModelSession(model: p.model, tools: [AddTool(calls: calls)])
        s.toolExecutionDelegate = DenyOnce()
        let r1 = try await s.respond(to: addPrompt).content
        let ranAfterDeny = calls.with { $0.count }
        let sawDenial = s.transcript.contains { if case .toolOutput(let o) = $0 { return "\(o.segments)".contains("DENIED") } else { return false } }
        let r2 = try await s.respond(to: addPrompt).content
        let ok = ranAfterDeny == 0 && sawDenial && calls.with { $0.count } == 1 && r2.contains("5")
        return (ok, "toolRunsAfterDeny=\(ranAfterDeny) denialInTranscript=\(sawDenial) reply1=\"\(r1.prefix(40))\" toolRunsAfterApprove=\(calls.with { $0.count }) reply2=\"\(r2.prefix(20))\"")
    }
}

// MARK: S6 thinking-block replay + parallel tool calls (Anthropic only)
public func s6Continuity(_ p: Provider) async -> Result {
    await time("S6", "thinking replay + parallel calls") {
        let env = ProcessInfo.processInfo.environment
        guard p.label == "anthropic" else { return (true, "skipped (anthropic only)") }
        let rec = RecordingTransport()
        let model = AnthropicLanguageModel(apiKey: env["ANTHROPIC_API_KEY"] ?? "", model: env["SPIKE_MODEL"] ?? "claude-haiku-4-5", transport: rec)
        var opts = GenerationOptions(maximumResponseTokens: 4096)
        opts[custom: AnthropicLanguageModel.self] = .init(thinking: .enabled(budgetTokens: 2048))

        // Round 1: thinking on, ask for two independent calls, stop before executing them.
        let calls = Locked<[[Int]]>([])
        let s = LanguageModelSession(model: model, tools: [AddTool(calls: calls)])
        s.toolExecutionDelegate = StopAfterRound()
        _ = try await s.respond(to: "Compute 2 + 3 and also 4 + 5. Call the add tool twice, both calls in the same turn. [add]", options: opts)
        let kinds1 = s.transcript.map(\.kind)
        var sigLen = 0, parallel = 0
        for e in s.transcript {
            if case .reasoning(let r) = e { sigLen = max(sigLen, r.signature?.count ?? 0) }
            if case .toolCalls(let tc) = e { parallel = max(parallel, tc.count) }
        }

        // Round 2: a "new process" - rebuild from JSON only, run the tools ourselves, continue.
        let saved = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(s.transcript))
        var entries = Array(saved)
        if case .response(let r) = entries.last, r.segments.allSatisfy({ if case .text(let t) = $0 { t.content.isEmpty } else { false } }) { entries.removeLast() }
        if case .toolCalls(let tc) = entries.last {
            for c in tc {
                let out = try await AddTool(calls: calls).call(arguments: .init(c.arguments))
                entries.append(.toolOutput(.init(id: c.id, toolName: c.toolName, segments: [.text(.init(content: out))])))
            }
        }
        let n1 = rec.bodies.with { $0.count }
        let s2 = LanguageModelSession(model: model, tools: [AddTool(calls: calls)], transcript: Transcript(entries: entries))
        let final = try await s2.respond(to: "Continue and give me both answers.", options: opts).content

        // The replayed request must carry the signed thinking block before the tool_use blocks.
        let req = rec.bodies.with { $0.count > n1 ? $0[n1] : Data() }
        let json = (try? JSONSerialization.jsonObject(with: req)) as? [String: Any]
        let msgs = json?["messages"] as? [[String: Any]] ?? []
        var order: [String] = []
        var replayedSig = false
        for m in msgs where m["role"] as? String == "assistant" {
            for b in m["content"] as? [[String: Any]] ?? [] {
                let t = b["type"] as? String ?? "?"
                order.append(t)
                if t == "thinking", (b["signature"] as? String)?.isEmpty == false { replayedSig = true }
            }
        }
        let ok = kinds1.contains("reasoning") && sigLen > 0 && parallel >= 2 && replayedSig
            && order.firstIndex(of: "thinking").map { i in order.firstIndex(of: "tool_use").map { i < $0 } ?? false } == true
            && final.contains("5") && final.contains("9")
        return (ok, "round1=\(kinds1) sigBytes=\(sigLen) parallelCalls=\(parallel) replayedAssistantBlocks=\(order) signatureInRequest=\(replayedSig) final=\"\(final.prefix(60))\"")
    }
}

// MARK: S5
public func s5Cancel(_ p: Provider) async -> Result {
    await time("S5", "cancel") {
        let s = LanguageModelSession(model: p.model)
        let snaps = Locked(0)
        let task = Task {
            for try await _ in s.streamResponse(to: "Count from 1 to 2000, one number per line. [long]") { snaps.with { $0 += 1 } }
        }
        // Cancel 1s after content starts; a reasoning model may think for a long time first, so give up
        // waiting after 8s and cancel mid-reasoning instead (reported as snapshotsBeforeCancel=0).
        let started = ContinuousClock.now
        while snaps.with({ $0 }) == 0, ContinuousClock.now - started < .seconds(8) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .seconds(1))
        let before = snaps.with { $0 }
        let t0 = ContinuousClock.now
        task.cancel()
        _ = await task.result
        let stopMs = (ContinuousClock.now - t0).ms
        var serverSaw = "n/a(external)"
        try await Task.sleep(for: .milliseconds(500))   // isResponding clears just after the task ends; mock notices on its next write (<=100ms tick)
        if let m = p.mock {
            serverSaw = "\(m.abortedStreams > 0)"
        }
        let ok = (before > 0 || p.mock == nil) && stopMs < 500 && !s.isResponding && (serverSaw != "false")
        return (ok, "snapshotsBeforeCancel=\(before) stoppedIn=\(stopMs)ms isResponding=\(s.isResponding) serverSawAbort=\(serverSaw)")
    }
}

public func runAll(_ p: Provider, checkpoint: URL, only: Set<String> = []) async -> [Result] {
    var out: [Result] = []
    func want(_ id: String) -> Bool { only.isEmpty || only.contains(id) }
    if want("S1") { out.append(await s1Stream(p)) }
    if want("S2") { out.append(await s2ToolRoundTrip(p)) }
    if want("S3") { out.append(await s3LoopControl(p, checkpoint: checkpoint)) }
    if want("S4") { out.append(await s4Approval(p)) }
    if want("S5") { out.append(await s5Cancel(p)) }
    if only.contains("S6") { out.append(await s6Continuity(p)) }  // opt-in: --only S6
    return out
}

extension Duration {
    var ms: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

extension Transcript.Entry {
    var kind: String {
        switch self {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .reasoning: "reasoning"
        case .response: "response"
        }
    }
}
