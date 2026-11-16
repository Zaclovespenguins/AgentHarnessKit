# Spike Handoff: AnyLanguageModel as a cross-platform agent foundation

You are starting in a fresh, empty repo. This document is your whole brief. Do not assume any other context.

## Goal

Decide whether [huggingface/AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) can be the foundation for a Swift agent SDK that **actually runs** (not just compiles) on **iOS, macOS, Linux and Android**. Build a small throwaway spike package, run it on each platform, and write up the answers. Do not build the SDK itself.

## Background (what is already known)

- The goal is a new package that adds agent features on top of AnyLanguageModel: an agent loop with approvals, checkpoint/resume, sub-agents, and MCP. The existing package AgentRunKit has these features but does not build on Linux or Android. Its blockers were `URLSession.bytes` (used for SSE streaming), missing `FoundationNetworking` imports, Accelerate, NaturalLanguage, and macOS-only stdio MCP.
- Swift Package Index (SPI) build grid for AnyLanguageModel (release 1.3.0 and main), as read from its builds page:
  - Swift 6.3 and 6.4: iOS, macOS, Linux and Android all **Succeeded** (on Swift 6.4, main's macOS builds showed Timed Out).
  - Swift 6.1 and 6.2: everything **Failed**. Wasm failed everywhere.
  - So the minimum toolchain is probably **Swift 6.3**.
- README claims (unverified by us): drop-in replacement for Apple's Foundation Models API. Providers include Anthropic, Gemini, OpenAI (Chat Completions and Responses), Ollama, MLX, llama.cpp and Core ML. Tool calling works on all providers except Core ML. A `ToolExecutionDelegate` can observe, approve, stop or replace tool calls and inject steering messages between rounds. `maximumToolRounds` caps the loop. Responses stream as snapshots. Optional traits (CoreML, MLX, Llama, AsyncHTTPClient) are all off by default. The README lists Linux and WASI but **does not mention Android**. It notes a SwiftPM bug that can break dependency resolution when traits are used and gives a workaround.
- A passing SPI build only proves it compiles. Nothing is known about runtime behavior on Linux or Android.

## Questions the spike must answer

1. **Runtime on each platform.** Does a real streaming request with a tool call work end to end on macOS, iOS, Linux and Android?
2. **HTTP transport.** On Linux and Android, which transport is used by default, and does streaming (SSE) arrive incrementally rather than buffered until the end? Does the `AsyncHTTPClient` trait change this?
3. **Loop control (the most important question).** The session runs the tool loop internally. Can we:
   - run exactly one model round at a time, or stop after each round via `ToolExecutionDelegate`;
   - read the full transcript (messages, tool calls, tool results) at any point;
   - serialize that transcript to JSON, then in a **new process** rebuild a session from it and continue;
   - deny or require approval for a tool call and have the model see the denial?
   If any of these is not possible, say what the closest workaround is.
4. **Provider-specific features.** Are Anthropic thinking/reasoning blocks and token usage exposed? Can provider-specific request fields be passed through? Is Vertex AI possible, or only via a custom endpoint?
5. **Cancellation.** Does cancelling the Swift `Task` mid-stream stop the request promptly on each platform?
6. **Android specifics.** What is needed to build and run (SDK install, emulator, how the binary is launched, how env vars and the network are provided)? Do TLS and DNS work? Is there anything Android-specific that breaks at runtime?
7. **Traits.** Does the documented SwiftPM trait bug show up in a package that depends on AnyLanguageModel? Does a consuming package build with traits off (the default) on all four platforms?
8. **Toolchain floor.** Confirm Swift 6.3 is required by trying 6.2 on Linux. Record the exact error if it fails.

## What to build

A single SwiftPM package, `AgentSpike`, with `swift-tools-version: 6.3`:

- Dependency: `https://github.com/huggingface/AnyLanguageModel`, pinned `.upToNextMinor` at the latest tagged release. Record the exact version used.
- A library target `SpikeCore` holding the scenarios, so it can be exercised from tests and from executables.
- An executable target `spike` that runs the scenarios below and prints a one-line PASS/FAIL per scenario with timings.
- Scenarios:
  - **S1 stream:** stream a short answer. Record time to first token and number of snapshots, to show that streaming is incremental.
  - **S2 tool round trip:** one tool, for example `add(a, b)`. The model must call it and use the result.
  - **S3 loop control:** the checks from question 3, including the cross-process resume (write transcript JSON to a file, exit, run again with `--resume <file>`).
  - **S4 approval and denial:** a delegate that denies a tool call once.
  - **S5 cancel:** cancel a long stream after about 1 second and confirm it stops.
- Provider selection by environment variable, with at least Anthropic and an OpenAI-compatible endpoint (base URL configurable). Add a **local mock server** that speaks the OpenAI-compatible SSE format, so scenarios can run without a real key and without network. Use the mock for Android and CI, and a real provider for at least one run per platform.

Keep it minimal. No abstractions, no UI beyond what is needed to prove iOS builds and runs a scenario.

## Platforms and how to test

| Platform | Minimum bar |
|---|---|
| macOS | `swift build` and `swift run spike` pass all scenarios. |
| Linux | Run in a Docker container using the official `swift:6.3` image (and `swift:6.2` once, to confirm the floor). `swift run spike` passes all scenarios. |
| Android | Install the official Swift SDK for Android (Swift 6.3 or later), cross-compile `spike`, push to an emulator with `adb`, and run it there. [skiptools/swift-android-action](https://github.com/skiptools/swift-android-action) runs Swift package tests on an emulator in CI and is a good reference. If the mock server is not reachable from the emulator, use `10.0.2.2` for the host loopback. |
| iOS | Build for the iOS Simulator. Run S1 or S2 inside a minimal host app or test target if practical. Report if it is skipped. |

Also run the mock-server scenarios on Linux and Android in a GitHub Actions workflow if time allows.

## Rules

- **Never commit API keys.** Read them from environment variables only. In any example, test data or docs, use obviously fake values.
- Do not modify or fork AnyLanguageModel. If something is broken, record it and a workaround.
- Do not claim a platform works unless you ran a scenario on it. Mark anything unverified as unverified.
- If a step is blocked (for example no Android emulator is available), say so and continue with the others.
- Time-box this spike. Prefer a clear negative answer on a question over a long fix attempt.

## Deliverable: `SPIKE_REPORT.md` in the repo root

1. **Result matrix.** Scenarios S1 to S5 against macOS, iOS, Linux and Android, with PASS, FAIL or NOT RUN, plus exact toolchain and AnyLanguageModel versions.
2. **Answers to questions 1 to 8**, each with the evidence (command, output or code location), not just a conclusion.
3. **Loop-control verdict:** can we build checkpoint/resume, approvals and sub-agents on top of the session API, or must we drive rounds ourselves? Include the smallest code sample that shows the approach working.
4. **Blockers and workarounds**, ordered by severity.
5. **Recommendation:** adopt AnyLanguageModel as the foundation, adopt with specific workarounds, or reject, and why.
6. **How to reproduce:** the exact commands for each platform.

## Out of scope

MCP, sub-agents, TTS, checkpointing as a feature, the final package design, and any UI. Those come after this spike, and only if the recommendation is to proceed.
