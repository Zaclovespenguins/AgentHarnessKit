import AgentHarnessKit
import AnyLanguageModel
import Foundation

/// Turns ALM's cumulative stream snapshots into incremental `StreamDelta`s.
struct StreamDeltaMapper {
    /// Text already emitted as `.reasoning` deltas.
    private var emittedReasoning = ""
    /// Text already emitted as `.content` deltas.
    private var emittedContent = ""

    /// Feed each snapshot's cumulative text and cumulative transcript entries; returns only the new
    /// `.content` and `.reasoning` text. Never returns tool-call deltas.
    mutating func deltas(content: String, entries: [Transcript.Entry]) -> [StreamDelta] {
        var result: [StreamDelta] = []

        let reasoning = entries.reduce(into: "") { text, entry in
            guard case .reasoning(let reasoning) = entry else { return }
            for segment in reasoning.segments {
                if case .text(let textSegment) = segment {
                    text += textSegment.content
                }
            }
        }
        if let suffix = Self.suffix(of: reasoning, after: emittedReasoning) {
            emittedReasoning = reasoning
            result.append(.reasoning(suffix))
        }

        if let suffix = Self.suffix(of: content, after: emittedContent) {
            emittedContent = content
            result.append(.content(suffix))
        }

        return result
    }

    /// Returns the non-empty text that `new` adds after `old`, or nil if `new` does not strictly extend `old`.
    private static func suffix(of new: String, after old: String) -> String? {
        guard new.hasPrefix(old) else { return nil }
        let rest = new.dropFirst(old.count)
        return rest.isEmpty ? nil : String(rest)
    }

    // shortcut: tool-call arguments are not streamed incrementally because ALM snapshots are not
    // prefix-stable JSON; upgrade if a UI needs live argument streaming.
    /// Call once with the final entries: a `.toolCallStart` then one `.toolCallDelta` with the full
    /// arguments JSON per call, indexed in order across all `.toolCalls` entries.
    static func toolCallDeltas(entries: [Transcript.Entry]) -> [StreamDelta] {
        let calls = entries.flatMap { entry -> [Transcript.ToolCall] in
            guard case .toolCalls(let group) = entry else { return [] }
            return Array(group)
        }
        return calls.enumerated().flatMap { index, call in
            [
                StreamDelta.toolCallStart(index: index, id: call.id, name: call.toolName, kind: .function),
                StreamDelta.toolCallDelta(index: index, arguments: call.arguments.jsonString),
            ]
        }
    }
}
