# Files

- [Build, Lint and CI](build-and-ci.md) - The local Make targets for build, test, lint, format, and acceptance, and the GitHub Actions matrix that runs lint in Docker, builds and tests on macOS and Linux with warnings as errors, runs live provider tests when secrets are set, and builds and tests on the iOS Simulator.
- [Gates and Acceptance Checks](gates-and-acceptance.md) - The standalone GRDB gate package that tested the SQLite, FTS5, WAL, and AnyLanguageModel stack on each target platform before the context store was built, the spike report it fed, and the phase8_acceptance.py script that checks CI configuration, documentation, and committed secrets in the release process.
