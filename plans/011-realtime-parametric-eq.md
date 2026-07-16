# Plan 011: Implement the realtime parametric EQ processor

> **Executor instructions**: Implement and test DSP only. Do not wire UI or
> runtime readiness. Run every gate and update `plans/README.md` when complete.
>
> **Drift check (run first)**:
> `git diff --stat 28b0210..HEAD -- Airwave/AudioPipeline.swift Airwave/RealtimeAudioProcessor.swift Airwave/HRIRManager.swift AirwaveTests/RealtimeAudioProcessorTests.swift AirwaveTests/AudioPipelineTests.swift`
> Plan 010 is expected to add EQ model types; stop if those types do not match
> its Current state and Done criteria.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/010-equalizer-preset-library.md`
- **Category**: direction / tests
- **Planned at**: commit `28b0210`, 2026-07-16

## Why this matters

This phase is the sound-quality and realtime-safety core. It must reproduce the
approved EqualizerAPO filters without adding callback allocation, locks, or
unbounded work. Preset swaps must not click or restart Core Audio.

## Current state

- `Airwave/RealtimeAudioProcessor.swift` preallocates callback storage, accepts
  1...4096 frames, and provides the callback/canary test pattern to match.
- `Airwave/HRIRManager.swift:467-504` publishes immutable renderer objects under
  `OSAllocatedUnfairLock`, uses `withLockIfAvailable` on the render thread, and
  retains the prior snapshot when a writer owns the lock.
- `StereoAudioProcessing` in `Airwave/AudioPipeline.swift:3-11` is the narrow
  callback contract. Keep EQ independent from Core Audio resource ownership.
- EqualizerAPO's canonical Q formulas are in
  <https://github.com/mirror/equalizerapo/blob/master/filters/BiQuad.cpp>.
  Airwave is GPLv3 and may port the GPLv2-or-later equations with attribution.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| DSP tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/ParametricEqualizerProcessorTests test` | selected tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | `ANALYZE SUCCEEDED` |
| Safety | `scripts/test-audio-safety-invariants.sh` | passed messages |

## Scope

**In scope**: focused coefficient, biquad-cascade, transition/state-publication,
and EQ processor files; focused DSP tests; minimal protocol additions needed to
prepare a processor for an output sample rate.

**Out of scope**: parser/library behavior, Settings, runtime start/stop policy,
Core Audio platform calls, output/volume mutation, limiting, clipping,
normalization, auto-headroom, visualization, or editable bands.

## Git workflow

- Branch: `codex/011-realtime-parametric-eq`
- Suggested commit: `feat(audio): add realtime parametric equalizer`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Implement exact coefficient construction

Add normalized biquad coefficients (`b0`, `b1`, `b2`, `a1`, `a2`) and a builder
that accepts filter type, gain, frequency, Q, and sample rate. Port the official
EqualizerAPO Q path exactly: `A = 10^(gain/40)`, `alpha = sin(omega)/(2Q)`, and
the source's PK/low-shelf/high-shelf equations. Compute in `Double`, normalize
by `a0`, require finite coefficients, and require `0 < frequency < sampleRate/2`.
Do not reinterpret shelf Q as slope S.

Add a closed-form magnitude helper used only by tests. Golden tests must use
hard-coded expected coefficient/magnitude values produced independently from
the Swift implementation, not call the production builder twice.

**Verify**: DSP tests pass coefficient and DC/center/high-frequency checks for
PK, LSC, and HSC at 44.1, 48, and 96 kHz.

### Step 2: Implement a bounded stereo cascade

Use transposed direct-form II with independent left/right history per enabled
filter. Apply preamp once before the cascade using `10^(dB/20)`. Preserve file
order and exclude `OFF` filters. Use fixed contiguous storage sized for the
approved maximum of 64 filters and 4096 callback frames; allocate all storage
and construct all coefficients away from the callback.

Flush subnormal state values to zero using a small absolute threshold after
each state update. Do not clamp finite output or hide non-finite coefficient
construction. In-place input/output must be supported.

**Verify**: tests cover unity, preamp-only, known impulse responses, cascade
order, left/right isolation, in-place processing, subnormal flushing, and
canaries at all callback sizes used by `RealtimeAudioProcessorTests`.

### Step 3: Add non-blocking state publication

Create fully built processor states on a non-render thread. Publish the target
reference using the `HRIRManager` non-blocking snapshot pattern: the callback
attempts one `withLockIfAvailable`, retains the previous target on contention,
and is the only code that mutates filter histories after publication. Writers
must never mutate a published target.

Expose preparation for a concrete sample rate and selected definition. Invalid
Nyquist/configuration results are structured errors returned to callers; do
not publish a half-built state. A `.none` selection produces an explicit unity
target rather than `nil` ambiguity.

**Verify**: contention tests prove the callback continues with the prior state;
rapid target publication never produces non-finite samples or data races under
Thread Sanitizer when run manually.

### Step 4: Crossfade state changes over 20 ms

When the callback observes a new target generation, retain old and new states
and process the same input through both into preallocated scratch buffers. Mix
with a linear sample ramp lasting `max(1, round(sampleRate * 0.020))` frames,
continuing correctly across callback boundaries. After completion, release the
old state off the realtime path if ARC destruction could deallocate there;
use a preallocated retirement slot consumed by the control thread rather than
dispatching from the callback.

Transitions to/from the unity target use the same path. If another target
arrives mid-transition, start from the currently audible transition endpoint
without allocation; if that cannot be expressed with the bounded two-state
model, retain the newest pending target and begin it immediately after the
current 20 ms transition.

**Verify**: tests cover exact ramp length at multiple sample rates, callback
boundary splits, rapid queued changes, old/new endpoint accuracy, unity
transitions, and a bounded adjacent-sample discontinuity.

### Step 5: Verify realtime constraints and performance

Add a source safety assertion or extend the existing invariant script so the EQ
callback path contains no `Array` growth, setup construction, locks that wait,
logging, `DispatchQueue`, `Task`, filesystem/defaults access, or Core Audio
calls. Add a ten-second performance test with the ten-filter reference preset
at 128/512/1024-frame callback sizes; record timing but do not invent a release
threshold.

**Verify**: DSP tests, full tests, analyze, and safety commands all pass.

## Test plan

- Golden coefficient and magnitude tests for each approved type and sample rate.
- Reference CCA curve: finite output, correct preamp, ten active filters, and
  expected response at representative low/mid/high frequencies.
- Realtime tests: arbitrary callback sizes, canaries, stereo independence,
  in-place operation, contention, rapid publication, reset, crossfades, and
  ten-second performance measurement.

## Done criteria

- [ ] Filter math matches EqualizerAPO's Q semantics within documented numeric
  tolerances and shelf Q is never treated as slope.
- [ ] Callback work is bounded by frames × at most 64 enabled filters.
- [ ] No callback allocation, waiting lock, logging, or dispatch exists.
- [ ] Every target change is click-resistant through a 20 ms crossfade.
- [ ] DSP, full, analyze, and safety gates pass.

## STOP conditions

- Golden values disagree with the official EqualizerAPO equations after
  independent calculation.
- ARC requires unpredictable deallocation on the render thread and no bounded
  retirement handoff can avoid it.
- Supporting 64 filters violates callback safety or causes buffer overruns.
- The implementation requires changing Core Audio lifecycle or volume policy.

## Maintenance notes

Any new filter type needs official-format semantics, independent golden values,
and realtime cost review. Review changes to the publication/retirement path as
render-thread safety changes, not ordinary state-management refactors.

