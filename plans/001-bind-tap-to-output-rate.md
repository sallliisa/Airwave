# Plan 001: Bind process tap to selected output's native sample rate

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If a STOP condition occurs, stop and report; do not add a realtime sample-rate converter or improvise another architecture. When done, update this plan's row in `plans/README.md` unless a reviewer says they maintain the index.
>
> **Drift check (run first)**: `git diff --stat bb9a8bf..HEAD -- Airwave/AudioPlatformClient.swift Airwave/AudioPipeline.swift Airwave/CoreAudioPlatformClient.swift AirwaveTests/AudioPipelineTests.swift AirwaveTests/CoreAudioPlatformClientTests.swift`
> If an in-scope file changed, compare Current state against live code. Stop if request shape, tap creation, or format validation no longer matches.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: migration / bug
- **Planned at**: commit `bb9a8bf`, 2026-07-16

## Why this matters

Airwave's global stereo tap reports 48 kHz on the known host while a Bluetooth output runs at 44.1 kHz. Current code accepts this mismatch on paper, then asks AUHAL to use the aggregate/output rate for both sides. That assumption is invalid: AUHAL handles simple PCM layout conversion, but its client rate must match device-side rate unless the app adds buffered SRC.

Do not add full-stream SRC. Core Audio's device-bound tap initializer guarantees its format matches the chosen hardware stream. Bind the tap to current physical output, then keep existing native-rate DSP: HRIR impulse responses are prepared offline at output rate, and EQ coefficients are already built at output rate.

## Current state

- `Airwave/AudioPlatformClient.swift:38-71` permits exact matches plus special 44.1↔48 kHz mismatches through `AudioSampleRateCompatibility`.
- `Airwave/AudioPlatformClient.swift:78-91` defines `GlobalStereoTapRequest` without output UID or stream index.
- `Airwave/AudioPipeline.swift:89-98` creates that untargeted request, then compares tap format with `output.nominalSampleRate`.
- `Airwave/CoreAudioPlatformClient.swift:267-275` uses `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, which is not bound to selected device.
- `Airwave/CoreAudioPlatformClient.swift:382-385` configures canonical stereo callback format at aggregate nominal rate. This remains correct once tap and output share rate.
- `Airwave/HRIRManager.swift:347-365` already resamples HRIR arrays during off-thread preset activation to `targetSampleRate`; do not replace this with realtime stream SRC.
- `Airwave/AudioEffectGraph.swift:103-105` already prepares EQ at `output.nominalSampleRate`.
- Installed Core Audio SDK declares `CATapDescription(excludingProcesses:deviceUID:stream:)`; header contract says tap format matches selected stream. A compile probe at plan time confirmed this Swift spelling.

Match existing conventions: value-type platform requests in `AudioPlatformClient.swift`, dependency injection and strict acquire/unwind order in `AudioPipeline.swift`, and recording fake assertions in `AudioPipelineTests.swift`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| API check | `xcrun swiftc -typecheck /tmp/airwave-tap-api-check.swift` | exit 0 |
| Focused tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/AudioPipelineTests -only-testing:AirwaveTests/CoreAudioPlatformClientTests` | `** TEST SUCCEEDED **` |
| Safety | `scripts/test-audio-safety-invariants.sh` | `audio safety invariant tests passed` |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | `** TEST SUCCEEDED **` |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | `** ANALYZE SUCCEEDED **` |

For API check, create `/tmp/airwave-tap-api-check.swift` containing `import CoreAudio` and construction of `CATapDescription(excludingProcesses: [AudioObjectID](), deviceUID: "uid", stream: 0)`. `/tmp` is not repo scope.

## Scope

**In scope**:

- `Airwave/AudioPlatformClient.swift`
- `Airwave/AudioPipeline.swift`
- `Airwave/CoreAudioPlatformClient.swift`
- `AirwaveTests/AudioPipelineTests.swift`
- `AirwaveTests/CoreAudioPlatformClientTests.swift`

**Out of scope**:

- `Airwave/Resampler.swift` and convolution DSP internals; offline HRIR conversion remains.
- Adding `AudioConverter`, ring buffers, worker threads, or callback buffering.
- Changing default output, nominal device rate, volume, or aggregate-device safety policy.
- Multichannel outputs; Airwave remains physical stereo-only.
- Product UI or release claims; physical acceptance belongs to Plan 002.

## Git workflow

- Branch: `codex/001-native-rate-tap`
- Use logical commits with existing conventional style, e.g. `fix(audio): bind tap to output rate`.
- Do not push or open PR unless instructed.

## Steps

### Step 1: Make output binding explicit in tap request

Extend `GlobalStereoTapRequest` with immutable `outputDeviceUID: String` and `streamIndex: Int`. Change initializer to require `excludedProcess` plus selected `OutputDeviceDescriptor`, copying `output.uid` and setting stream index `0`. Retain `isGlobal`, stereo, private, and muted semantics: “global” means all processes except Airwave, scoped to selected device.

Update `AudioPipeline.start(on:)` to build request with same validated `output` used for aggregate creation. Do not re-query default output between tap and aggregate creation.

Update lifecycle test expected request and assert UID/stream. Add one 44.1 kHz output case proving request targets Bluetooth UID and successful matching 44.1 formats proceed through full lifecycle.

**Verify**: focused tests command → `** TEST SUCCEEDED **`.

### Step 2: Use device-bound Core Audio tap initializer

In `CoreAudioPlatformClient.createGlobalStereoTap`, validate nonempty output UID and nonnegative stream index in addition to existing request invariants. Construct:

```swift
CATapDescription(
    excludingProcesses: [AudioObjectID(request.excludedProcess.value)],
    deviceUID: request.outputDeviceUID,
    stream: request.streamIndex
)
```

Keep name, UUID, privacy, mute behavior, error mapping, resource tracking, and teardown unchanged.

**Verify**: API check and focused tests → exit 0 / `** TEST SUCCEEDED **`.

### Step 3: Restore strict same-rate validation

Replace `AudioSampleRateCompatibility` conversion policy with strict positive finite rate equality within existing 0.5 Hz tolerance. Prefer a clearly named helper such as `AudioSampleRateCompatibility.matches`; alternatively keep `isCompatible` only if its documentation explicitly says it means no SRC and requires same rate. Remove 44.1↔48 special cases.

Update tests to prove matching 44.1, 48, 88.2, and 96 kHz rates pass; invalid/nonfinite rates and all cross-rate pairs fail. Replace tests that currently expect mismatched tap/output rates to start with cleanup/error assertions. Preserve interleaved tap acceptance only when sample rate matches, since AUHAL may convert PCM interleaving without SRC.

**Verify**: focused tests → `** TEST SUCCEEDED **`.

### Step 4: Run full safety gates

Run safety, full tests, and analyzer. Confirm diff contains no route/volume mutation, realtime allocation, new dependency, or changes outside scope plus `plans/README.md` status.

**Verify**: `git diff --check` exits 0; all commands in table pass; `git status --short` lists only scoped files and plan index status change.

## Test plan

- `AudioPipelineTests`: request carries selected device UID/stream; matching 44.1, 48, 88.2, 96 kHz tap/output formats start and clean up; 48→44.1 and 44.1→48 mismatches fail before aggregate creation and destroy tap.
- `CoreAudioPlatformClientTests`: exact-rate helper accepts common matching rates, rejects mismatches, zero, negative, infinity, and NaN.
- Preserve existing interleaved same-rate test, strict resource ordering, failure unwind, idempotent stop, and teardown retry tests.
- Plan 002 supplies signed hardware evidence unavailable to unsigned CI.

## Done criteria

- [ ] Tap request binds excluded process, selected output UID, and stream 0.
- [ ] Production uses device-bound `CATapDescription` initializer.
- [ ] No cross-rate pair is declared callback-compatible.
- [ ] Matching 44.1/48/88.2/96 kHz unit cases pass.
- [ ] No realtime full-stream SRC or DSP-rate conversion added.
- [ ] Safety script, focused tests, full tests, and analyzer pass.
- [ ] No source files outside Scope changed.
- [ ] `plans/README.md` row updated.

## STOP conditions

Stop and report if:

- Device-bound initializer is unavailable at macOS 15 deployment target or compile probe fails.
- Physical stream 0 cannot represent existing supported stereo outputs; do not invent stream selection policy.
- Device-bound tap still reports rate different from selected stream in signed Plan 002 testing; buffered SRC needs separate architecture plan.
- Fix requires device nominal-rate writes, default-route writes, volume writes, realtime allocation, or public aggregate routing.
- Any verification fails twice after reasonable correction.

## Maintenance notes

Review request/output identity carefully: output changes already rebuild pipeline, so each rebuilt tap must bind new UID. Keep HRIR activation key and EQ preparation keyed to output rate. If multistream or multichannel support arrives later, replace fixed stream 0 only after output-stream discovery becomes part of descriptor contract.

