# Plan 003: Implement the stereo process-tap backend

> **Executor instructions**: Implement only the concrete platform client and
> stereo callback bridge. Do not build retry/UI policy. Run all gates and update
> the index.
>
> **Drift check**: `git diff --stat f020179..HEAD -- Airwave AirwaveTests Airwave.xcodeproj`
> Confirm plans 001 and 002 are DONE and their contracts match this plan.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/002-audio-runtime-contracts.md`
- **Category**: migration
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

This is the replacement audio backend. It captures the global stereo mix,
excludes Airwave to prevent feedback, mutes originals only while the tap is
actively read, processes through the retained HRIR DSP, and renders to the
current default output. It must never select the private aggregate as the macOS
default and must never touch volume.

## Current state

- Apple's process-tap API is available from macOS 14.2; this project targets 15.
- Apple documents the tap as an input in a HAL aggregate device and requires
  `NSAudioCaptureUsageDescription`:
  <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>
- `CATapDescription` defines `mutedWhenTapped`: original hardware playback is
  muted only while another client reads the tap.
- The retained DSP accepts noninterleaved stereo Float32 and arbitrary callback
  sizes up to 4096.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | succeeds |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | succeeds |

## Scope

**In scope**:

- Concrete `CoreAudioPlatformClient.swift` and callback/buffer helpers.
- `AudioPipeline.swift` only to connect the concrete client to stereo DSP.
- Info.plist usage description and entitlements required by verified Apple
  process-tap behavior.
- Unit tests for pure format/buffer helpers and one opt-in manual integration
  harness that is excluded from normal CI.

**Out of scope**:

- Default-output observation policy, retries, sleep/wake, UI, app settings.
- Per-app capture, multichannel, virtual/public aggregate support.
- Any default-output or volume write.

## Git workflow

- Branch: `codex/003-process-tap-backend`
- Commit example: `feat(audio): add private process-tap pipeline`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Implement process identity and tap creation

Resolve the current PID to its Core Audio process object. Build a private global
stereo `CATapDescription` that excludes only Airwave, sets
`muteBehavior = .mutedWhenTapped`, and has a unique stable-in-process UID/name.
Create with `AudioHardwareCreateProcessTap`; validate every `OSStatus` and retain
the handle only after success. Do not use macOS 26-only `bundleIDs` or process
restoration.

**Verify**: build and analyze commands → succeed.

### Step 2: Create the private aggregate as an internal graph

Create a private aggregate containing the tap and the current physical default
output, with tap autostart and appropriate drift compensation/clock ownership.
It must be invisible outside Airwave and never be passed to a default-device
property setter. Reject known virtual outputs, public aggregate/multi-output
devices, mono outputs, and formats the stereo bridge cannot safely render; return
`unsupportedOutput` so policy can fail open.

**Verify**: recording/integration harness confirms the system default output ID
before creation equals the ID after creation and after teardown.

### Step 3: Bridge input, DSP, and physical output

Create a HAL I/O callback on the private aggregate. Pull the tap's noninterleaved
stereo Float32 input, adapt interleaved/format differences outside the DSP core,
invoke `RealtimeAudioProcessor`, and write stereo only to the current physical
output channels. Preallocate all callback buffers; perform no allocation,
locking, logging, Objective-C messaging, collection mutation, or async dispatch
on the real-time thread. If a callback is oversized or invalid, zero only
Airwave's output buffer and return an error without corrupting memory.

Apply hardware volume exactly once by rendering through the selected physical
device; do not read, copy, normalize, or write volume scalars.

**Verify**: callback unit tests cover mono rejection, stereo mapping, interleaved
conversion if supported, oversized callbacks, and silence on invalid input.

### Step 4: Implement deterministic teardown and partial-failure cleanup

Stop and destroy the I/O callback before destroying the private aggregate, then
destroy the tap. Make every operation idempotent and tolerate already-gone HAL
objects during cleanup while preserving the first meaningful startup/runtime
error. Confirm all paths satisfy plan 002's fake lifecycle tests.

**Verify**: full test command → all pass; manual harness leaves no private
aggregate/tap after normal stop.

### Step 5: Replace microphone metadata with system-audio capture metadata

Add `NSAudioCaptureUsageDescription` with plain language explaining HRIR
processing. Remove `NSMicrophoneUsageDescription` and microphone-specific code/
entitlements unless the Apple sample and signed integration test prove an audio-
input entitlement is still required for the tap aggregate. Record the result in
a code comment beside the entitlement, not as lore in UI code.

**Verify**: `plutil -p Airwave/Info.plist | rg 'NSAudioCaptureUsageDescription'`
→ one match; `rg -n 'NSMicrophoneUsageDescription|AVCaptureDevice' Airwave`
→ no matches.

## Test plan

- Keep all plan 002 fake lifecycle tests.
- Add pure tests for OSStatus mapping, stream format validation, channel mapping,
  buffer bounds, and teardown tolerance.
- Add an opt-in signed/manual integration test that creates the tap, observes the
  permission prompt, processes a known stereo signal, asserts output/default
  device identity never changes, and verifies resource removal.
- Normal CI must not require permission or audio hardware.

## Done criteria

- [ ] Global stereo tap excludes Airwave and uses muted-when-tapped behavior.
- [ ] Private aggregate is never a macOS default or user-visible preference.
- [ ] No volume selector or default-output write exists.
- [ ] Callback path is bounded, preallocated, and covered by buffer tests.
- [ ] Every partial failure and stop releases all resources.
- [ ] System-audio permission metadata is correct for macOS 15.

## STOP conditions

- Signed macOS 15 testing shows the sandbox/entitlement combination cannot
  create or read a process tap.
- The private aggregate becomes visible or changes the system default.
- Native audio remains muted after the I/O reader stops or the process exits.
- A supported output requires volume mutation or a public aggregate.
- Apple behavior differs from the cited documentation; record OS build, device,
  and exact OSStatus and report.

## Maintenance notes

Review all callback changes for allocations and bounds. The generic Core Audio
property helper, if needed, must remain private to this file; upper layers use
typed capabilities only.

