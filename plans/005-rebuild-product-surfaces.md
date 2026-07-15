# Plan 005: Rebuild settings, menu, onboarding, and persistence

> **Executor instructions**: Consume the runtime controller as the single source
> of truth. Do not recreate routing or permission logic in views. Update the
> index after verification.
>
> **Drift check**: `git diff --stat f020179..HEAD -- Airwave AirwaveTests`
> Confirm plan 004 is DONE and list its final public runtime-state cases before
> editing views.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/004-always-on-recovery.md`
- **Category**: migration / docs
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

Most current product surfaces teach users to install BlackHole, create an
aggregate, select input/output devices, grant microphone access, and toggle an
engine. Airwave 2.0 has none of those concepts. This phase presents preset plus
health, requests the correct system-audio permission, resets legacy state, and
keeps output identity read-only.

## Current state

- `OnboardingModels.SetupStep` currently contains virtual driver, aggregate,
  microphone permission, and audio route steps.
- `SetupActions` opens BlackHole, Audio MIDI Setup, and microphone privacy.
- `AppSettings` persists device IDs/UIDs, `autoStart`, buffer size, and target
  sample rate.
- `AirwaveMenuView` exposes an engine toggle and aggregate output selector.
- Product decisions: reset all Airwave preferences, onboarding, active preset,
  and Launch at Login registration on first 2.0 launch; keep HRIR files; show
  preset + health + read-only current output + Settings + Quit.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | succeeds |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Search | `rg -n -i 'blackhole|virtual audio|aggregate device|microphone permission|input device|output selector|audio engine' Airwave AirwaveTests` | no legacy UX matches |

## Scope

**In scope**:

- `AirwaveMenuView`, `MenuBarViewModel`, `SettingsView`, onboarding models/view/
  view model/persistence/actions, `SettingsManager`, `ConfigurationManager` and
  `Configuration.plist`, `AirwaveApp`, `LaunchAtLoginManager`, UI/model tests.

**Out of scope**:

- Core Audio mechanics/retry policy, DSP math, public README/Cask/release CI.
- Deleting HRIR files or changing the HRIR file format.

## Git workflow

- Branch: `codex/005-rebuild-product-surfaces`
- Commit example: `feat(ui): rebuild setup for process taps`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Replace settings with a versioned 2.0 schema

Define a minimal schema containing only settings that remain real user choices
(for example UI preferences; active preset is deliberately reset and may be
saved only after the new selection). Remove device IDs/UIDs, `autoStart`, fixed
buffer size, target sample rate, and all legacy migration helpers.

On first launch of schema version 2: clear the old settings/onboarding keys,
clear active preset, call `LaunchAtLoginManager` to disable/unregister the login
item, set a one-time migration marker, and leave the HRIR application-support
directory untouched. Make migration idempotent and unit-test with an isolated
UserDefaults suite and injectable login-item adapter.

**Verify**: migration tests prove legacy data is removed, login item disabled
once, HRIR fixture files unchanged, and second launch is a no-op.

### Step 2: Replace permission UX

Remove microphone authorization/status terminology and actions. New onboarding
explains System Audio Capture and triggers permission by attempting the safe
pipeline setup defined by plans 003/004; map its result to controller state.
Provide an action to open the correct macOS Privacy & Security pane and a Retry
action. Do not claim a preflight authorization status if Core Audio offers none.

**Verify**: model tests cover unknown/requesting, granted/start succeeds, denied,
open settings, retry, and revoked-during-runtime states.

### Step 3: Rebuild onboarding around actual requirements

Use a new onboarding version and steps: welcome/safety promise, system-audio
permission, HRIR discovery and preset selection, and final live health check.
Remove virtual driver, Audio MIDI Setup, aggregate route, microphone, input, and
output selection pages. Existing 1.x completion/checkpoint must never skip 2.0
onboarding. Preserve Finish Later and automatic re-presentation only where it
cannot cause repeated permission prompts.

The final page may complete only when a preset is selected and the controller
has reached `processing` on a supported current output. Unsupported BlackHole/
virtual output instructions say to change output in macOS; no automatic repair.

**Verify**: onboarding model tests cover fresh install, 1.x upgrade, denial,
unsupported virtual output, valid completion, finish later, and relaunch.

### Step 4: Rebuild the menu around preset and health

Remove engine toggle and device selectors. Show current preset, one concise
health row derived from runtime state, read-only current macOS output while known,
Settings, and Quit. Provide Retry only for states the controller marks retryable.
The menu icon must distinguish processing, recovering, and needs-attention
without maintaining its own readiness calculation.

**Verify**: view-model tests assert display mappings for every runtime state and
that no UI action can set output, volume, or engine running state.

### Step 5: Simplify Settings and setup actions

Retain HRIR management, update status, launch-at-login control (default off after
2.0 reset), diagnostics/health, and About/support. Display current output, sample
rate, and tap state only as read-only health details. Remove BlackHole external
link, Audio MIDI Setup action, route controls, volume controls, and redundant
diagnostic polling.

**Verify**: build/test/search commands all meet expected results.

## Test plan

- Isolated persistence migration including login-item disable and HRIR survival.
- New onboarding snapshot/navigation tests using injected runtime state.
- Menu/settings view-model mapping tests for every state and retryability.
- Permission UX tests driven by fake pipeline results, never live TCC.
- Existing DSP and updater tests remain green.

## Done criteria

- [ ] No engine toggle or route/device selector is visible or callable.
- [ ] 1.x state resets exactly once; login item is disabled; HRIR files survive.
- [ ] 2.0 onboarding cannot be skipped by legacy completion state.
- [ ] Permission language says System Audio Capture, never microphone.
- [ ] Menu and Settings consume one runtime state source.
- [ ] BlackHole/virtual output receives warning-only guidance.

## STOP conditions

- The reset implementation deletes or relocates HRIR files.
- A view needs to call Core Audio directly or reproduce runtime policy.
- The correct macOS 15 System Settings pane cannot be opened reliably; keep a
  generic Privacy & Security fallback and report the tested OS build.
- Launch-at-login cannot be disabled through the existing injectable manager.

## Maintenance notes

Permission copy must stay aligned with `NSAudioCaptureUsageDescription`.
Reviewers should search for stale route vocabulary in strings and accessibility
labels, not only Swift symbol names.
