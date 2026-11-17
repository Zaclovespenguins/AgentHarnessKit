import AgentHarnessKit
import Foundation

// TASK H2. Stubs return placeholder values; replace the bodies, keep the signatures.

public extension ContextPipeline {
    /// Refs the model may not compress. Union of:
    /// 1. every `.system` message;
    /// 2. the first and the last user-role message (`.user` or `.userMultimodal`);
    /// 3. the recent zone: the last `k` messages, where `k` is the larger of
    ///    `configuration.protectedRecentMessages` and the smallest suffix length whose token sum is
    ///    >= `configuration.protectedRecentTokens` (all messages if never reached). If the zone then starts
    ///    with `.tool` messages, extend it backwards to include the assistant message that issued those calls;
    /// 4. every assistant message with a call whose name is in `ContextToolName.all`, and every `.tool`
    ///    message whose name is in `ContextToolName.all`.
    static func protectedRefs(_ messages: [StoredMessage], configuration: ContextConfiguration) -> Set<MessageRef> {
        []
    }

    /// Maximal runs of consecutive refs that are neither protected nor in the `effectiveMessageRefs` of an
    /// active block, ascending. Each run is then trimmed so it does not start with a `.tool` message and does
    /// not end with an assistant message that has tool calls (repeat until stable); empty runs are dropped.
    static func compressibleRanges(
        _ messages: [StoredMessage],
        blocks: [ContextBlock],
        protected: Set<MessageRef>
    ) -> [ClosedRange<MessageRef>] {
        []
    }
}
