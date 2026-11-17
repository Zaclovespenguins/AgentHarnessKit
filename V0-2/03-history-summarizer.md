# 3. Generic "summarize this history" helper — sub-tasks (conditional)

**Roadmap goal:** either ship `summarize(history:using:)` in `AgentHarnessKitContext` so the app can delete `ManualCompactionService`, or close the item as won't-do.

**State of the tree:** Phase 4b already shipped. `Sources/AgentHarnessKitContext/HierarchicalContextStore.swift` and the reserved `compress` tool exist (v0.1.0). The gate is therefore about the consuming app: does it adopt `HierarchicalContextStore` soon, or stay on Option A without it for a while?

---

## 3.0 Decision gate (human, not an agent task)

- **Owner:** project maintainer.
- **Question:** is the app staying on Option A without `HierarchicalContextStore` for a while?
  - **No** → do 3.7a only and stop.
  - **Yes** → supply the inputs below, then run 3.1 – 3.7b.
- **Inputs needed for "Yes":** the app's `ManualCompactionService` source (paste into `V0-2/inputs/ManualCompactionService.swift`), the bridge format it mirrors, and the summary prompt text it uses. A Haiku agent cannot infer these.

## 3.1 Expose the existing truncation to the Context target

- **Depends on:** 3.0 = Yes.
- **Read first:** `Sources/AgentHarnessKit/Core/AgentLoop/ToolResultTruncation.swift` (internal `enum ToolResultTruncation`, head/tail "middle-out").
- **Do:** change `ToolResultTruncation` and its two `truncateToolResult` functions from internal to `package`. No behavior change.
- **Done when:** `swift test --filter ChatToolResultTruncationTests` green.

## 3.2 Summarizer API skeleton

- **Depends on:** 3.1.
- **Read first:** `Sources/AgentHarnessKit/LLM/LLMClient.swift`, `Sources/AgentHarnessKitContext/ContextModel.swift`, `V0-2/inputs/ManualCompactionService.swift`.
- **Do:** create `Sources/AgentHarnessKitContext/HistorySummarizer.swift`:

  ```swift
  /// Transitional: replaced by `HierarchicalContextStore` + `compress`. See docs/ARCHITECTURE.md.
  public struct HistorySummaryOptions: Sendable {
      public var maxToolResultCharacters: Int
      public var instructions: String          // default = app's prompt text from inputs
  }
  public func summarize(
      history: [ChatMessage],
      using client: any LLMClient,
      options: HistorySummaryOptions = .init()
  ) async throws -> ChatMessage
  ```

  Body may `fatalError("TODO 3.3")` for now.
- **Done when:** `swift build` passes.

## 3.3 Build the summary request

- **Depends on:** 3.2.
- **Do:**
  - Copy `history`; truncate each `.tool` result with `ToolResultTruncation.truncateToolResult(_, maxCharacters:)`.
  - Render to the bridge format from the inputs (a pure function `renderForSummary(_:) -> String`, unit-testable).
  - Send one `client.generate` call: system = `options.instructions`, user = rendered text, no tools.
  - Return the assistant text as a `ChatMessage` (role and wrapper per the bridge format). Never mutate or return `history`.
- **Done when:** `swift build` passes.

## 3.4 Tests: trimming and bridge format

- **Depends on:** 3.3. **Parallel-safe** with 3.5.
- **Do:** `Tests/AgentHarnessKitContextTests/HistorySummarizerTests.swift` with `TestLLMClient`: oversized tool output is trimmed with the existing marker; `renderForSummary` matches a golden string from the app's format; the request has no tools; the input array is unchanged after the call.
- **Done when:** `swift test --filter HistorySummarizerTests` green.

## 3.5 Test: history fits the window after summarizing

- **Depends on:** 3.3. **Parallel-safe** with 3.4.
- **Do:** build a synthetic history over a fake window (reuse helpers in `Tests/AgentHarnessKitContextTests/Fixtures.swift`), summarize, splice `[system, summary, lastUserMessage]`, and assert the token estimate the Context target already uses is under the window and the spliced history passes `validateForLLMRequest()`.
- **Done when:** test green.

## 3.6 Error mapping

- **Depends on:** 3.4.
- **Do:** client errors surface as the same `AgentError.llmError` the loop uses; an empty model reply throws a clear error instead of returning an empty message. Add one test each.
- **Done when:** `swift test --filter HistorySummarizerTests` green.

## 3.7a Close as won't-do (gate = No)

- **Do:** add to `docs/ARCHITECTURE.md` section 4b: "v0.2 item 3 (history summarizer): not built. `HierarchicalContextStore` with the `compress` tool covers manual compaction; the app migrates to it instead." Add one line to `CHANGELOG.md` Unreleased under Notes.
- **Done when:** docs diff only.

## 3.7b Record and document (gate = Yes)

- **Depends on:** 3.4 – 3.6.
- **Do:** `docs/ARCHITECTURE.md` section 4b records the decision and labels `summarize(history:using:)` transitional; `CHANGELOG.md` Unreleased entry.
- **Done when:** `swift test` green.

**Section exit:** decision recorded in `docs/ARCHITECTURE.md`; either the helper ships and the app deletes `ManualCompactionService`, or the item is closed.
