@testable import AgentHarnessKit
import Foundation
import Testing

/// Spike S3 pattern: a child process writes a checkpoint with FileCheckpointer and exits mid-run;
/// this process resumes it from a fresh FileCheckpointer on the same directory.
private final class BundleAnchor {}

private func probeExecutable() throws -> URL {
    let candidates = [
        Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent(),
        Bundle.main.bundleURL,
        Bundle.main.bundleURL.deletingLastPathComponent(),
    ]
    for directory in candidates {
        let url = directory.appending(path: "CheckpointResumeProbe")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    Issue.record("CheckpointResumeProbe not found next to the test bundle: \(candidates.map(\.path))")
    throw CancellationError()
}

private func runProbe(directory: URL, session: SessionID) throws -> CheckpointID {
    let process = Process()
    process.executableURL = try probeExecutable()
    process.arguments = [directory.path, session.rawValue.uuidString]
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    let output = String(bytes: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0)
    guard let uuid = UUID(uuidString: output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        Issue.record("probe printed no checkpoint id: \(output)")
        throw CancellationError()
    }
    return CheckpointID(rawValue: uuid)
}

private struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

private struct EchoOutput: Codable {
    let echoed: String
}

/// Counts approval prompts; the child's approveAlways must make this stay at zero.
private actor PromptCounter {
    var prompted = 0
    func increment() { prompted += 1 }
}

struct CrossProcessResumeTests {
    @Test
    func resumeContinuesCheckpointWrittenByAnotherProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ahk-cross-process-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionID()

        let checkpointID = try runProbe(directory: directory, session: session)

        let checkpointer = FileCheckpointer(directory: directory)
        let echo = try Tool<EchoParams, EchoOutput, EmptyContext>(
            name: "echo", description: "Echoes input",
            executor: { params, _ in EchoOutput(echoed: params.message) }
        )
        let client = StreamingMockLLMClient(streamSequences: [
            [
                .toolCallStart(index: 0, id: "call_parent", name: "echo", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"message": "from parent"}"#),
                .finished(usage: TokenUsage(input: 10, output: 5)),
            ],
            [
                .toolCallStart(index: 0, id: "call_finish", name: "finish", kind: .function),
                .toolCallDelta(index: 0, arguments: #"{"content": "done"}"#),
                .finished(usage: TokenUsage(input: 5, output: 5)),
            ],
        ])
        let agent = Agent<EmptyContext>(
            client: client, tools: [echo],
            configuration: AgentConfiguration(approvalPolicy: .allTools)
        )
        let prompts = PromptCounter()
        let stream = try await agent.resume(
            from: checkpointID, checkpointer: checkpointer, context: EmptyContext(),
            approvalHandler: { _ in
                await prompts.increment()
                return .deny(reason: "allowlist from the child process should have applied")
            }
        )

        var events: [StreamEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let first = try #require(events.first)
        #expect(first.origin == .replayed(from: checkpointID))
        guard case let .iterationCompleted(_, iteration, history) = first.kind else {
            Issue.record("first event should be the replayed iteration, got \(first.kind)")
            return
        }
        #expect(iteration == 1)
        #expect(history.contains { message in
            if case let .tool(id, _, content) = message { return id == "call_child" && content.contains("from child") }
            return false
        })
        #expect(await prompts.prompted == 0)
        guard case let .finished(_, content, _, _) = try #require(events.last).kind else {
            Issue.record("last event should be finished")
            return
        }
        #expect(content == "done")
        // Child saved iteration 1; the resumed run saved iteration 2 (the built-in finish is not checkpointed).
        let saved = try await FileCheckpointer(directory: directory).list(session: session)
        #expect(saved.count == 2)
        #expect(saved.first == checkpointID)
    }
}
