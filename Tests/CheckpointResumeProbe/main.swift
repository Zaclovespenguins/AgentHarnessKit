// Child process for CrossProcessResumeTests: runs one streamed iteration (an `echo` call approved
// with approveAlways), lets FileCheckpointer persist it, then exits when the second request starts
// (the loop saves the iteration checkpoint before issuing the next request).
// Prints the checkpoint ID on stdout. Usage: CheckpointResumeProbe <directory> <sessionUUID>
import AgentHarnessKit
import Foundation

struct EchoParams: Codable, SchemaProviding {
    let message: String
    static var jsonSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }
}

struct EchoOutput: Codable {
    let echoed: String
}

actor RequestCounter {
    var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

struct OneShotClient: LLMClient, ToolCallSurfacingClient {
    let providerIdentifier: ProviderIdentifier = .custom("CheckpointResumeProbe")
    let requests = RequestCounter()
    let onSecondRequest: @Sendable () async -> Never

    func generate(
        messages _: [ChatMessage], tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?, requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        throw AgentError.llmError(.other("probe only streams"))
    }

    func stream(
        messages _: [ChatMessage], tools _: [ToolDefinition], requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await requests.next() > 1 { await onSecondRequest() }
                continuation.yield(.toolCallStart(index: 0, id: "call_child", name: "echo", kind: .function))
                continuation.yield(.toolCallDelta(index: 0, arguments: #"{"message": "from child"}"#))
                continuation.yield(.finished(usage: TokenUsage(input: 10, output: 5)))
                continuation.finish()
            }
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let sessionUUID = UUID(uuidString: arguments[2]) else {
    FileHandle.standardError.write(Data("usage: CheckpointResumeProbe <directory> <sessionUUID>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let sessionID = SessionID(rawValue: sessionUUID)
let checkpointer = FileCheckpointer(directory: directory)
let echo = try Tool<EchoParams, EchoOutput, EmptyContext>(
    name: "echo", description: "Echoes input",
    executor: { params, _ in EchoOutput(echoed: params.message) }
)
let client = OneShotClient {
    let saved = await (try? checkpointer.list(session: sessionID)) ?? []
    guard saved.count == 1, let only = saved.first else { exit(3) }
    print(only.rawValue.uuidString)
    exit(0) // simulate the process dying mid-run
}

let agent = Agent<EmptyContext>(
    client: client, tools: [echo],
    configuration: AgentConfiguration(approvalPolicy: .allTools)
)
let stream = agent.stream(
    userMessage: "Echo something", context: EmptyContext(),
    approvalHandler: { _ in .approveAlways },
    sessionID: sessionID, checkpointer: checkpointer
)
for try await _ in stream {}
exit(4)
