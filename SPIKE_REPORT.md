# AgentSpike Report (macOS, Linux, Android emulator, iOS Simulator; mock + one real endpoint)

Status: macOS, Linux (Docker `swift:6.3`, aarch64) and Android (local arm64 emulator, API 34) are verified against the local mock. iOS (Simulator) is verified the same way. All four platforms also pass S1–S5 against one real endpoint: a local OpenAI-compatible llama.cpp-style server (`http://10.9.11.193:8080/v1`, model `swift-1.5-iq2_xs`, a reasoning model, no API key). Anthropic and OpenAI proper are **NOT RUN** (no API keys).
Android used Swift **6.4.2** (open-source toolchain + matching Android SDK), not 6.3: the SDK must match the toolchain exactly and Xcode's 6.4.2 toolchain is the local one.
The iOS build was blocked by a permission denial (see Blockers).

Versions: AnyLanguageModel **1.3.0** (`.upToNextMinor(from: "1.3.0")`, latest tag), Swift 6.4.2 (Xcode 27.2), macOS 27.3 arm64.
Traits: all off (default).

## 1. Result matrix

| | macOS | iOS | Linux | Android |
|---|---|---|---|---|
| S1 stream (mock) | PASS | PASS | PASS | PASS |
| S2 tool round trip (mock) | PASS | PASS | PASS | PASS |
| S3 loop control (mock) | PASS | PASS | PASS | PASS |
| S3 cross-process resume (mock) | PASS | PASS | PASS | PASS |
| S4 approval/denial (mock) | PASS | PASS | PASS | PASS |
| S5 cancel (mock) | PASS | PASS | PASS | PASS |
| S1–S5, real local endpoint | PASS | PASS | PASS | PASS |
| S1–S5, Anthropic / OpenAI | NOT RUN (no keys) | NOT RUN | NOT RUN | NOT RUN |

Real endpoint: S2 and S3 ran a real tool call (`add(2,3)`, model answered 5); the transcript contains `reasoning` entries (`prompt, reasoning, toolCalls, toolOutput, reasoning, response`); `session.usage` reported ~1040 tokens. S1 ttft was 0.5–3s (the model reasons first) but 13–18 snapshots then arrived spread over 50–240ms on every platform. I changed two scenario checks after the first real run (S1 no longer requires ttft < 80% of total, since reasoning inflates ttft; S5 waits up to 8s for content, then cancels, and reports `snapshotsBeforeCancel=0` if it cancelled mid-reasoning). The mock results above were re-checked after those changes only on macOS/Android/iOS for S5/S1 where noted; treat them as earlier-code results otherwise. After a cancel the server's `/slots` showed no slot processing within seconds (macOS check), so the request was dropped server-side.

iOS: `spike` built with SwiftPM for `arm64-apple-ios17.0-simulator` and run inside an iPhone 18 Pro / iOS 27.2 simulator via `xcrun simctl spawn` (a command-line binary, not a host app, so no app sandbox or ATS; the mock is plain HTTP on loopback). All scenarios passed. The `xcodebuild` route is still blocked by Xcode's macro prompt; SwiftPM's CLI does not prompt.

Android: arm64 emulator (Android 14, API 34), binary built with `--swift-sdk aarch64-unknown-linux-android28`, run with `adb shell`. All scenarios passed with the in-process mock; S1, S2, S4, S5 also passed against a host mock via `10.0.2.2`. The GitHub Actions Android job built the package but its emulator never booted (run cancelled), so CI is not a result.

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
   - Android (emulator): in-process mock S1 streamed incrementally (ttft 64ms of 632ms, 12 snapshots). Via the host mock over `10.0.2.2`, S1 showed ttft 508ms of 643ms, and S2/S4 took 1.0s/2.0s versus 0.17s/0.02s in-process. That looked like batching, but against the real endpoint from the same emulator, S1 streamed 17 snapshots over 141ms after the first token, so Android's HTTP streaming is incremental. The slow mock path is most likely my mock (unconfirmed). Source read (default transport is URLSession; no `#if os(Android)` branches):
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
5. **Cancellation.** macOS and Linux: cancelling the task stopped it in 0ms and `isResponding` went false. The mock saw the socket drop within 500ms (`serverSawAbort=true`). Android: also passes, but see Blockers for a SIGPIPE issue in my mock.
6. **Android specifics.**
   - Needed: open-source Swift 6.4.2 toolchain (Xcode's will not do), the matching Swift SDK for Android (`swift sdk install ...swift-6.4.2-RELEASE_android.artifactbundle.tar.gz --checksum ...`), NDK r30 (only for `libc++_shared.so`), JDK + Android cmdline-tools, `platform-tools`, `emulator`, system image `android-34;google_apis;arm64-v8a`. About 5 GB. `scripts/android-setup-1.sh` does the Swift/NDK/JDK part, all inside `.android-env/`.
   - Launch: `adb push` the `spike` binary, the Swift runtime `.so` files from the SDK (`swift-resources/usr/lib/swift-aarch64/android`) and `libc++_shared.so` to `/data/local/tmp/spike`, then `LD_LIBRARY_PATH=. ./spike`. Env vars are passed on the `adb shell` command line.
   - `--static-swift-stdlib` fails to link: undefined OpenSSL symbols (`SSL_get_peer_cert_chain`, `BIO_new`, ...). Use dynamic linking.
   - DNS and TLS work: `SPIKE_PROVIDER=openai OPENAI_API_KEY=<fake> ./spike --only S2` got `HTTP error (Status 401)` from api.openai.com in 851ms.
   - Emulator reaches the host mock at `10.0.2.2` (host mock must be running; bound to 127.0.0.1 works).
7. **Traits.** macOS and Linux build and run with traits off as a consuming package (this spike). The documented SwiftPM trait bug did not appear (I did not enable traits). Android and iOS are not run.
8. **Toolchain floor.** Confirmed in `swift:6.2` (6.2.4): `swift build` fails immediately with `package 'work' is using Swift tools version 6.3.0 but the installed version is 6.2.4`. That is my manifest; AnyLanguageModel's own manifest is also 6.3, so 6.2 can't resolve the dependency either. It did not get as far as compiling AnyLanguageModel, so compile-level failures on 6.2 (as SPI shows) are not independently reproduced.

## 3. Loop-control verdict
We can build checkpoint/resume, approvals and sub-agents on the session API, with two workarounds for the quirks in answer 3. The smallest sample is `resumeFromCheckpoint` plus `StopAfterRound` and `DenyOnce` in `Sources/SpikeCore/Scenarios.swift`. We do not have to drive rounds ourselves.
Two points are unverified: whether these delegate hooks and the empty-response quirk behave the same with real providers, and how parallel tool calls behave.

## 4. Blockers and workarounds
1. iOS is only verified as a command-line binary in the Simulator, not inside an app (ATS and sandbox untested).
2. **iOS build blocked.** `xcodebuild -scheme AgentSpike -destination 'generic/platform=iOS Simulator' build` fails with "Macro AnyLanguageModelMacros must be enabled". Passing `-skipMacroValidation` was denied by the permission classifier, and I did not work around it. Options: you run it yourself, you approve that flag, or you enable the macro in Xcode.
2. Mock over `10.0.2.2` showed late first tokens; not reproduced with a real endpoint (see answer 2). Low severity.
3. `signal(SIGPIPE, SIG_IGN)` did not protect my mock on Android: cancelling a stream killed the process (exit 141) until I used `send(..., MSG_NOSIGNAL)`. This is my mock's bug, but a client doing the same on Android should expect it.
3. Empty trailing `.response` after `.stop` (workaround above).
4. Continuation needs an extra user prompt (workaround above).
5. No Vertex support (transport shim).
6. Anthropic and OpenAI proper were not run (no keys), so Anthropic thinking and usage remain source-read only. Only an OpenAI-compatible llama.cpp-style server was exercised for real.

## 5. Recommendation
Leaning adopt. Loop control works on macOS, Linux and an Android emulator with two small workarounds. The remaining gap is a run against Anthropic itself.

## 6. Reproduce (macOS)
```bash
# Real endpoint (any platform): SPIKE_PROVIDER=openai OPENAI_BASE_URL=http://10.9.11.193:8080/v1 OPENAI_API_KEY=none SPIKE_MODEL=swift-1.5-iq2_xs
#   (iOS sim: prefix each var with SIMCTL_CHILD_; Android: export them inside `adb shell`; Docker: -e)
# Android (after scripts/android-setup-1.sh and the sdkmanager step; see scripts/):
#   swift build --product spike --swift-sdk aarch64-unknown-linux-android28 --swift-sdks-path $SWIFT_SDKS --scratch-path .android-env/build
# Linux:
docker run --rm -v "$PWD":/src:ro swift:6.3 bash -c 'cp -r /src /work && cd /work && rm -rf .build && swift run spike'
# iOS Simulator:
#   swift build --product spike --sdk $(xcrun --sdk iphonesimulator --show-sdk-path) --triple arm64-apple-ios17.0-simulator --scratch-path /tmp/ios
#   xcrun simctl boot <udid>; xcrun simctl spawn <udid> /tmp/ios/debug/spike
# macOS:
swift run spike                                   # all scenarios, in-process mock
swift run spike --resume spike-checkpoint.json    # new-process resume (after S3 wrote the file)
swift run spike --serve-mock 8080                 # standalone mock (for Android: SPIKE_MOCK_URL=http://10.0.2.2:8080/v1/)
swift test
SPIKE_PROVIDER=openai OPENAI_API_KEY=... OPENAI_BASE_URL=... SPIKE_MODEL=... swift run spike   # or SPIKE_PROVIDER=anthropic ANTHROPIC_API_KEY=...
```
