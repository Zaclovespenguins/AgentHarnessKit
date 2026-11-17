import Foundation

/// Head/tail truncation of oversized tool results.
enum ToolResultTruncation {
    private static let toolResultTruncationMarkers = [
        "\n\n...[truncated]...\n\n",
        "...[truncated]...",
        "[truncated]",
        "...",
    ]

    static func truncateToolResult(_ content: String, maxCharacters: Int?) -> String {
        guard let max = maxCharacters else { return content }
        guard max > 0 else { return "" }
        guard content.count > max else { return content }
        let marker = Self.toolResultTruncationMarkers.first { $0.count <= max } ?? String(repeating: ".", count: max)
        guard marker.count < max else { return marker }
        let contentBudget = max - marker.count
        let headBudget = contentBudget * 3 / 5
        let tailBudget = contentBudget - headBudget
        return "\(content.prefix(headBudget))\(marker)\(content.suffix(tailBudget))"
    }

    static func truncateToolResult(_ result: ToolResult, maxCharacters: Int?) -> ToolResult {
        ToolResult(
            content: truncateToolResult(result.content, maxCharacters: maxCharacters),
            isError: result.isError
        )
    }
}
