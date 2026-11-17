import Foundation

/// A client that streams agent-loop run elements directly, instead of plain deltas.
package protocol RunStreamingClient: LLMClient {
    func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<RunStreamElement, Error>
}

extension LLMClient {
    func runStream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        if let capableClient = self as? any RunStreamingClient {
            return capableClient.streamForRun(
                messages: messages,
                tools: tools,
                requestContext: requestContext
            )
        }
        return wrapRunStream(stream(messages: messages, tools: tools, requestContext: requestContext))
    }
}

private func wrapRunStream(
    _ stream: AsyncThrowingStream<StreamDelta, Error>
) -> AsyncThrowingStream<RunStreamElement, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await delta in stream {
                    continuation.yield(.delta(delta))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}
