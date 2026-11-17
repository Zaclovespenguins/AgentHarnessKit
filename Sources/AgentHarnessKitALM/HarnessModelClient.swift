import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// The stateless `LLMClient` seam over AnyLanguageModel: one ALM request per call, tools declared
/// but never executed. See docs/ARCHITECTURE.md sections 1-3.
public struct HarnessModelClient<Model: LanguageModel>: ToolCallSurfacingClient {
    public let model: Model
    public let providerIdentifier: ProviderIdentifier
    public let contextWindowSize: Int?
    /// When set, reasoning turns are preserved in `AssistantMessage.continuity` and replayed verbatim.
    public let replaySubstrate: ReplaySubstrate?
    public let options: GenerationOptions

    public init(
        model: Model,
        providerIdentifier: ProviderIdentifier,
        contextWindowSize: Int? = nil,
        replaySubstrate: ReplaySubstrate? = nil,
        options: GenerationOptions = GenerationOptions()
    ) {
        self.model = model
        self.providerIdentifier = providerIdentifier
        self.contextWindowSize = contextWindowSize
        self.replaySubstrate = replaySubstrate
        self.options = options
    }

    public func generate(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        responseFormat: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        let model = model
        let options = options
        let replaySubstrate = replaySubstrate
        let providerIdentifier = providerIdentifier
        do {
            let transcript = try TranscriptMapping.transcript(from: messages, replaySubstrate: replaySubstrate)
            let almTools = try ToolBridging.almTools(from: tools)
            let session = LanguageModelSession(model: model, tools: almTools, transcript: transcript)
            session.toolExecutionDelegate = StopDelegate()
            var opts = options
            try ProviderOptions.apply(requestContext, modelType: Model.self, to: &opts)
            do {
                if let responseFormat {
                    let response = try await model.respond(
                        within: session,
                        to: Prompt(""),
                        schema: try ToolBridging.generationSchema(from: responseFormat.schema),
                        includeSchemaInPrompt: false,
                        options: opts
                    )
                    return try ResponseMapping.assistantMessage(
                        content: response.rawContent.jsonString,
                        entries: Array(response.transcriptEntries),
                        usage: response.usage,
                        replaySubstrate: replaySubstrate
                    )
                }
                let response = try await model.respond(
                    within: session,
                    to: Prompt(""),
                    generating: String.self,
                    includeSchemaInPrompt: false,
                    options: opts
                )
                return try ResponseMapping.assistantMessage(
                    content: response.content,
                    entries: Array(response.transcriptEntries),
                    usage: response.usage,
                    replaySubstrate: replaySubstrate
                )
            } catch let stopped as LanguageModelSession.ToolExecutionStopped {
                // Stopping for tool calls is the normal outcome; the calls are returned unexecuted.
                return try ResponseMapping.assistantMessage(
                    content: "",
                    entries: Array(stopped.transcriptEntries),
                    usage: zeroUsage(),
                    replaySubstrate: replaySubstrate
                )
            }
        } catch {
            throw ErrorMapping.agentError(from: error, provider: providerIdentifier)
        }
    }

    public func stream(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let inner = streamForRun(messages: messages, tools: tools, requestContext: requestContext)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in inner {
                        if case .delta(let delta) = element {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like `stream`, plus one `.finalizedContinuity` before the terminal `.finished` delta when
    /// the turn has replay state.
    package func streamForRun(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<RunStreamElement, Error> {
        let model = model
        let options = options
        let replaySubstrate = replaySubstrate
        let providerIdentifier = providerIdentifier
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcript = try TranscriptMapping.transcript(from: messages, replaySubstrate: replaySubstrate)
                    let almTools = try ToolBridging.almTools(from: tools)
                    let session = LanguageModelSession(model: model, tools: almTools, transcript: transcript)
                    session.toolExecutionDelegate = StopDelegate()
                    var opts = options
                    try ProviderOptions.apply(requestContext, modelType: Model.self, to: &opts)

                    var mapper = StreamDeltaMapper()
                    var lastEntries: [Transcript.Entry] = []
                    var lastUsage = zeroUsage()
                    do {
                        for try await snapshot in model.streamResponse(
                            within: session,
                            to: Prompt(""),
                            generating: String.self,
                            includeSchemaInPrompt: false,
                            options: opts
                        ) {
                            for delta in mapper.deltas(
                                content: snapshot.content,
                                entries: Array(snapshot.transcriptEntries)
                            ) {
                                continuation.yield(.delta(delta))
                            }
                            lastEntries = Array(snapshot.transcriptEntries)
                            lastUsage = snapshot.usage
                        }
                    } catch let stopped as LanguageModelSession.ToolExecutionStopped {
                        // Stopped for tool calls: the final entries include the unexecuted calls.
                        lastEntries = Array(stopped.transcriptEntries)
                    }
                    try Task.checkCancellation()

                    for delta in StreamDeltaMapper.toolCallDeltas(entries: lastEntries) {
                        continuation.yield(.delta(delta))
                    }
                    if let continuity = try ResponseMapping.continuity(
                        entries: lastEntries,
                        substrate: replaySubstrate
                    ) {
                        continuation.yield(.finalizedContinuity(continuity))
                    }
                    continuation.yield(.delta(.finished(usage: ResponseMapping.tokenUsage(from: lastUsage))))
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        let agentError = ErrorMapping.agentError(from: error, provider: providerIdentifier)
                        continuation.finish(throwing: agentError)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Returns every tool call to the harness unexecuted.
private struct StopDelegate: ToolExecutionDelegate {
    func toolCallDecision(
        for toolCall: Transcript.ToolCall,
        in session: LanguageModelSession
    ) async -> ToolExecutionDecision {
        .stop
    }
}

/// All-zero usage; `ResponseMapping.tokenUsage` maps it to nil.
private func zeroUsage() -> LanguageModelSession.Usage {
    LanguageModelSession.Usage(
        input: .init(totalTokenCount: 0, cachedTokenCount: 0),
        output: .init(totalTokenCount: 0, reasoningTokenCount: 0)
    )
}

extension HarnessModelClient: RunStreamingClient {}
