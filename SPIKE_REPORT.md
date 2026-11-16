# AgentSpike Report (partial: macOS + Linux)

Status: macOS and Linux (Docker `swift:6.3`, aarch64) are verified against the local mock. Android, iOS and the real-provider runs are **NOT RUN**.
Android needs downloads (SDK, emulator) that were not approved yet.
The iOS build was blocked by a permission denial (see Blockers).

Versions: AnyLanguageModel **1.3.0** (`.upToNextMinor(from: "1.3.0")`, latest tag), Swift 6.4.2 (Xcode 27.2), macOS 27.3 arm64.
Traits: all off (default).

## 1. Result matrix

| | macOS | iOS | Linux | Android |
|---|---|---|---|---|
| S1 stream (mock) | PASS | NOT RUN | PASS | NOT RUN |
| S2 tool round trip (mock) | PASS | NOT RUN | PASS | NOT RUN |
| S3 loop control (mock) | PASS | NOT RUN | PASS | NOT RUN |
| S3 cross-process resume (mock) | PASS | NOT RUN | PASS | NOT RUN |
| S4 approval/denial (mock) | PASS | NOT RUN | PASS | NOT RUN |
| S5 cancel (mock) | PASS | NOT RUN | PASS | NOT RUN |
| Any scenario, real provider | NOT RUN (no API key in env; only `ANTHROPIC_BASE_URL` is set) | NOT RUN | NOT RUN | NOT RUN |

Linux: Swift 6.3.3 in `swift:6.3`, traits off. Build took 68s. Output matched macOS (S1 ttft=58ms of 612ms, 12 snapshots; S5 server saw the abort; cross-process resume in a second process passed). Same mock caveat applies.

macOS output (`swift run spike`; `swift test` also passes):
```
PASS S1 stream 657ms ttft=64ms total=657ms snapshots=12
PASS S2 tool round trip 168ms toolCalls=[[2, 3]] usage.total=63 transcript=[prompt,toolCalls,toolOutput,response]
PASS S3 loop control afterOneRound=[prompt,toolCalls,response] stoppedBeforeExec=true jsonRoundTrip=true
PASS S3-resume cross-process resume pid=67414 resumed="The sum is 5."   (run as: spike --resume spike-checkpoint.json)
PASS S4 approval/denial toolRunsAfterDeny=0 denialInTranscript=true toolRunsAfterApprove=1
PASS S5 cancel snapshotsBeforeCancel=9 stoppedIn=0ms isResponding=false serverSawAbort=true
```
Caveat: the mock server is mine, so these results prove the client path, not real-model behavior.

## 2. Answers

1. **Runtime per platform.** macOS only, mock only. The others are unverified.
2. **HTTP transport.**
   - macOS: S1 shows incremental streaming (first snapshot at 64ms, 12 snapshots, 657ms total).
   - Linux: S1 streamed incrementally (ttft 58ms of 612ms, 12 snapshots) with the default transport (URLSession via FoundationNetworking). The `AsyncHTTPClient` trait was not tried.
   - Android: not run. Source read only (unverified at runtime):
     - Default transport is `URLSession` everywhere, via `makeDefaultTransport()` (`Shared/Transport.swift:140-195`). SSE is read through a delegate-based `ResponseChunks`, not `URLSession.bytes` (`Extensions/URLSession+Extensions.swift`).
     - On Linux and Android (`canImport(FoundationNetworking)`) it creates a new URLSession per request and serializes request starts with a gate, working around swift-corelibs-foundation#4791. Timeouts round up to whole seconds.
     - The `AsyncHTTPClient` trait only swaps the default transport to `HTTPClient.shared`.
     - There are no `#if os(Android)` branches in the module.
3. **Loop control (macOS, mock).**
   - Stop after each round: **yes**. A delegate returning `.stop` from `toolCallDecision` ends the response after the model emits tool calls, with the tool not executed.
   - Read the transcript: **yes**. `session.transcript` is a Collection of entries (prompt, toolCalls, toolOutput, response, reasoning, instructions).
   - Serialize it: **yes**. `Transcript` is `Codable`, and the JSON round trip is equal (739 bytes).
   - Rebuild and continue in a new process: **yes**, via `LanguageModelSession(model:tools:transcript:)`. The code is `resumeFromCheckpoint` in `Sources/SpikeCore/Scenarios.swift`. Two quirks apply:
     - `.stop` leaves a trailing **empty `.response` entry** after `toolCalls`. Drop it before appending `.toolOutput` entries.
     - Continuing needs a **new prompt** (`respond(to:)` always appends a user turn). I used "Continue and give me the final answer." Whether an empty prompt is accepted is untested.
   - Deny or require approval: **yes**. `.provideOutput([.text("DENIED...")])` replaces the tool output. The model saw it, and the transcript records it. The tool did not run, and a later call ran normally (S4).
4. **Provider features** (source read only, unverified at runtime).
   - Anthropic thinking: enabled via `AnthropicLanguageModel.CustomGenerationOptions.thinking` (`.enabled(budgetTokens:)` or `.adaptive`). Blocks surface as `Transcript.Reasoning` entries, both streaming and non-streaming. Signatures are kept and replayed (`Models/AnthropicLanguageModel.swift:546-553, 769-797, 1170-1190`).
   - Usage: `session.usage` is cumulative, `Response.usage` is the last request, and `Snapshot.usage` is available while streaming. It has input, cached and reasoning counts plus a metadata dictionary. `session.usage` returned 63 tokens in S2 on the mock. One catch: OpenAI streaming sends `include_usage` only for the official endpoint, so a custom `baseURL` gets none unless you set it through `extraBody`.
   - Passthrough: `extraBody: [String: JSONValue]` exists on both the Anthropic and OpenAI custom options and is merged last.
   - Vertex: no support. Auth headers and the `v1/messages` path are hard-coded. Workaround: a custom `HTTPTransport` that rewrites the URL, headers and body. For OpenAI-compatible Vertex endpoints, a custom `baseURL` with a token-provider closure should work.
5. **Cancellation.** macOS and Linux: cancelling the task stopped it in 0ms and `isResponding` went false. The mock saw the socket drop within 500ms (`serverSawAbort=true`). Android is not run.
6. **Android.** Not run. Needs the Swift SDK for Android, an emulator, and `adb`, none of which are installed (`adb` is not found). Waiting for OK.
7. **Traits.** macOS and Linux build and run with traits off as a consuming package (this spike). The documented SwiftPM trait bug did not appear (I did not enable traits). Android and iOS are not run.
8. **Toolchain floor.** Confirmed in `swift:6.2` (6.2.4): `swift build` fails immediately with `package 'work' is using Swift tools version 6.3.0 but the installed version is 6.2.4`. That is my manifest; AnyLanguageModel's own manifest is also 6.3, so 6.2 can't resolve the dependency either. It did not get as far as compiling AnyLanguageModel, so compile-level failures on 6.2 (as SPI shows) are not independently reproduced.

## 3. Loop-control verdict
We can build checkpoint/resume, approvals and sub-agents on the session API, with two workarounds for the quirks in answer 3. The smallest sample is `resumeFromCheckpoint` plus `StopAfterRound` and `DenyOnce` in `Sources/SpikeCore/Scenarios.swift`. We do not have to drive rounds ourselves.
Two points are unverified: whether these delegate hooks and the empty-response quirk behave the same with real providers, and how parallel tool calls behave.

## 4. Blockers and workarounds
1. Android and iOS are unverified. That is the main open risk; Android needs approval for downloads.
2. **iOS build blocked.** `xcodebuild -scheme AgentSpike -destination 'generic/platform=iOS Simulator' build` fails with "Macro AnyLanguageModelMacros must be enabled". Passing `-skipMacroValidation` was denied by the permission classifier, and I did not work around it. Options: you run it yourself, you approve that flag, or you enable the macro in Xcode.
3. Empty trailing `.response` after `.stop` (workaround above).
4. Continuation needs an extra user prompt (workaround above).
5. No Vertex support (transport shim).
6. No real-provider run, because no API key is set in the environment.

## 5. Recommendation
Leaning adopt. Loop control works on macOS and Linux with two small workarounds. Decide after the Android run and a real-provider run.

## 6. Reproduce (macOS)
```bash
# Linux:
docker run --rm -v "$PWD":/src:ro swift:6.3 bash -c 'cp -r /src /work && cd /work && rm -rf .build && swift run spike'
# macOS:
swift run spike                                   # all scenarios, in-process mock
swift run spike --resume spike-checkpoint.json    # new-process resume (after S3 wrote the file)
swift run spike --serve-mock 8080                 # standalone mock (for Android: SPIKE_MOCK_URL=http://10.0.2.2:8080/v1/)
swift test
SPIKE_PROVIDER=openai OPENAI_API_KEY=... OPENAI_BASE_URL=... SPIKE_MODEL=... swift run spike   # or SPIKE_PROVIDER=anthropic ANTHROPIC_API_KEY=...
```
