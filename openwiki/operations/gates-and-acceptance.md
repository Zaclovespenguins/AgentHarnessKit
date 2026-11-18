---
type: operations
title: Gates and Acceptance Checks
description: The standalone GRDB gate package that tested the SQLite, FTS5, WAL, and AnyLanguageModel stack on each target platform before the context store was built, the spike report it fed, and the phase8_acceptance.py script that checks CI configuration, documentation, and committed secrets in the release process.
tags: [gate, grdb, sqlite, fts5, wal, acceptance, release, ci-checks, spike]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-7fc5296c5fc27ddf8db9373a
    resource: repo://Gates/GRDBGate/Package.swift
  - id: openwiki-source-1cac7172add86e07f8490d57
    resource: repo://Gates/GRDBGate/Sources/GRDBGateCore/GRDBGateCore.swift
  - id: openwiki-source-9f28c1359f83941dc93527ed
    resource: repo://Gates/GRDBGate/Tests/GRDBGateCoreTests/GRDBGateCoreTests.swift
  - id: openwiki-source-3e6c06bc2c7540d6cdca4189
    resource: repo://scripts/phase8_acceptance.py
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Gates and Acceptance Checks

Two kinds of check sit outside the normal test suite. Both are release-process tools, not part of the library.

- The **GRDB gate** (`Gates/GRDBGate`) is a separate Swift package. It verified that GRDB's database pool, migrations, FTS5, and WAL mode work on each target platform before the persistence design was committed. Its results are recorded in `docs/spike`.
- The **acceptance script** (`scripts/phase8_acceptance.py`) is a Python check that runs in CI's lint job and through `make acceptance`. It verifies CI configuration, docs, and the absence of committed API keys. It does not build or run Swift code.

## The GRDB gate package

`Gates/GRDBGate/Package.swift` is a `swift-tools-version: 6.3` package with platforms macOS 14 and iOS 17. It depends on GRDB (`upToNextMajor` from 7.12.0) and on AnyLanguageModel (`upToNextMinor` from 1.3.0). It has three targets:

- `GRDBGateCore` (library product). It opens a `DatabasePool` in a given directory (`openGatePool(directory:)`, `GRDBGateCore.swift:38`), runs a migrator that creates the FTS5-backed tables (`gateMigrator()`, `GRDBGateCore.swift:45`), and runs `runGRDBGate(...)` (`GRDBGateCore.swift:66`). That function records a list of named checks. Each check has a `GateCheck.Status` of `PASS`, `FAIL`, or `N/A`. The result is a `GateReport` with the journal mode, the SQLite version, and the compile options.
- `grdb-gate` (executable product). It is the command-line runner for the same checks.
- `GRDBGateCoreTests`. Its first test requires exactly eight checks, no `FAIL` results, WAL journal mode, a SQLite version, and `ENABLE_FTS5` in the compile options. The last check must be `N/A`. A second test confirms that `AnyLanguageModel` links next to GRDB by checking for `LanguageModelSession`.

The product package's persistence layer (`GRDBContextPersistence`, see [Hierarchical context store](../context/hierarchical-context-store.md)) relies on the same pool, migration, and WAL behavior.

### What the spike recorded

`docs/spike/SPIKE_REPORT.md` contains the result table. The report's status line says macOS, Linux (Docker `swift:6.3`, aarch64), and Android (arm64 emulator, API 34) pass against the local mock. It also says the iOS Simulator passes the same checks. All four platforms also pass scenarios S1 through S5 against one real OpenAI-compatible local endpoint. Those scenarios are streaming, tool round trip, loop control, cross-process resume, approval and denial, and cancel. Anthropic and OpenAI proper are recorded as **NOT RUN** because no API keys were available at that point.

The spike report is a historical record. The current behavior of the product is described in the architecture pages, not in the spike report. `docs/ARCHITECTURE.md` records the decision that followed the gate.

## The acceptance script

`scripts/phase8_acceptance.py` runs named sections. Each section prints `PASS` or `FAIL` for each check and exits non-zero if any check fails. The sections are:

- `ci` parses `.github/workflows/ci.yml` and checks for the `lint`, `macos`, `linux`, `ios`, and `live` jobs. It requires top-level `contents: read` permissions and a 40-character commit SHA on every `uses:` reference. It rejects any `secrets.` reference inside a `run:` script. It requires `swift test` with `-warnings-as-errors` on macOS and Linux. It requires `xcodebuild test` on a concrete iOS Simulator destination, with both target bundles and `-skipMacroValidation`. It also checks that the live job uses the expected secret names, runs only `LiveEndpointTests`, covers Linux and iOS, and is skipped when the secret is absent.
- `readme` checks that `README.md` names every library product in `Package.swift`, contains required phrases such as `make check`, `MLX`, and `-skipMacroValidation`, and has no broken relative links. It also checks that every type named in a Swift sample exists in `Sources/`, with an allowlist for ALM provider types.
- `docs` checks that `docs/README.md` links every other Markdown file in `docs/`, and also `ROADMAP.md`, `AGENTHARNESSKIT_PARITY_SPEC.md`, `CHANGELOG.md`, and `README.md`. It checks that `CHANGELOG.md` has a `0.1.0` section and lists known gaps. It checks that `ROADMAP.md` has a Phase 8 status line.
- `arch` checks that `docs/ARCHITECTURE.md` has a results row for `AgentHarnessKitALMTests` on the iOS Simulator, with `PASS` or `FAIL` and a test count.
- `keys` runs `git ls-files` and searches tracked files for patterns that look like Anthropic, OpenAI, AWS, or GitHub keys.

The script uses PyYAML. Run it with `python3 scripts/phase8_acceptance.py`, or with `--only` to choose sections, for example `--only ci,keys`.

## Operational consequences

- Changing a CI job name, its SHA pins, or its secret handling can fail the `ci` section even when the workflow runs correctly. Update the script when the workflow changes on purpose.
- The `arch` section requires a current results row in `docs/ARCHITECTURE.md`. Adding an iOS run without updating that row fails the check.
- The `keys` section scans only tracked files plus three top-level docs. A secret in an untracked file is not found.
- Passing the acceptance script does not show that Swift code builds or that tests pass. Those are covered by [Build and CI](build-and-ci.md).

## Related pages

- [Build and CI](build-and-ci.md) describes the lint job that runs this script.
- [Hierarchical context store](../context/hierarchical-context-store.md) describes the persistence layer the GRDB gate was checking.
