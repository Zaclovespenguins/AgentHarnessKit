import AgentHarnessKit
@testable import AgentHarnessKitALM
import AnyLanguageModel
import Foundation
import Testing

private struct AddParams: Codable, SchemaProviding {
    // swiftlint:disable identifier_name
    let a: Int
    let b: Int
    // swiftlint:enable identifier_name

    static var jsonSchema: JSONSchema {
        addTool.parametersSchema
    }
}

private struct AddOutput: Codable {
    let sum: Int
}

private func makeAgent(_ server: MockServer) throws -> Agent<EmptyContext> {
    let add = try Tool<AddParams, AddOutput, EmptyContext>(
        name: "add", description: "Add two integers and return the sum.",
        executor: { params, _ in AddOutput(sum: params.a + params.b) }
    )
    return Agent(client: mockClient(server), tools: [add])
}

private func enqueueAddThenFinish(_ server: MockServer) {
    server.enqueue(.toolCall(id: "call_1", name: "add", arguments: #"{"a":2,"b":3}"#), .usage(input: 20, output: 5))
    server.enqueue(
        .toolCall(id: "call_2", name: "finish", arguments: #"{"content":"The sum is 5."}"#),
        .usage(input: 30, output: 6)
    )
}

/// The whole stack on the mock: Agent loop -> HarnessModelClient -> ALM -> HTTP.
@Suite(.serialized)
struct AgentOverAdapterTests {
    @Test func runExecutesTheToolAndFinishes() async throws {
        let server = try MockServer()
        enqueueAddThenFinish(server)
        let result = try await makeAgent(server).run(userMessage: "What is 2 + 3?", context: EmptyContext())

        #expect(result.content == "The sum is 5.")
        #expect(result.finishReason == .completed)
        #expect(result.iterations == 2)
        #expect(result.totalTokenUsage.input == 50)
        #expect(server.requestCount == 2)
        let first = server.requestJSON(0)["tools"] as? [[String: Any]] ?? []
        let names = first.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(Set(names) == ["add", "finish"])
        let sent = server.requestJSON(1)["messages"] as? [[String: Any]] ?? []
        #expect(sent.last?["role"] as? String == "tool")
        #expect(jsonObject(sent.last?["content"] as? String ?? "") == ["sum": 5])
    }

    @Test func streamExecutesTheToolAndFinishes() async throws {
        let server = try MockServer()
        enqueueAddThenFinish(server)
        var kinds: [String] = []
        var finishedContent: String?
        var toolResult: String?
        for try await event in try makeAgent(server).stream(userMessage: "What is 2 + 3?", context: EmptyContext()) {
            switch event.kind {
            case .toolCallStarted: kinds.append("started")
            case let .toolCallCompleted(_, name, result):
                kinds.append("completed:\(name)")
                toolResult = result.content
            case .iterationCompleted: kinds.append("iteration")
            case let .finished(_, content, _, _):
                kinds.append("finished")
                finishedContent = content
            default: break
            }
        }

        #expect(kinds == ["started", "iteration", "completed:add", "iteration", "finished"])
        #expect(jsonObject(toolResult ?? "") == ["sum": 5])
        #expect(finishedContent == "The sum is 5.")
        #expect(server.requestCount == 2)
    }
}
