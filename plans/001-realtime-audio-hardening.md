# Plan 001: Make real-time audio processing frame-safe and non-blocking

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report; do not improvise. When done, update this plan's status row in `plans/README.md`, unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 3592756..HEAD -- Airwave.xcodeproj/project.pbxproj Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme Airwave/AudioGraphManager.swift Airwave/HRIRManager.swift Airwave/ConvolutionEngine.swift Airwave/RealtimeAudioProcessor.swift AirwaveTests`
> If any in-scope file changed, compare the excerpts below with live code. Any material mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: none
- **Category**: perf, bug, tests
- **Planned at**: commit `3592756`, 2026-07-14

## Why this matters

Airwave's CoreAudio callback promises preallocated processing, but active convolution allocates pointer storage and takes blocking locks every callback. DSP accepts arbitrary `frameCount`, yet processes only full 512-frame chunks; callbacks below 512 or trailing remainders leave stale samples that are later copied to output. The fixed 4096-frame capacity is enforced only in Debug, allowing Release buffer overflow if CoreAudio exceeds it. This plan first creates hardware-independent DSP regression tests, then adds a preallocated frame adapter and a non-blocking renderer-state snapshot path.

## Current state

- `Airwave/ConvolutionEngine.swift` — fixed-block UPOLS engine; `process` requires exactly `blockSize` samples.
- `Airwave/HRIRManager.swift` — owns renderers, temporary buffers, state locks, and callback-facing `processAudio`.
- `Airwave/AudioGraphManager.swift` — owns HAL Audio Unit, preallocated I/O buffers, and global render callback.
- `Airwave.xcodeproj/project.pbxproj` — contains one application target and no test target.
- `Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme` — shared scheme has an empty `TestAction`.

Current fixed-block loop (`Airwave/HRIRManager.swift:334-386`):

```swift
var offset = 0
while offset + processingBlockSize <= frameCount {
    let currentLeftOut = leftOutput.advanced(by: offset)
    let currentRightOut = rightOutput.advanced(by: offset)
    // ...process exactly processingBlockSize frames...
    offset += processingBlockSize
}
```

When `frameCount == 128`, loop executes zero times. When `frameCount == 768`, final 256 output frames are never written.

Current callback allocation (`Airwave/AudioGraphManager.swift:842-858`):

```swift
let shouldProcess = manager.hrirManager?.isConvolutionActive ?? false
if shouldProcess, let channelPtrs = manager.inputChannelBufferPtrs {
    let stereoInputPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
    defer { stereoInputPtrs.deallocate() }
    stereoInputPtrs[0] = channelPtrs[leftInputChannel]
    stereoInputPtrs[1] = channelPtrs[rightInputChannel]
    manager.hrirManager?.processAudio(inputPtrs: stereoInputPtrs, inputCount: 2, ...)
}
```

Current state access (`Airwave/HRIRManager.swift:105-115, 308-313`):

```swift
private let stateLock = OSAllocatedUnfairLock<RendererState?>(initialState: nil)
private let stateVersion = OSAllocatedUnfairLock<Int>(initialState: 0)

let currentVersion = stateVersion.withLock { $0 }
if currentVersion != AudioThreadCache.cachedVersion {
    AudioThreadCache.cachedState = stateLock.withLock { $0 }
}
```

Current capacity guard (`Airwave/AudioGraphManager.swift:788-793`) exists only under `#if DEBUG`.

Conventions to preserve:

- DSP buffers use explicitly allocated `UnsafeMutablePointer<Float>` storage and release it in `deinit`; follow `ConvolutionEngine.swift:101-138, 199-224`.
- Vector math uses Accelerate/vDSP; follow `ConvolutionEngine.process` rather than scalar sample loops where a vDSP primitive exists.
- Callback failures return an `OSStatus` and write silence when safe; do not log, dispatch, allocate, or throw from the render thread.
- Existing app target uses Swift 5 language mode with default main-actor isolation. Do not silence concurrency errors with broad `nonisolated(unsafe)` annotations.

## Commands you will need

Full Xcode is required. This audit environment had only Command Line Tools; if `/Applications/Xcode.app` is absent, set `DEVELOPER_DIR` to an installed Xcode 26 path.

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **` |
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/RealtimeAudioProcessorTests` | exit 0; target suite passes |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | exit 0; `** ANALYZE SUCCEEDED **` |

## Suggested executor toolkit

- Use Instruments' Allocations and Time Profiler templates for manual callback validation after automated gates pass.
- For non-blocking state snapshots, use Apple's `OSAllocatedUnfairLock.withLockIfAvailable`; do not use raw `os_unfair_lock` from Swift: <https://developer.apple.com/documentation/os/osallocatedunfairlock>.

## Scope

**In scope** — only these files may change:

- `Airwave.xcodeproj/project.pbxproj`
- `Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme`
- `Airwave/AudioGraphManager.swift`
- `Airwave/HRIRManager.swift`
- `Airwave/ConvolutionEngine.swift` only if a small internal test seam is necessary
- `Airwave/RealtimeAudioProcessor.swift` (create)
- `AirwaveTests/ConvolutionEngineTests.swift` (create)
- `AirwaveTests/RealtimeAudioProcessorTests.swift` (create)

**Out of scope**:

- Preset loading, cancellation, deduplication, or UI selection; Plan 002 owns these.
- Device enumeration, routing policy, volume behavior, and aggregate-device inspection.
- FFT algorithm replacement, HRIR channel-map changes, or audible gain retuning.
- New third-party dependencies, including `swift-atomics`.
- App UI and settings persistence.

## Git workflow

- Branch: `codex/001-realtime-audio-hardening`
- Commit logical units. Use Conventional Commits, e.g. `test: add DSP regression baseline`, then `perf: harden real-time audio pipeline`.
- Do not push or open a PR unless operator instructs it.

## Steps

### Step 1: Add hardware-independent XCTest baseline

Add an `AirwaveTests` unit-test target and include it in shared scheme's `TestAction`. Do not require microphone permission, BlackHole, aggregate devices, fixtures from user folders, or live CoreAudio hardware.

Create `ConvolutionEngineTests.swift` with generated sample arrays covering:

1. Impulse IR `[1, 0, ...]` preserves sample order within numerical tolerance.
2. Reset clears overlap and frequency-delay history.
3. Multiple blocks produce finite samples; no NaN or infinity.
4. Identical input after reset produces identical output.

Use small power-of-two block sizes such as 8 or 16 for correctness tests. Use `@testable import Airwave`; do not make production symbols public only for tests.

**Verify**: run All tests command. Expected: test target builds; all new convolution tests pass.

### Step 2: Add a preallocated arbitrary-frame adapter

Create `RealtimeAudioProcessor.swift`. It must adapt arbitrary callback sizes to `ConvolutionEngine`'s fixed 512-frame contract without changing `ConvolutionEngine.process` semantics.

Required design:

- Allocate all input accumulation, block output, temporary mix, and output FIFO storage during processor/state initialization.
- Maintain pending input count across callbacks for each active input channel.
- When a full 512-frame input block exists, run all current left/right convolution engines and append one stereo block to the preallocated output FIFO.
- Drain exactly `frameCount` samples into both output pointers on every call. If initial FIFO data is unavailable, write zeros; never leave stale output.
- Preserve stream order across callback sequences. A sequence of callback sizes `[128, 128, 128, 128]` must yield the same ordered steady-state samples as one 512-frame callback, allowing only documented initial buffering latency.
- Support every `frameCount` from 1 through `maxFramesPerCallback` and callback sizes larger than one DSP block.
- Provide `reset()` that clears pending input, queued output, and every convolver's history.
- Processing method must not create `Array`, `Data`, `UnsafeMutablePointer.allocate`, `DispatchQueue`, `Task`, locks, logs, or autoreleased Foundation objects.

Integrate one processor into each immutable `RendererState`; do not keep FIFO indices as global/static state.

Create `RealtimeAudioProcessorTests.swift` covering callback sizes `1`, `64`, `128`, `256`, `511`, `512`, `513`, `768`, `1024`, and `4096`; mixed sequences whose total exceeds several blocks; reset mid-stream; silence underflow; mono duplication; and canary regions before/after buffers to detect out-of-bounds writes.

**Verify**: run Targeted tests command. Expected: every listed frame-size test passes and canaries remain unchanged.

### Step 3: Make renderer snapshots non-blocking

Replace two-lock/version/static-cache flow with one per-instance audio-thread cache:

- Keep published `RendererState?` protected by `OSAllocatedUnfairLock<RendererState?>` for writers.
- At callback entry, attempt `withLockIfAvailable` once. If acquired, retain returned immutable state in a per-`HRIRManager` audio-thread cache. If unavailable, continue with previous cached state for this callback; never block waiting for writer.
- Remove `stateVersion`, `AudioThreadCache` static storage, and callback's separate `isConvolutionActive` lookup.
- Ensure only render thread mutates audio-thread cache. State lifetime must remain protected by a strong reference while processing.
- A cleared state may take one extra callback to become visible under contention; that bounded behavior is acceptable. A data race or use-after-free is not.
- Do not replace this with an unsynchronized optional reference or raw `os_unfair_lock`.

Add tests with a controllable state writer showing failed try-lock reuses prior state and later successful snapshot observes new state. If this cannot be tested without exposing unsafe production internals, extract a small internal `RendererStateSnapshot` helper and test that.

**Verify**: run All tests command. Expected: all tests pass. Then run:

`rg -n 'stateVersion|AudioThreadCache|stateVersion\.withLock' Airwave/HRIRManager.swift`

Expected: no matches.

### Step 4: Remove callback allocation and enforce Release bounds

In `renderCallback`:

- Pass selected stereo input pointers without allocating a temporary pointer array. Prefer two explicit pointer parameters because current callback always sends stereo. If retaining a collection API, back it with storage allocated in `AudioGraphManager.init`, never callback-local heap storage.
- Always validate `frameCount <= maxFramesPerCallback` in Debug and Release before configuring buffer byte sizes or copying memory. On violation, zero only buffers whose declared capacity is known safe and return `kAudioUnitErr_TooManyFramesToProcess`.
- Set/query `kAudioUnitProperty_MaximumFramesPerSlice` during Audio Unit setup so capacity and Audio Unit contract agree. If device refuses configured maximum, setup must fail with a descriptive `AudioError` instead of starting with mismatched buffers.
- Validate selected input and output ranges in Release before pointer indexing. Invalid ranges return silence, not assertion-only behavior.
- Always write both stereo staging outputs for exactly `frameCount` frames before output copy.

**Verify**: run All tests and Build commands. Expected: both succeed. Then run:

`rg -n 'allocate\(capacity: 2\)|defer \{ stereoInputPtrs\.deallocate\(\) \}' Airwave/AudioGraphManager.swift`

Expected: no matches.

### Step 5: Add repeatable performance guards

Add XCTest performance cases that process at least 10 seconds of generated stereo input in Release-compatible code paths using 128-, 512-, and 1024-frame callbacks. Record baseline locally, but avoid brittle absolute wall-clock assertions tied to one machine. Automated assertions should verify:

- No output NaN/infinity.
- Exact processed frame count.
- No canary corruption.
- Mixed callback-size output order matches fixed-size reference within floating-point tolerance after accounting for initial adapter latency.

Run app manually with an active preset under Instruments Allocations. Inspect render-thread stack for at least 30 seconds. There must be no repeated allocation originating from `renderCallback`, `HRIRManager.processAudio`, or `RealtimeAudioProcessor.process`.

**Verify**: run All tests and Analyze commands. Expected: both succeed; manual Instruments observation reports zero recurring callback-path allocations.

## Test plan

- `AirwaveTests/ConvolutionEngineTests.swift`: fixed-block DSP characterization and reset behavior.
- `AirwaveTests/RealtimeAudioProcessorTests.swift`: arbitrary sizes, mixed sizes, FIFO ordering, underflow silence, reset, finite output, mono behavior, and bounds canaries.
- No live hardware tests in this plan. CoreAudio setup remains covered by build/analyze plus manual app smoke test.
- Required manual smoke test: active preset, engine start/stop, switch output, and 30 seconds playback at device buffer sizes 128 and 512 when hardware permits. Expected: no clicks, repeated fragments, crashes, or callback allocations.

## Done criteria

- [ ] `xcodebuild ... build` exits 0 with `** BUILD SUCCEEDED **`.
- [ ] `xcodebuild ... test` exits 0 with `** TEST SUCCEEDED **`.
- [ ] `xcodebuild ... analyze` exits 0 with `** ANALYZE SUCCEEDED **`.
- [ ] Tests cover all required callback sizes and mixed-size sequences.
- [ ] Callback writes or deliberately silences every requested output frame.
- [ ] Release path rejects frames above allocated capacity before any copy/write.
- [ ] No `allocate(capacity: 2)` remains in render callback.
- [ ] No blocking `withLock` remains on render path; state access uses one `withLockIfAvailable` attempt.
- [ ] Instruments shows no recurring allocation from callback-path symbols over 30 seconds.
- [ ] `git diff --name-only` contains only in-scope files plus `plans/README.md` status update.
- [ ] `plans/README.md` row 001 updated.

## STOP conditions

Stop and report if:

- In-scope code materially differs from excerpts after drift check.
- Full Xcode 26 cannot build current `main` before changes.
- `ConvolutionEngine` fails basic impulse/reset characterization before adapter work; do not hide an existing DSP defect with loose tolerances.
- Safe arbitrary-frame adaptation requires changing convolution gain, FFT partition math, or HRIR mapping.
- Non-blocking state access appears to require an unsynchronized reference, raw Swift `os_unfair_lock`, or new dependency.
- Audio Unit reports a maximum slice larger than supported capacity and cannot be configured safely.
- Any verification fails twice after one reasonable correction.
- Fix requires an out-of-scope file.

## Maintenance notes

- Any future DSP block-size setting must resize all adapter/FIFO/state buffers together and rerun every mixed-size test.
- Reviewer should scrutinize pointer lifetime, FIFO wraparound, initial latency, Release-only bounds, and thread ownership more than style.
- `withLockIfAvailable` intentionally permits one callback of stale immutable renderer state; document this near code.
- Preset generation/cancellation and clean deactivation are deferred to Plan 002.

