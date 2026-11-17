# v0.2 task breakdown

Sub-tasks for the four items in `ROADMAP_V0.2.md` (on branch `docs/roadmap-v0.2`, commit `d119967`), plus the release checklist. Each task is sized for one Haiku agent: one or two files, a fixed design, and a command that proves it is done.

| File | Roadmap section | Tasks |
|------|-----------------|-------|
| [01-partial-history-after-cancel.md](01-partial-history-after-cancel.md) | 1. Partial history after Cancel | 1.0 – 1.8 |
| [02-terminal-answer-handling.md](02-terminal-answer-handling.md) | 2. Terminal-answer handling | 2.0 – 2.6 |
| [03-history-summarizer.md](03-history-summarizer.md) | 3. Generic "summarize this history" helper | 3.0 (gate), 3.1 – 3.7 |
| [04-queued-approval-handler.md](04-queued-approval-handler.md) | 4. Queued approval handler | 4.0 – 4.8 |
| [05-release.md](05-release.md) | Order and dependencies, Definition of done | 5.1 – 5.7 |

## Run order

Roadmap order is 2, 1, 4, then 3 if the gate says yes. Within a file, tasks are numbered in dependency order; each task lists `Depends on`. Tasks with no shared dependency can run in parallel (marked **parallel-safe**).

```
02: 2.0 ─► 2.1 ─► 2.2 ─┬─► 2.3 ─┐
                        ├─► 2.4 ─┼─► 2.6
                        └─► 2.5 ─┘
01: 1.0 ─► 1.1 ─► 1.2 ─► 1.3 ─► 1.4 ─┬─► 1.5 ─┐
                                      ├─► 1.6 ─┼─► 1.8
                                      └─► 1.7 ─┘   (1.7 also needs 4.3)
04: 4.0 ─► 4.1 ─► 4.2 ─► 4.3 ─┬─► 4.4 … 4.7 ─► 4.8
03: 3.0 (human gate) ─► 3.1 … 3.7  or  close
05: after 01, 02, 04 (and 03 if built)
```

## Rules for every task

1. Work on the branch you are given. Read every file listed under **Read first** before editing.
2. Behavior is governed by `AGENTHARNESSKIT_PARITY_SPEC.md`. A task that changes behavior updates the spec in the same commit; the tasks that do this say so.
3. Swift 6.3, strict concurrency, swift-testing (`import Testing`, `@Test`, `#expect`). Follow the style of neighbouring files; no new dependencies.
4. Core target (`Sources/AgentHarnessKit`) stays Foundation-only. Nothing new may require `Observation`; `AgentStream` is already gated with `#if canImport(Observation)`.
5. Done means all of these pass locally:
   - `swift build`
   - `swift test --filter <the suite named in the task>`
   - `swift test` (whole suite, so you did not break neighbours)
   - `make format-check lint` if `mint` is installed; otherwise say in your report that it was not run.
6. Report back: files changed, tests added, the exact commands run and their result, and anything you could not do. Never mark a step done that you did not run. If a step in the task turns out to be wrong for the code as it stands, stop and report instead of improvising a different design.
7. `CHANGELOG.md` has no Unreleased section yet; the first task that needs one adds `## Unreleased` at the top.
8. Out of scope for every task: UI types, `@Observable` state outside `AgentStream`, new provider options, anything in the v0.1 Deferred list.

## Inputs a human must supply

- **3.0**: the decision gate for item 3 (and, if yes, the app's `ManualCompactionService` source and bridge format).
- **5.6**: the consuming app's deletions are in the app repository, not this one.
- **5.7**: tagging `v0.2.0`.
