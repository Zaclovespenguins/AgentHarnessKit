import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// Converts core `ChatMessage` history into a per-request ALM `Transcript`.
enum TranscriptMapping {
    /// Key under which `AssistantContinuity.payload` (a JSON object) stores the JSON-encoded
    /// `[Transcript.Entry]` of one assistant turn, for verbatim replay.
    static let continuityEntriesKey = "almEntries"

    /// - Parameter replaySubstrate: the client's substrate. An assistant message whose
    ///   `continuity.substrate` equals it and whose payload has `continuityEntriesKey` is replayed
    ///   verbatim from those entries; otherwise the turn is rebuilt from semantic fields.
    static func transcript(
        from messages: [ChatMessage],
        replaySubstrate: ReplaySubstrate?
    ) throws -> Transcript {
        var entries: [Transcript.Entry] = []
        for message in messages {
            switch message {
            case let .system(text):
                entries.append(.instructions(.init(segments: [.text(.init(content: text))], toolDefinitions: [])))
            case let .user(text):
                entries.append(.prompt(.init(segments: [.text(.init(content: text))])))
            case let .userMultimodal(parts):
                entries.append(.prompt(.init(segments: try parts.map(segment(for:)))))
            case let .assistant(assistant):
                entries += try assistantEntries(assistant, replaySubstrate: replaySubstrate)
            case let .tool(id, name, content):
                entries.append(.toolOutput(.init(id: id, toolName: name, segments: [.text(.init(content: content))])))
            }
        }
        return Transcript(entries: entries)
    }

    private static func segment(for part: ContentPart) throws -> Transcript.Segment {
        switch part {
        case let .text(text):
            return .text(.init(content: text))
        case let .imageBase64(data, mimeType):
            return .image(.init(data: data, mimeType: mimeType))
        case let .imageURL(string):
            guard let url = URL(string: string), url.scheme != nil else {
                throw AgentError.llmError(.encodingFailed(description: "Image URL is not a valid URL: \(string)"))
            }
            return .image(.init(url: url))
        case .videoBase64:
            throw AgentError.llmError(.featureUnsupported(provider: "AnyLanguageModel", feature: "video input"))
        case .pdfBase64:
            throw AgentError.llmError(.featureUnsupported(provider: "AnyLanguageModel", feature: "pdf input"))
        case .audioBase64:
            throw AgentError.llmError(.featureUnsupported(provider: "AnyLanguageModel", feature: "audio input"))
        }
    }

    private static func assistantEntries(
        _ message: AssistantMessage,
        replaySubstrate: ReplaySubstrate?
    ) throws -> [Transcript.Entry] {
        if let replaySubstrate, let continuity = message.continuity,
           continuity.substrate == replaySubstrate,
           case let .object(payload) = continuity.payload,
           let stored = payload[continuityEntriesKey] {
            do {
                let data = try JSONEncoder().encode(stored)
                return try JSONDecoder().decode([Transcript.Entry].self, from: data)
            } catch {
                throw AgentError.llmError(.decodingFailed(
                    description: "Stored assistant transcript entries are invalid: \(error)"
                ))
            }
        }

        var entries: [Transcript.Entry] = []
        if let reasoning = message.reasoning {
            entries.append(.reasoning(.init(
                segments: [.text(.init(content: reasoning.content))],
                signature: reasoning.signature.map { Data($0.utf8) }
            )))
        }
        if !message.content.isEmpty {
            entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: message.content))])))
        }
        if !message.toolCalls.isEmpty {
            var calls: [Transcript.ToolCall] = []
            for call in message.toolCalls {
                calls.append(Transcript.ToolCall(
                    id: call.id,
                    toolName: call.name,
                    arguments: try arguments(call.arguments, tool: call.name)
                ))
            }
            entries.append(.toolCalls(Transcript.ToolCalls(calls)))
        }
        return entries
    }

    /// Model-produced arguments must be valid JSON. `GeneratedContent(json:)` would silently
    /// turn malformed text into a string, so validate first.
    private static func arguments(_ json: String, tool: String) throws -> GeneratedContent {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "{}" : trimmed
        do {
            _ = try JSONDecoder().decode(AgentHarnessKit.JSONValue.self, from: Data(source.utf8))
            return try GeneratedContent(json: source)
        } catch {
            throw AgentError.llmError(.decodingFailed(description: "Arguments for tool '\(tool)' are not valid JSON"))
        }
    }
}
