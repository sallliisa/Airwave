# Plan 004: Add always-on output following and recovery

> **Executor instructions**: Implement runtime policy around the proven backend.
> Do not add a user engine toggle. Update the index after all gates pass.
>
> **Drift check**: `git diff --stat f020179..HEAD -- Airwave AirwaveTests`
> Confirm plan 003 is DONE and its manual tap teardown check passed.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/003-process-tap-backend.md`
- **Category**: correctness / migration
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

Airwave 2.0 must behave like a safe always-on utility rather than a route users
manually manage. This phase follows the macOS default output, recovers from
transient changes, sleep/wake, and invalidation, and exposes one authoritative
runtime state. Native audio remains audible during every transition or failure.

## Current state

- Plan 003 provides a single-device stereo `AudioPipeline` with deterministic
  cleanup but no policy.
- Product decisions: automatic start while app is running and ready; bounded
  automatic retry; unsupported outputs and failures fail open; current output is
  read-only status; no remembered engine state.
- Existing `PresetActivationCoordinator` already uses generation/cancellation to
  ensure stale preset work does not publish; use that pattern for route rebuilds.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | succeeds |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | succeeds |

## Scope

**In scope**:

- New `AudioRuntimeController.swift` and tests.
- `AudioRuntimeState.swift`, app lifecycle wiring, output observation, sleep/wake
  notifications, preset-readiness observation.
- `AudioPipeline` only for cancellation/invalidation hooks required by policy.

**Out of scope**:

- Menu/settings/onboarding layout, persistence migration, docs.
- Manual output selection, engine toggle, per-app capture, multichannel.

## Git workflow

- Branch: `codex/004-always-on-recovery`
- Commit example: `feat(audio): follow default output safely`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define the runtime state machine

Make `AudioRuntimeController` the sole writer of `AudioRuntimeState`. Events:
app launched, setup/preset readiness changed, permission result, default output
changed, pipeline started, pipeline invalidated, sleep, wake, retry fired, and
app terminating. States must distinguish needs setup/permission, native
passthrough with actionable reason, starting, processing with read-only output
descriptor, and recovering.

Only publish `processing` after the full tap/aggregate/I/O pipeline starts. On
any error, stop the pipeline first so muted-when-tapped releases native audio,
then publish passthrough/recovering.

**Verify**: transition-table unit tests pass.

### Step 2: Start automatically when ready

At app launch, if a valid HRIR preset exists and system-audio capture succeeds,
start against the current default output. There is no public start/stop API and
no `autoStart`/`isRunning` preference. Preset activation/replacement must rebuild
or atomically swap DSP configuration without exposing stale output; if it fails,
return to native audio and report the preset error.

**Verify**: fake-driven tests show ready launch starts once; missing preset or
permission does not create live resources.

### Step 3: Follow default-output changes transactionally

Observe the system default output read-only. On change, invalidate the prior
generation, stop its pipeline (restoring native playback), resolve/validate the
new output, then start a new pipeline. Stale callbacks and retries must not
publish state or tear down the newest generation. Never stay on the old device.

Known virtual outputs, public aggregate/multi-output devices, mono devices, and
unsupported formats produce a blocking health reason instructing the user to
change output in macOS; Airwave itself does not change it.

**Verify**: tests cover A→B, rapid A→B→C, disconnect, reconnect with a new live
ID, virtual output, mono output, and stale start completion.

### Step 4: Add bounded recovery

For transient HAL failures, permission restoration, wake, and reconnect, retry
automatically with cancellable exponential backoff (1, 2, 4, 8, then 15 seconds
maximum) and reset backoff after 30 seconds of stable processing. Keep native
audio during the entire retry period. Permanent unsupported-output and explicit
permission-denied states do not spin; resume when their observed condition
changes or the user invokes a Retry action from health UI.

**Verify**: use a fake clock/scheduler; tests contain no real sleeps and prove
backoff, cancellation, reset, and no retry storm.

### Step 5: Handle lifecycle and interruption events

On sleep, stop and release the pipeline before suspension. On wake, wait for a
valid default output and enter bounded recovery. On termination, stop resources
without signal interception or route/volume restoration. If the process is force
terminated, muted-when-tapped must cause native playback to resume by OS design;
manual validation belongs to plan 006.

**Verify**: lifecycle tests show zero live fake resources after sleep/terminate
and one current pipeline after wake recovery.

## Test plan

- State transition table for every event/state pair that can occur in practice.
- Generation cancellation and stale callback protection.
- Fake-scheduler recovery sequence and stable-period reset.
- Output support matrix policy and actionable error mapping.
- No default-output/volume write capability exists in controller dependencies.

## Done criteria

- [ ] Ready launch begins processing without a user toggle.
- [ ] Every failure stops reading before publishing passthrough/recovery.
- [ ] Output changes follow macOS automatically and never select a route.
- [ ] Retry is bounded, cancellable, and fake-clock tested.
- [ ] Sleep/wake and termination release resources deterministically.
- [ ] One runtime state feeds all later UI consumers.

## STOP conditions

- Any transition can leave the tap actively read while output is unavailable.
- Output observation requires changing the output property.
- Retry needs a second independent state machine in UI code.
- A force-termination manual check from plan 003 did not restore native audio.

## Maintenance notes

Review generation ownership and cleanup before UI polish. A state that says
`processing` while resources are incomplete is a release-blocking defect.

