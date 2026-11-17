# Release v0.2 — sub-tasks

Covers the roadmap's "Order and dependencies" and "Definition of done" sections. Starts when 01, 02 and 04 are complete (and 03 if the gate said yes).

## 5.1 Spec and architecture consistency pass

- **Depends on:** 1.8, 2.6, 4.8 (and 3.7a or 3.7b).
- **Do:** read the v0.2 diffs to `AGENTHARNESSKIT_PARITY_SPEC.md` and `docs/ARCHITECTURE.md` together. Check that terminal-answer restore (2.0), partial history (1.0) and the approval queue (4.0) do not contradict each other, e.g. a cancelled parked approval yields the same synthetic text in both the queue section and the partial-history section. Fix wording only; report any real conflict instead of changing behavior.
- **Done when:** docs diff reviewed; no code changes.

## 5.2 Public API audit

- **Depends on:** 5.1. **Parallel-safe** with 5.3.
- **Do:** list every new `public` symbol added in v0.2 (`grep -rn "public" Sources` against `git diff v0.1.0`). Each needs a doc comment and a test that touches it. Write the list into the PR description; add missing doc comments.
- **Done when:** `swift build` passes; list attached.

## 5.3 Full local check

- **Depends on:** 5.1. **Parallel-safe** with 5.2.
- **Do:** run `make check` (format-check, lint, `swift test --parallel -Xswiftc -warnings-as-errors`) and `make acceptance`. Fix warnings introduced by v0.2 work only.
- **Done when:** all pass; paste the tail of each output in the report.

## 5.4 CI on macOS, Linux, iOS Simulator

- **Depends on:** 5.3.
- **Read first:** `.github/workflows/`, `docs/ARCHITECTURE.md` section 7 (platform status).
- **Do:** push the branch and confirm the macOS, Linux (`swift:6.3`) and iOS Simulator jobs pass, including the new mock-server tests on iOS. If a job fails, fix and push; do not skip or disable tests.
- **Done when:** all three jobs green; record run links in the report.

## 5.5 Changelog and version

- **Depends on:** 5.4.
- **Do:** turn the `CHANGELOG.md` Unreleased section into `## 0.2.0 – <date>`, grouped Added / Changed / Notes. Under Changed, call out the terminal-answer history change (consumers that re-add the answer will now see it twice). Update `docs/ARCHITECTURE.md` section 7 platform table with v0.2 results.
- **Done when:** docs diff reviewed.

## 5.6 Consumer deletions (app repository, human-tracked)

- **Depends on:** 5.4.
- **Do:** in the consuming app, against this branch:
  - delete `TerminalAnswer.restore` (item 2);
  - delete `StoppedTurnReply`, read `AgentStream.partialHistory` (item 1);
  - replace `ToolApprovalCoordinator` queue logic with `ToolApprovalQueue` + a thin `@Observable` wrapper over `updates` (item 4);
  - delete `ManualCompactionService` if 3.7b shipped, or migrate to `HierarchicalContextStore` if 3.7a.
- **Done when:** the app builds and its tests pass with those deletions. This is the roadmap's proof the kit surface is sufficient; any gap goes back to the matching section file as a new task.

## 5.7 Tag v0.2.0 (human)

- **Depends on:** 5.5, 5.6.
- **Do:** merge to `main`, tag `v0.2.0`, push the tag.
