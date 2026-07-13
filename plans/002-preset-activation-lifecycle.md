# Plan 002: Make preset activation cancellable, deduplicated, and latest-wins

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm expected result before moving on. If a STOP condition occurs, stop and report; do not improvise. When done, update this plan's row in `plans/README.md`, unless reviewer maintains index.
>
> **Drift check (run first)**:
> `git diff --stat 3592756..HEAD -- Airwave/HRIRManager.swift Airwave/AudioGraphManager.swift Airwave/MenuBarViewModel.swift Airwave/AirwaveMenuView.swift Airwave/SettingsView.swift Airwave/VirtualSpeaker.swift Airwave/PresetActivationCoordinator.swift AirwaveTests/PresetActivationCoordinatorTests.swift`
> Plan 001 intentionally changes `HRIRManager.swift` and `AudioGraphManager.swift`; execute this plan only after Plan 001 is DONE, then reconcile excerpts with its final code. Unexpected changes elsewhere are a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-realtime-audio-hardening.md`
- **Category**: perf, bug
- **Planned at**: commit `3592756`, 2026-07-14

## Why this matters

Every `activatePreset` call launches independent background work that reads the whole WAV, optionally resamples it, creates FFT-backed convolvers, and publishes unconditionally. Re-selecting, starting engine, or switching presets can duplicate this work; an older slow request can finish after a newer request and overwrite user selection. Plan 001 also makes renderer state authoritative inside processing, so direct `activePreset = nil` writes must become a real deactivation API that clears pending work and renderer state together.

## Current state

- `Airwave/HRIRManager.swift` — activation, WAV loading, resampling, renderer construction, and publication are one method.
- `Airwave/AudioGraphManager.swift` — `start()` calls `activatePreset` again after Audio Unit setup.
- `Airwave/MenuBarViewModel.swift`, `Airwave/AirwaveMenuView.swift`, `Airwave/SettingsView.swift` — restoration and selection call activation; “None” directly sets `activePreset = nil`.
- `Airwave/VirtualSpeaker.swift` — `VirtualSpeaker` is already `Hashable`; `InputLayout` contains `[VirtualSpeaker]` and a display name.

Current asynchronous launch (`Airwave/HRIRManager.swift:180-192`):

```swift
func activatePreset(...) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        let wavData = try WAVLoader.load(from: preset.fileURL)
        // resample and build every renderer
```

Current unconditional publication (`Airwave/HRIRManager.swift:268-276`):

```swift
let newState = RendererState(renderers: newRenderers, blockSize: self.processingBlockSize)
self.rendererState = newState
DispatchQueue.main.async {
    self.activePreset = preset
    self.currentInputLayout = inputLayout
    self.currentHRIRMap = channelMap
}
```

Current duplicate start path (`Airwave/AudioGraphManager.swift:168-180`):

```swift
try setupAudioUnit(device: device, outputChannelRange: selectedOutputChannelRange)
if let hrirManager = hrirManager, let activePreset = hrirManager.activePreset {
    hrirManager.activatePreset(activePreset,
        targetSampleRate: currentSampleRate,
        inputLayout: InputLayout.detect(channelCount: Int(inputChannelCount)))
}
```

Current direct deactivation examples: `Airwave/AirwaveMenuView.swift:392-397` and `Airwave/SettingsView.swift:392-401`.

Conventions to preserve:

- User-visible published properties change on main actor/main queue.
- Heavy WAV/resample/FFT work remains off main thread.
- Existing localized errors flow through `errorMessage`; cancellation is not user-visible failure.
- Renderer publication must use Plan 001's immutable/non-blocking snapshot mechanism.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **` |
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/PresetActivationCoordinatorTests` | exit 0; target suite passes |

## Scope

**In scope**:

- `Airwave/HRIRManager.swift`
- `Airwave/AudioGraphManager.swift`
- `Airwave/MenuBarViewModel.swift`
- `Airwave/AirwaveMenuView.swift`
- `Airwave/SettingsView.swift`
- `Airwave/VirtualSpeaker.swift` only for narrowly scoped `Hashable`/key support
- `Airwave/PresetActivationCoordinator.swift` (create if separation improves testability)
- `AirwaveTests/PresetActivationCoordinatorTests.swift` (create)

**Out of scope**:

- DSP math, frame adapter, callback pointer mechanics, and state handoff implementation from Plan 001.
- Preset directory watcher, metadata JSON format, file deletion behavior except invoking deactivation when active file disappears.
- New UI, progress indicators, new dependencies, or changing HeSuVi mapping.
- Device enumeration and contributor workflow from Plan 003.

## Git workflow

- Branch: `codex/002-preset-activation-lifecycle`
- Commit message: `perf: coordinate preset activation lifecycle`.
- Do not push/open PR unless instructed.

## Steps

### Step 1: Extract activation identity and injectable builder boundary

Create an internal activation key containing:

- `preset.id`
- canonical `preset.fileURL`
- target sample rate represented without lossy rounding
- ordered `inputLayout.channels`

All current call sites pass `hrirMap: nil`; default-map requests with same key are deduplicable. Treat a non-nil custom `hrirMap` as non-deduplicable unless you add a deterministic, tested mapping signature. Do not silently consider distinct custom maps equal.

Extract renderer construction behind an internal async/cancellable builder boundary. Production builder may still call synchronous `WAVLoader.load`, but it must check cancellation:

1. Before file load.
2. Immediately after file load.
3. Between renderer/channel builds.
4. Before constructing/publishing final state.

Tests must inject a fake builder; no test reads actual HRIR files.

**Verify**: run Build command. Expected: build succeeds with same app behavior.

### Step 2: Implement one latest-wins activation coordinator

Maintain exactly one in-flight activation task and monotonically increasing generation/token.

Required behavior:

- Request matching current published key: return without rebuild.
- Request matching current in-flight key: return without starting second task.
- Different request: cancel old task, increment generation, start new task.
- Completion publishes only when its generation still equals latest generation and task is not cancelled.
- Stale success, stale failure, and cancellation cannot change `rendererState`, `activePreset`, layout/map, or `errorMessage`.
- Latest non-cancellation failure sets `errorMessage` but leaves state internally consistent. Do not label failed preset active.
- All UI-published state changes occur on main actor.
- Actor/task ownership must not retain `HRIRManager` forever.

Write deterministic tests using controllable fake builders:

1. Two identical requests invoke builder once.
2. Slow A then fast B publishes B only.
3. Stale A failure after B success does not replace B error/state.
4. Cancellation produces no user-visible error.
5. Same preset with changed sample rate rebuilds.
6. Same preset with changed ordered input channels rebuilds.

**Verify**: run Targeted tests. Expected: all six behaviors pass.

### Step 3: Add explicit deactivation

Add one public/main-actor `deactivatePreset()` API that atomically, from application perspective:

- Cancels current activation.
- Invalidates its generation.
- Clears published renderer state through Plan 001 handoff.
- Sets `activePreset`, `currentInputLayout`, and `currentHRIRMap` to nil.
- Clears only activation-related error state.
- Resets queued DSP/FIFO history so reactivation cannot emit old samples.

Replace all direct `activePreset = nil` assignments in menu, settings, preset removal, and directory reconciliation with this API. Remove duplicate consecutive nil assignments currently present in `HRIRManager.removePreset` and directory sync.

Test that deactivation during an in-flight build prevents later publication and processing falls back to passthrough/silence contract defined by Plan 001.

**Verify**:

`rg -n 'activePreset\s*=\s*nil' Airwave --glob '*.swift'`

Expected: only assignment inside `deactivatePreset()` (or its single private helper) remains.

Then run All tests. Expected: all pass.

### Step 4: Stop rebuilding unchanged presets during engine start

Replace `AudioGraphManager.start()`'s unconditional activation with an idempotent “ensure configuration” request using actual `currentSampleRate` and detected input layout.

- If published activation key matches device sample rate/layout, reuse renderer state; do no WAV/resample/FFT work.
- If configuration differs, invalidate mismatched renderer state before audio starts, begin rebuild, and let Plan 001's defined passthrough/silence behavior operate until matching state publishes. Never convolve using renderer built for wrong sample rate/layout.
- Preserve engine start error behavior and system-output safety sequence.
- UI selection and state restoration must call same coordinator path, not bypass it.

Add tests showing repeated start/ensure with same key causes zero additional builds, while changed sample rate causes exactly one additional build.

**Verify**: run Targeted tests, then All tests. Expected: both succeed.

### Step 5: Validate lifecycle manually

With a real preset and engine running:

1. Select A, immediately B, immediately A. Final visible/active preset must be last A.
2. Toggle engine off/on with unchanged device. No second preset preparation should be logged or profiled.
3. Select None during a load. Load must never reactivate later.
4. Change aggregate device/sample rate. Old renderer must not process new-rate audio; app uses bounded passthrough/silence until rebuild completes.
5. Remove active preset file. State deactivates cleanly.

Use temporary DEBUG-only counters or signposts if needed, but do not leave noisy per-callback logs.

**Verify**: run Build and All tests. Expected: both succeed; manual cases match above.

## Test plan

- `PresetActivationCoordinatorTests.swift` uses fake builder with manually resumed continuations/tasks.
- Test identical-key dedupe, generation ordering, stale errors, cancellation, deactivation, sample-rate/layout key changes, and engine ensure behavior.
- Existing Plan 001 DSP tests must remain green.
- No tests depend on user presets folder or external WAV downloads.

## Done criteria

- [ ] Build and full test commands succeed.
- [ ] Exactly one activation task may be in flight.
- [ ] Identical current/in-flight keys do not rebuild.
- [ ] Only latest generation may publish success or failure.
- [ ] Deactivation cancels, invalidates, clears renderer/UI state, and resets buffered audio.
- [ ] No UI file directly assigns `activePreset = nil`.
- [ ] Engine restart with unchanged key performs no renderer rebuild.
- [ ] Changed sample rate/layout never uses mismatched renderer.
- [ ] `git diff --name-only` contains only in-scope files plus plan status update.
- [ ] `plans/README.md` row 002 updated.

## STOP conditions

Stop and report if:

- Plan 001 is not DONE or its renderer-state API cannot support clean state invalidation.
- Current call sites use non-nil custom HRIR maps; key semantics require product decision.
- Cancellation requires aborting inside an uninterruptible framework call; keep cooperative checks around call, do not invent unsafe interruption.
- Correct latest-wins behavior requires blocking render thread.
- Change requires preset metadata migration or UI redesign.
- Any verification fails twice after reasonable correction.
- Out-of-scope file becomes necessary.

## Maintenance notes

- Future activation inputs—block size, gain, custom map, quality mode—must join activation key or explicitly force rebuild.
- Reviewer should force out-of-order fake completions; ordinary happy-path tests will miss stale publication.
- Cancellation saves work only at cooperative boundaries; full synchronous WAV read may finish before cancellation is observed. Correctness requirement is stale result never publishes.

