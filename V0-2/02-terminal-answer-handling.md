# 2. Terminal-answer handling — sub-tasks

**Roadmap goal:** the loop keeps the `finish` answer in history as an assistant message, so the app can delete `TerminalAnswer.restore`.

**Where the bug is:** `sanitizedTerminalHistory()` in `Sources/AgentHarnessKit/Messages/ChatMessageHistory.swift:26`. When the last assistant message holds only a `finish` call, it removes the call, finds the message empty, and returns `dropLast()`, so the answer is lost. It is the single choke point for all terminal paths:

- `Sources/AgentHarnessKit/Core/AgentLoop/Agent+Run.swift:80` and `:180` (non-streaming)
- `Sources/AgentHarnessKit/Core/AgentLoop/Agent+StreamingLoop.swift:54` (streaming)
- `Sources/AgentHarnessKit/Core/Streaming/Agent+StreamEvents.swift:38` (`.finished` event history)

Existing tests that assert the current dropping behavior: `Tests/AgentHarnessKitTests/Messages/ChatMessageHistoryTests.swift:121, 136, 181, 227, 269`.

---

## 2.0 Write the restore rule into the spec

- **Depends on:** nothing. **Parallel-safe** with 1.0 and 4.0.
- **Read first:** `AGENTHARNESSKIT_PARITY_SPEC.md` section "Behavioral details that are easy to get wrong" (line ~195), `Sources/AgentHarnessKit/Core/AgentLoop/FinishArguments.swift`, `ChatMessageHistory.swift`.
- **Do:** add a bullet **Terminal answer in history** under that section with this rule:
  - After a built-in `finish` call ends the run, the returned history ends with one assistant message with no tool calls. Its text is:
    - the finish `content` if the assistant message's own text is empty;
    - the assistant text if the finish `content` is nil or empty;
    - the assistant text alone if the two are equal after trimming whitespace;
    - otherwise assistant text, a blank line, then finish `content`.
  - If both are empty, the message is dropped (current behavior).
  - Reasoning/continuity on the original assistant message is kept on the restored message.
  - The restored message is plain content, so it never counts as a second `finish` and never trips the single-finish rule.
  - A `completionTool` run is unchanged (its tool result is already in history).
- **Done when:** spec diff only; no code changes.

## 2.1 Make `sanitizedTerminalHistory` restore the answer

- **Depends on:** 2.0.
- **Read first:** `ChatMessageHistory.swift`, `Sources/AgentHarnessKit/Messages/AssistantMessage.swift` (`removingTerminalFinishTool`, `isEmptyAfterRemovingTerminalTools`), `FinishArguments.swift` (`decodeFinishArguments`).
- **Do:**
  - Change `sanitizedTerminalHistory()` to decode the finish call's arguments and build the restored assistant message per the 2.0 rule. Keep the existing `finishMustBeExclusive` throw.
  - If decoding fails, keep today's behavior (remove the call) rather than throwing a new error; the run already decoded the same arguments successfully before reaching here.
  - Keep the function `package` and its signature unchanged so the four call sites need no edits.
- **Do not:** touch the loop files.
- **Done when:** `swift build` passes. Existing tests may now fail; 2.2 fixes them.

## 2.2 Update and extend unit tests for the rule

- **Depends on:** 2.1.
- **Read first:** `Tests/AgentHarnessKitTests/Messages/ChatMessageHistoryTests.swift`.
- **Do:**
  - Update the five existing `sanitizedTerminalHistory` tests to expect the restored message where they used to expect the drop. Do not delete tests.
  - Add one test per branch of the rule: finish-only, finish plus different text, finish plus equal text, finish with nil content plus text, both empty, reasoning preserved.
  - Add a test that the restored history passes `validateForLLMRequest()` and `validateForAgentHistory()`.
- **Done when:** `swift test --filter ChatMessageHistoryTests` green.

## 2.3 Loop tests: non-streaming and streaming

- **Depends on:** 2.2. **Parallel-safe** with 2.4 and 2.5.
- **Read first:** `Sources/AgentHarnessKitTesting/TestLLMClient.swift`, `Tests/AgentHarnessKitTests/Core/AgentLoop/ContentOnlyTerminationTests.swift`, `Tests/AgentHarnessKitTests/Core/Streaming/AgentStreamingTests.swift`.
- **Do:** create `Tests/AgentHarnessKitTests/Core/AgentLoop/TerminalAnswerHistoryTests.swift` with, for both `agent.run` and `agent.stream` (read the `.finished` event's history):
  - finish-only turn → `result.history.last` is an assistant message with the finish content and no tool calls;
  - finish plus content → one message, text per rule;
  - `completionTool` run → history unchanged from today (regression guard).
- **Done when:** `swift test --filter TerminalAnswerHistoryTests` green.

## 2.4 Follow-up request contains the answer exactly once

- **Depends on:** 2.2. **Parallel-safe** with 2.3 and 2.5.
- **Read first:** `TestLLMClient.swift` (how recorded requests are exposed), `Tests/AgentHarnessKitALMTests/Support/MockServer.swift`, `Tests/AgentHarnessKitALMTests/AgentOverAdapterTests.swift`.
- **Do:**
  - In `TerminalAnswerHistoryTests.swift`: run turn 1 (finish-only), pass `result.history` into turn 2, and assert the recorded turn-2 request messages contain the finish content in exactly one message.
  - In `AgentOverAdapterTests.swift` add the same check over `MockServer`: count occurrences of the answer string in the second request body.
- **Done when:** both test files green on `swift test --filter "TerminalAnswerHistoryTests|AgentOverAdapterTests"`.

## 2.5 Checkpoint resume does not restore twice

- **Depends on:** 2.2. **Parallel-safe** with 2.3 and 2.4.
- **Read first:** `Sources/AgentHarnessKit/Core/Checkpointing/Agent+Checkpointing.swift`, `Agent+Resume.swift`, `Tests/AgentHarnessKitTests/Core/Checkpointing/AgentResumeTests.swift`.
- **Do:**
  - Check whether a checkpoint is written for the iteration that ended with `finish`, and whether that snapshot holds raw messages (with the `finish` call) or sanitized ones. Write the answer as a comment at the top of the new test.
  - Add tests to `AgentResumeTests.swift`: resume from the last checkpoint of a finish-only run, then (a) the `.finished` history holds the answer once, and (b) a follow-up turn's request holds it once.
  - If (a) or (b) fails, fix it at the point where resume re-emits history so sanitizing runs once on raw messages. Do not sanitize stored checkpoint data.
- **Done when:** `swift test --filter AgentResumeTests` green.

## 2.6 Docs and changelog

- **Depends on:** 2.3, 2.4, 2.5.
- **Do:** add an "Unreleased" entry in `CHANGELOG.md` ("Terminal `finish` answers are kept in history as an assistant message; consumers can drop their own restore step"). If `docs/ARCHITECTURE.md` section 5 describes terminal history, update it to match.
- **Done when:** `swift test` green; docs diff reviewed.

**Section exit:** all of the above green on macOS and Linux CI; the app deletes `TerminalAnswer.restore` (tracked in 5.6).
