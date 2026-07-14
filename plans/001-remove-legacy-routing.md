# Plan 001: Remove hazardous legacy routing and leave a safe shell

> **Executor instructions**: Follow this plan step by step. Run every
> verification command before continuing. This phase intentionally leaves
> spatial processing unavailable. Do not begin the process-tap implementation.
> Update this plan's row in `plans/README.md` when done.
>
> **Drift check (run first)**:
> `git diff --stat f020179..HEAD -- Airwave AirwaveTests Airwave.xcodeproj`
> If the cited legacy symbols moved or new route/volume mutation code appeared,
> stop and report instead of adapting the scope silently.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: none
- **Category**: migration / correctness
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

The current architecture can strand macOS on BlackHole after a crash and can
continue asynchronous volume ramps after route restoration. This is a hearing-
safety problem, not ordinary refactor debt. The first migration phase removes
every capability that changes global output or device volume and leaves a
compiling native-pass-through shell before replacement work starts.

## Current state

- `Airwave/AudioGraphManager.swift:165-167` calls
  `switchSystemAudioToInputDevice()` before starting.
- `Airwave/AudioGraphManager.swift:203-205` restores system output on stop.
- `Airwave/MenuBarViewModel.swift:321-337` sets a selected physical output to
  `1.0` volume.
- `Airwave/AppDelegate.swift:158-233` installs signal recovery because the app
  owns global route state.
- `Airwave/RuntimeEnvironment.swift:10-13` keeps two legacy route paths behind
  `-UseLegacyRouting`; both must go.
- Legacy concepts also live in `AggregateDeviceInspector`, `AudioRouteTransition`,
  `DeviceSelectionCoordinator`, `DeviceSelectionPolicy`,
  `DeviceOutputEligibility`, `SystemDiagnosticsManager`, and their tests.
- Preserve the existing backend-independent DSP files: `ConvolutionEngine.swift`,
  `FFTSetupManager.swift`, `HRIRManager.swift`, `PresetActivationCoordinator.swift`,
  `RealtimeAudioProcessor.swift`, `Resampler.swift`, `VirtualSpeaker.swift`,
  `WAVLoader.swift`, and their DSP tests.
- Match existing app logging through `Logger.log`; do not add a second logger.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0, `BUILD SUCCEEDED` |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0, all remaining tests pass |
| Analyze | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | exit 0, `ANALYZE SUCCEEDED` |

## Scope

**In scope**:

- Legacy routing/device source files under `Airwave/` and corresponding tests.
- `AirwaveApp.swift`, `AppDelegate.swift`, `MenuBarViewModel.swift`,
  `AirwaveMenuView.swift`, `SettingsView.swift`, and onboarding files only as
  needed to leave a compiling safe shell.
- `Airwave.xcodeproj/project.pbxproj` for file removal and macOS 15 target.
- Add `Airwave/AudioRuntimeState.swift` as the temporary/new shared state model.

**Out of scope**:

- Process taps, private aggregate creation, IOProc/AUHAL output, permission
  requests, automatic retry, and final 2.0 UI.
- DSP behavior and HRIR file formats.
- README, Cask, release workflow, and public version numbers; plan 006 owns them.

## Git workflow

- Branch: `codex/001-remove-legacy-routing`
- Use logical conventional commits, e.g. `refactor(audio): remove legacy routing`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Introduce a safe runtime state owned by no Core Audio code

Create `AudioRuntimeState.swift` with an `@MainActor`, `ObservableObject`
singleton (plus injectable initializer for tests) and a finite status enum:
`unavailable`, `needsSetup`, `nativePassthrough(reason:)`, `starting`,
`processing`, and `recovering(reason:)`. In this phase initialize it to
`unavailable("Airwave 2.0 audio backend is not installed yet")`. Expose only
read-only display state; do not expose start/stop, device selection, route, or
volume APIs.

**Verify**: build command → `BUILD SUCCEEDED`.

### Step 2: Remove all route and volume mutation code

Delete the legacy routing stack and remove project references:

- `AggregateDeviceInspector.swift`
- `AudioDevice.swift` and `AudioDeviceQueryService.swift`
- `AudioGraphManager.swift`
- `AudioRouteTransition.swift`
- `DeviceOutputEligibility.swift`
- `DeviceSelectionCoordinator.swift`
- `DeviceSelectionPolicy.swift`
- `OnboardingRouteController.swift`
- `SystemDiagnosticsManager.swift`

Delete route-specific tests in `AudioDeviceQueryServiceTests.swift` and
`OnboardingModelTests.swift`; retain unrelated onboarding tests only if the safe
shell still has that behavior. Remove `RuntimeEnvironment.useSelectionCoordinator`
and the `-UseLegacyRouting` branch. Rewrite `AppDelegate` to remove signal
interception, crash recovery, output restoration, and engine shutdown; normal
application termination must have no audio side effect in this phase.

**Verify**:

`rg -n 'setSystemDefaultOutputDevice|setDeviceVolume|rampVolume|restoreSavedOutputDevice|UseLegacyRouting|BlackHole|AggregateDeviceInspector|AudioGraphManager' Airwave AirwaveTests`
→ no matches, except user-facing temporary migration text only if explicitly
marked for removal by plan 005.

### Step 3: Reduce the app shell to retained product capabilities

Rewrite `MenuBarViewModel`, `AirwaveMenuView`, and `SettingsView` so they use
`AudioRuntimeState` and retain only preset discovery/selection, HRIR folder
management, updater, Launch at Login control, Settings, and Quit. Display the
unavailable/native-pass-through status. Remove engine toggle, aggregate/input/
output selectors, route help, and any action that starts legacy audio.

Temporarily reduce onboarding to a truthful single unavailable/setup screen or
disable automatic onboarding presentation. Do not retain pages that instruct
users to install BlackHole or create aggregates.

**Verify**: build and test commands → both succeed.

### Step 4: Set the code target to macOS 15

Set app and test deployment targets consistently to `15.0`. Do not adopt
macOS 26-only APIs. Leave release metadata updates to plan 006.

**Verify**:

`xcodebuild -project Airwave.xcodeproj -scheme Airwave -showBuildSettings | rg 'MACOSX_DEPLOYMENT_TARGET = 15.0'`
→ reports 15.0 for relevant targets; analyze command succeeds.

## Test plan

- Keep all `ConvolutionEngineTests`, `RealtimeAudioProcessorTests`,
  `PresetActivationCoordinatorTests`, and `UpdateStateModelTests` passing.
- Add a small `AudioRuntimeStateTests.swift` covering the initial unavailable
  status and display mapping.
- Remove tests that assert default-output restoration, aggregate selection,
  BlackHole filtering, or engine toggling; those behaviors must not be ported.

## Done criteria

- [ ] No source symbol can set a system default output or device volume.
- [ ] No legacy routing feature flag or aggregate/input/output preference remains.
- [ ] The app visibly reports processing unavailable and otherwise compiles.
- [ ] DSP, preset, update, and new runtime-state tests pass.
- [ ] All deployment targets are macOS 15.0.
- [ ] No user HRIR files or runtime preferences are modified by this phase.
- [ ] Only in-scope files changed and the index row is updated.

## STOP conditions

- Removing a listed legacy file also removes HRIR loading or convolution logic.
- A proposed compile fix reintroduces a default-output or volume mutation helper.
- The app cannot be made to compile without starting process-tap work.
- Any test invokes live Core Audio or presents a TCC prompt.

## Maintenance notes

The temporarily disabled app is deliberate. Reviewers should reject any
"temporary" call that restores route switching or volume synchronization.

