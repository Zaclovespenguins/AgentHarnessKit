import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// Converts one ALM response (text + generated transcript entries + usage) into core types.
enum ResponseMapping {
    /// All-zero usage means the provider reported nothing: returns nil, never a zero `TokenUsage`.
    static func tokenUsage(from usage: LanguageModelSession.Usage) -> TokenUsage? {
        let inputTotal = max(usage.input.totalTokenCount, 0)
        let cached = max(usage.input.cachedTokenCount, 0)
        let outputTotal = max(usage.output.totalTokenCount, 0)
        let reasoning = max(usage.output.reasoningTokenCount, 0)
        guard inputTotal > 0 || cached > 0 || outputTotal > 0 || reasoning > 0 else {
            return nil
        }
        return TokenUsage(
            input: inputTotal,
            output: outputTotal,
            reasoning: reasoning,
            cacheRead: cached > 0 ? cached : nil
        )
    }

    /// Replay state for one assistant turn, or nil when `substrate` is nil or `entries` has no
    /// `.reasoning` entry. Payload: `.object([TranscriptMapping.continuityEntriesKey: <entries as JSON>])`.
    static func continuity(
        entries: [Transcript.Entry],
        substrate: ReplaySubstrate?
    ) throws -> AssistantContinuity? {
        guard let substrate, entries.contains(where: {
            if case .reasoning = $0 {
                true
            } else {
                false
            }
        }) else {
            return nil
        }
        let data: Data
        let value: AgentHarnessKit.JSONValue
        do {
            data = try JSONEncoder().encode(entries)
            value = try JSONDecoder().decode(AgentHarnessKit.JSONValue.self, from: data)
        } catch {
            throw AgentError.llmError(.encodingFailed(description: String(describing: error)))
        }
        return AssistantContinuity(
            substrate: substrate,
            payload: .object([TranscriptMapping.continuityEntriesKey: value])
        )
    }

    static func assistantMessage(
        content: String,
        entries: [Transcript.Entry],
        usage: LanguageModelSession.Usage,
        replaySubstrate: ReplaySubstrate?
    ) throws -> AssistantMessage {
        var toolCalls: [ToolCall] = []
        var reasoningText = ""
        var reasoningSeen = false
        var reasoningSignature: String?
        var responseText = ""

        for entry in entries {
            switch entry {
            case let .toolCalls(calls):
                for call in calls {
                    toolCalls.append(ToolCall(
                        id: call.id,
                        name: call.toolName,
                        arguments: call.arguments.jsonString,
                        kind: .function
                    ))
                }
            case let .reasoning(reasoning):
                reasoningSeen = true
                reasoningText += text(of: reasoning.segments)
                if let signature = reasoning.signature {
                    reasoningSignature = String(bytes: signature, encoding: .utf8)
                }
            case let .response(response):
                responseText += text(of: response.segments)
            case .instructions, .prompt, .toolOutput:
                break
            }
        }

        let reasoning = reasoningSeen
            ? ReasoningContent(content: reasoningText, signature: reasoningSignature)
            : nil

        return try AssistantMessage(
            content: content.isEmpty ? responseText : content,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage(from: usage),
            reasoning: reasoning,
            reasoningDetails: nil,
            continuity: continuity(entries: entries, substrate: replaySubstrate)
        )
    }

    /// Concatenates the text segments, skipping structured and image segments.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.reduce(into: "") { result, segment in
            if case let .text(textSegment) = segment {
                result += textSegment.content
            }
        }
    }
}
