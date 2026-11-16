import Foundation

/// Identifies a folded block of conversation history held by a context store.
public struct ContextBlockID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }
}

/// Payload of `StreamEvent.Kind.contextFolded`: history ranges were replaced by summary blocks.
public struct ContextFold: Sendable, Equatable, Codable {
    /// The blocks created by this fold, in creation order.
    public let blockIDs: [ContextBlockID]
    /// Approximate tokens removed from the live context by this fold.
    public let tokensSaved: Int

    public init(blockIDs: [ContextBlockID], tokensSaved: Int) {
        self.blockIDs = blockIDs
        self.tokensSaved = tokensSaved
    }
}

/// Payload of `StreamEvent.Kind.contextRestored`: a folded block was expanded back into the live context.
public struct ContextRestore: Sendable, Equatable, Codable {
    public let blockID: ContextBlockID
    /// Approximate tokens added back to the live context by this restore.
    public let tokensRestored: Int

    public init(blockID: ContextBlockID, tokensRestored: Int) {
        self.blockID = blockID
        self.tokensRestored = tokensRestored
    }
}

/// Payload of `StreamEvent.Kind.contextStatus`: a snapshot of context-window usage.
public struct ContextStatus: Sendable, Equatable, Codable {
    /// The model's context window size in tokens.
    public let windowSize: Int
    /// Tokens currently occupied in the live context.
    public let usedTokens: Int
    /// Number of folded blocks currently held by the context store.
    public let blockCount: Int

    public init(windowSize: Int, usedTokens: Int, blockCount: Int) {
        self.windowSize = windowSize
        self.usedTokens = usedTokens
        self.blockCount = blockCount
    }

    /// Fraction of the window in use; 0 when the window size is not positive.
    public var utilization: Double {
        windowSize > 0 ? Double(usedTokens) / Double(windowSize) : 0
    }

    /// Tokens left in the window, floored at 0.
    public var remainingTokens: Int {
        max(0, windowSize - usedTokens)
    }
}
