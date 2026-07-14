# Plan 002: Establish testable audio-runtime contracts

> **Executor instructions**: Build contracts and fakes only; do not call live
> process-tap APIs. Run each verification gate and update `plans/README.md`.
>
> **Drift check**: `git diff --stat f020179..HEAD -- Airwave AirwaveTests`
> Plan 001 is expected to change these paths. Confirm its DONE state and use its
> resulting safe shell as current state; otherwise stop.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-remove-legacy-routing.md`
- **Category**: tests / migration
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

The existing test suite covers DSP but not Core Audio lifecycle or the safety
invariant. A narrow, fakeable platform boundary lets later plans prove resource
ordering, retries, and native passthrough without touching live devices or TCC in
unit tests. The interface must make route and volume mutation impossible for
upper layers to request.

## Current state

- Before plan 001, `AudioGraphManager` combined device policy, HAL setup, DSP,
  output mutation, buffers, and callbacks in 1,130 lines.
- `RealtimeAudioProcessor.process(inputLeft:inputRight:leftOutput:rightOutput:frameCount:)`
  is the retained stereo DSP seam and accepts callbacks up to 4096 frames.
- Existing tests use protocol-backed fakes in onboarding and preset activation;
  follow that style rather than global mutable test hooks.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |

## Scope

**In scope**:

- New `AudioPlatformClient.swift`, `AudioPipeline.swift`, and focused tests.
- `AudioRuntimeState.swift` only to align state types.
- `HRIRManager`/`RealtimeAudioProcessor` only for dependency injection seams,
  without changing output math.

**Out of scope**:

- Concrete Core Audio API calls, UI, permissions, retries, docs, multichannel.
- Generic `AudioObjectSetPropertyData` exposure outside the future concrete HAL
  adapter.

## Git workflow

- Branch: `codex/002-audio-runtime-contracts`
- Commit example: `test(audio): define process-tap lifecycle contracts`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define platform values and error taxonomy

Define value types for read-only `OutputDeviceDescriptor` (ID, UID, name,
transport, output channel count, nominal sample rate, virtual/aggregate flags),
`AudioStreamFormat`, and opaque resource handles for tap, private aggregate, and
I/O callback. Define `AudioRuntimeError` cases for permission denied, no output,
unsupported output, tap creation, aggregate creation, format mismatch, I/O
creation/start, device loss, and cleanup. Do not put raw `AudioObjectID` in UI
state or persist it.

**Verify**: build command → succeeds.

### Step 2: Define a capability-oriented platform protocol

Create an `AudioPlatformClient` protocol with only these capabilities:

- read the current default output and observe changes;
- resolve Airwave's own audio-process object;
- create/destroy a private global stereo tap excluding Airwave;
- create/destroy a private aggregate containing the tap and current output;
- read stream formats;
- create/start/stop/destroy the I/O callback;
- open System Settings for system-audio recording permission.

Do not include methods to set a default device, set a volume, select an arbitrary
output, or perform untyped property writes. Make lifecycle calls throwing and
resource handles explicit so partial cleanup can be tested.

**Verify**:

`rg -n 'setDefault|set.*Volume|volumeScalar|route.*write' Airwave/AudioPlatformClient.swift`
→ no matches.

### Step 3: Define pipeline ownership and cleanup semantics

Create an `AudioPipeline` abstraction that owns resources in strict order:
tap → private aggregate → I/O callback. Its `start(on:)` either reaches running
or unwinds every acquired resource in reverse order. Its idempotent `stop()`
stops/destroys I/O, destroys the aggregate, then destroys the tap. The pipeline
accepts the retained stereo DSP processor through a protocol/closure and never
publishes UI state directly.

Use `CATapMutedWhenTapped` as an invariant in the future concrete client: native
audio must resume when the I/O reader disappears. Encode that requirement in the
tap creation request type now.

**Verify**: test command → new lifecycle tests pass.

### Step 4: Add exhaustive fake-driven lifecycle tests

Implement a recording fake that can fail each acquisition and teardown call.
Test successful order, idempotent stop, and reverse cleanup after failure at
every step. Add a compile-time/API-surface safety test or source audit test that
ensures upper layers have no default-output or volume-write capability.

**Verify**: test command → all tests pass without a TCC prompt.

## Test plan

- `AudioPipelineTests`: success ordering; fail after tap; fail after aggregate;
  fail after callback creation; fail on start; repeated stop; deinit cleanup.
- Assert tap requests are global stereo, exclude Airwave, private, and
  muted-when-tapped.
- Assert the physical output is an input to private-aggregate construction but
  is never a persisted preference.
- Model tests after the recording-fake style in
  `PresetActivationCoordinatorTests.swift`.

## Done criteria

- [ ] Upper layers cannot request default-output or volume mutation.
- [ ] All partial failures unwind acquired resources in reverse order.
- [ ] Stop is idempotent and leaves the fake with zero live resources.
- [ ] Tests run without live Core Audio, hardware dependence, or permission UI.
- [ ] Existing DSP output tests remain unchanged and pass.

## STOP conditions

- A required interface operation cannot be expressed without a generic public
  property setter; report the exact selector/use case.
- The retained DSP seam requires multichannel input for stereo operation.
- Plan 001 is not complete or legacy mutation APIs remain reachable.

## Maintenance notes

Keep platform mechanics, pipeline resource ownership, and runtime policy
separate. Review future protocol additions as security/safety-sensitive API
surface changes.

