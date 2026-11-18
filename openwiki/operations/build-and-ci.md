---
type: operations
title: Build, Lint and CI
description: The local Make targets for build, test, lint, format, and acceptance, and the GitHub Actions matrix that runs lint in Docker, builds and tests on macOS and Linux with warnings as errors, runs live provider tests when secrets are set, and builds and tests on the iOS Simulator.
tags: [ci, github-actions, make, swiftformat, swiftlint, warnings-as-errors, docker, ios-simulator]
verified:
  - by: openwiki/0.9.0
    at: 2026-11-18T19:31:47.975Z
sources:
  - id: openwiki-source-164e2da859b5277df81c7d94
    resource: repo://.github/workflows/ci.yml
  - id: openwiki-source-012f2c78e3b1446dfc35803f
    resource: repo://Makefile
generated: { by: "claude-code", at: "2026-11-18T19:31:47.975Z" }
---

# Build, Lint and CI

Build and check commands are defined in the `Makefile`. The same checks run in `.github/workflows/ci.yml` on every push to `main` and every pull request. The workflow uses Docker images for linters, and runs Swift builds directly on macOS and inside the `swift:6.3` image on Linux.

## Local Make targets

`Makefile` defines these targets:

| Target | Command | Purpose |
|---|---|---|
| `build` | `swift build` | Debug build of all products. |
| `test` | `swift test` | Run the test suite. |
| `test-ci` | `swift test --parallel -Xswiftc -warnings-as-errors` | Test with the same flags as CI. |
| `lint` | `mint run swiftlint --strict` | SwiftLint in strict mode. |
| `format` | `mint run swiftformat .` | Rewrite files in place. |
| `format-check` | `mint run swiftformat --lint .` | Report formatting differences without changing files. |
| `dev-check` | `format`, `lint`, `test` | Developer loop, with formatting applied. |
| `check` | `format-check`, `lint`, `test-ci` | Read-only gate that matches CI's warnings-as-errors policy. |
| `acceptance` | `python3 scripts/phase8_acceptance.py` | Release acceptance checks (see [Gates and acceptance](gates-and-acceptance.md)). |
| `bootstrap` | `brew install mint`, `mint bootstrap` | Installs Mint and the tools pinned in the Mintfile. |
| `clean` | `swift package clean` | Removes build products. |

`make check` is the closest local equivalent to CI, apart from the live and iOS jobs. Run `make dev-check` while editing, because it rewrites files.

## CI jobs

`ci.yml` runs on `push` to `main` and on `pull_request`. Concurrent runs for the same ref are cancelled. The workflow token has read-only `contents` permission. Every checkout step uses a pinned commit SHA and does not persist credentials.

- **Lint** (`ubuntu-latest`, 10 minutes). It runs `swiftformat --lint .` in the `ghcr.io/nicklockwood/swiftformat:0.60.1` image, `swiftlint lint --strict` in the `ghcr.io/realm/swiftlint:0.63.0` image, and then `python3 scripts/phase8_acceptance.py`. The repository is mounted read-only. The comment in the workflow says these image tags must be kept in sync with the Mintfile.
- **macOS** (`macos-26`, 30 minutes). It runs `swift build -Xswiftc -warnings-as-errors` and `swift test --parallel -Xswiftc -warnings-as-errors`.
- **Linux (Swift 6.3)** (`ubuntu-latest`, 30 minutes). The `swift:6.3` image has no Node.js, so the job cannot run `actions/checkout` inside it. Instead it runs the image with `docker run`, copies the source into `/work`, installs `libsqlite3-dev`, and runs the same build and test commands with warnings as errors.
- **Live provider** (matrix: macOS, Linux, iOS Simulator). Each leg runs only when the `AHK_LIVE_BASE_URL` secret is set. Without it, every live step is skipped, so forks and pull requests without secrets still pass. The macOS leg runs `swift test --filter LiveEndpointTests`. The Linux leg runs the same filter in Docker, passing secrets with bare `-e` names so their values never appear in the script. The iOS leg runs `xcodebuild test` on `LiveEndpointTests` in `AgentHarnessKitALMTests`, with the secrets mapped to `TEST_RUNNER_`-prefixed variables.
- **iOS Simulator** (`macos-26`, 30 minutes). It builds the package for `generic/platform=iOS Simulator`, then runs `AgentHarnessKitTests` and `AgentHarnessKitALMTests` on an iPhone 17 Pro simulator. Live tests are excluded here.

Both iOS steps pass `-skipMacroValidation`. The workflow comment records the reason: CI cannot approve Xcode's macro trust prompt, and the build otherwise fails with "Macro AnyLanguageModelMacros must be enabled". The decision is referenced as "Macro trust" in `docs/ARCHITECTURE.md`.

## Warnings as errors

The macOS, Linux, and live macOS and Linux steps pass `-warnings-as-errors`. The iOS Simulator job and the live iOS step do not, because they use `xcodebuild`. A new compiler warning therefore fails CI on macOS and Linux, and the local `make test-ci` and `make check` targets enforce the same rule.

## Operational consequences

- Lint and acceptance run without building Swift, so they catch formatting and release-check failures quickly.
- The live jobs depend on repository secrets. A pull request from a fork runs without them and reports the live tests as skipped, not failed.
- Linux builds depend on `libsqlite3-dev` being installed in the container. Adding a system dependency means updating the workflow command as well.

## Related pages

- [Test strategy](../testing/test-strategy.md) describes which tests these jobs run.
- [Gates and acceptance](gates-and-acceptance.md) describes what the acceptance script checks.
