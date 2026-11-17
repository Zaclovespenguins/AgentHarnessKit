import Foundation

extension Agent {
    func executeResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage], sessionID: SessionID,
        approvalHandler: ToolApprovalHandler? = nil, allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        let contextResults = try await executeContextCalls(
            calls.filter { isContextCall($0.call) }, sessionID: sessionID, emit: nil
        )
        let userResults = try await executeUserResults(
            calls.filter { !isContextCall($0.call) }, context: context, messages: messages,
            approvalHandler: approvalHandler, allowlist: &allowlist
        )
        return (contextResults + userResults).sorted { $0.index < $1.index }
    }

    func executeStreamingResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage], sessionID: SessionID,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)
        let contextResults = try await executeContextCalls(
            calls.filter { isContextCall($0.call) }, sessionID: sessionID, emit: emit
        )
        let userResults = try await executeUserStreamingResults(
            calls.filter { !isContextCall($0.call) }, context: context, messages: messages,
            options: options, continuation: continuation, allowlist: &allowlist
        )
        return (contextResults + userResults).sorted { $0.index < $1.index }
    }

    /// Reserved context tools are executed by the context store, never looked up among user tools or approved.
    func isContextCall(_ call: ToolCall) -> Bool {
        configuration.contextStore?.toolDefinitions.contains { $0.name == call.name } ?? false
    }

    private func executeContextCalls(
        _ calls: [IndexedToolCall], sessionID: SessionID, emit: StreamEmitter?
    ) async throws -> [IndexedToolResult] {
        guard let store = configuration.contextStore else { return [] }
        var results: [IndexedToolResult] = []
        for indexed in calls {
            let outcome = try await store.executeTool(indexed.call, sessionID: sessionID)
            emit?.yield(.toolCallCompleted(id: indexed.call.id, name: indexed.call.name, result: outcome.result))
            for kind in outcome.events {
                emit?.yield(kind)
            }
            results.append(IndexedToolResult(index: indexed.index, call: indexed.call, result: outcome.result))
        }
        return results
    }

    private func executeUserResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage],
        approvalHandler: ToolApprovalHandler? = nil, allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        guard !calls.isEmpty else { return [] }
        let executionContext = try context.withParentHistory(messages.resolvedPrefixForInheritance())

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            return try await executeIndexedCalls(
                calls,
                context: executionContext,
                approvalHandler: approvalHandler
            )
        }

        let (autoExecute, needsApproval) = partitionCallsRequiringApproval(calls, allowlist: allowlist)
        var allResults = try await executeIndexedCalls(autoExecute, context: executionContext, approvalHandler: handler)

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, allowlist: &allowlist
        )
        try Task.checkCancellation()

        allResults.append(contentsOf: denied.map(truncatedIndexedToolResult))
        try await allResults.append(contentsOf: executeIndexedCalls(
            approved,
            context: executionContext,
            approvalHandler: handler
        ))
        return allResults.sorted { $0.index < $1.index }
    }

    private func executeUserStreamingResults(
        _ calls: [IndexedToolCall], context: C, messages: [ChatMessage],
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        allowlist: inout Set<String>
    ) async throws -> [IndexedToolResult] {
        guard !calls.isEmpty else { return [] }
        let executionContext = try context.withParentHistory(messages.resolvedPrefixForInheritance())
        let approvalHandler = options.approvalHandler
        let emit = StreamEmitter(factory: options.eventFactory, continuation: continuation)

        guard let handler = approvalHandler, configuration.approvalPolicy != .none else {
            return try await executeIndexedStreamingCalls(
                calls,
                context: executionContext,
                options: options,
                continuation: continuation
            )
        }

        let (autoExecute, needsApproval) = partitionCallsRequiringApproval(calls, allowlist: allowlist)
        var allResults = try await executeIndexedStreamingCalls(
            autoExecute,
            context: executionContext,
            options: options,
            continuation: continuation
        )

        let (approved, denied) = try await resolveApprovals(
            needsApproval, handler: handler, emit: emit, allowlist: &allowlist
        )
        try Task.checkCancellation()

        for entry in denied {
            let truncatedEntry = truncatedIndexedToolResult(entry)
            emit.yield(.toolCallCompleted(
                id: truncatedEntry.call.id, name: truncatedEntry.call.name, result: truncatedEntry.result
            ))
            allResults.append(truncatedEntry)
        }

        try await allResults.append(contentsOf: executeIndexedStreamingCalls(
            approved,
            context: executionContext,
            options: options,
            continuation: continuation
        ))
        return allResults.sorted { $0.index < $1.index }
    }

    func appendToolResults(_ results: [IndexedToolResult], messages: inout [ChatMessage]) {
        for entry in results {
            messages.append(.tool(id: entry.call.id, name: entry.call.name, content: entry.result.content))
        }
    }

    private func partitionCallsRequiringApproval(
        _ calls: [IndexedToolCall],
        allowlist: Set<String>
    ) -> (autoExecute: [IndexedToolCall], needsApproval: [IndexedToolCall]) {
        var autoExecute: [IndexedToolCall] = []
        var needsApproval: [IndexedToolCall] = []
        for indexed in calls {
            if requiresApproval(indexed.call, allowlist: allowlist) {
                needsApproval.append(indexed)
            } else {
                autoExecute.append(indexed)
            }
        }
        return (autoExecute: autoExecute, needsApproval: needsApproval)
    }

    private func executeIndexedCalls(
        _ calls: [IndexedToolCall],
        context: C,
        approvalHandler: ToolApprovalHandler?
    ) async throws -> [IndexedToolResult] {
        let results = try await executeToolsInParallel(
            calls.map(\.call),
            context: context,
            approvalHandler: approvalHandler
        )
        return zip(calls, results).map { indexed, entry in
            IndexedToolResult(
                index: indexed.index,
                call: entry.call,
                result: truncatedToolResult(
                    entry.result,
                    toolName: entry.call.name,
                    tools: tools,
                    fallbackLimit: configuration.maxToolResultCharacters
                )
            )
        }
    }

    private func executeIndexedStreamingCalls(
        _ calls: [IndexedToolCall],
        context: C,
        options: InvocationOptions,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws -> [IndexedToolResult] {
        let results = try await executeToolsStreaming(
            calls.map(\.call),
            context: context,
            options: options,
            continuation: continuation
        )
        return zip(calls, results).map { indexed, entry in
            IndexedToolResult(
                index: indexed.index,
                call: entry.call,
                result: entry.result
            )
        }
    }

    private func truncatedIndexedToolResult(_ entry: IndexedToolResult) -> IndexedToolResult {
        IndexedToolResult(
            index: entry.index,
            call: entry.call,
            result: truncatedToolResult(
                entry.result,
                toolName: entry.call.name,
                tools: tools,
                fallbackLimit: configuration.maxToolResultCharacters
            )
        )
    }
}
