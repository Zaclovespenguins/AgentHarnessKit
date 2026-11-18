import AgentHarnessKit
import Foundation

/// A run of stored messages that a `compress` call for this session would accept today.
public struct CompressibleRange: Sendable, Equatable {
    public let startRef: MessageRef
    /// Inclusive.
    public let endRef: MessageRef
    /// The covered messages, in ref order.
    public let messages: [ChatMessage]
    /// `ContextTokens` estimate for `messages`: the sum of their stored token estimates.
    public let tokens: Int

    public init(startRef: MessageRef, endRef: MessageRef, messages: [ChatMessage], tokens: Int) {
        self.startRef = startRef
        self.endRef = endRef
        self.messages = messages
        self.tokens = tokens
    }
}
