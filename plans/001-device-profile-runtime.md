# Plan 001: Apply a persistent HRIR and EQ profile per supported output device

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0e64fa7..HEAD -- Airwave AirwaveTests README.md Airwave.xcodeproj`
> If an in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. Stop if
> output ownership, preset selection, or Settings navigation has materially
> changed.

## Status

- **Priority**: P1
- **Effort**: L (multi-day)
- **Risk**: HIGH — changes output-switch sequencing and the source of truth for both effects
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `0e64fa7`, 2026-07-17

## Why this matters

Airwave currently has one process-wide HRIR selection and one persisted EQ
selection. When macOS changes output, `AudioRuntimeController` immediately
restarts the pipeline using those same effects. A headphone HRIR can therefore
be applied to speakers, HDMI, or a device with its own processing.

After this plan, every supported physical stereo output has one independent,
persistent `{ HRIR preset ID?, EQ preset ID? }` profile keyed by Core Audio
device UID. A new device starts at `None`/`None`, so Airwave never processes an
unreviewed output. There is deliberately no Global profile or inheritance.

## Product decisions (do not reinterpret)

- A valid profile device is physical, non-aggregate, and exactly stereo. Use
  the same support rule as the runtime. Unsupported virtual, aggregate, and
  non-stereo outputs are not persisted.
- Device UID is persistent identity. Core Audio object ID is transient and
  must never be stored. Refresh name and transport whenever a known UID is
  observed.
- New profiles are `HRIR = None`, `EQ = None`. Do not migrate the legacy global
  EQ selection. HRIR is not currently persisted.
- Preset import only adds to its library. It must not select the imported item
  for any device.
- Deleting or externally losing a preset clears only that effect's reference
  in every affected device profile; preserve the other effect.
- Onboarding edits the current supported device. The menu bar also edits only
  the current supported device.
- Settings opens on the current supported output and follows every subsequent
  macOS output change. Users may select a remembered device manually until the
  next output change.
- The shared Settings top bar shows an elegant device menu on General and
  Equalizer only: plain device-name text plus a downward chevron, no filled
  background. It remains the same editing target while navigating between
  those two pages. Hide it on Application and onboarding.
- On an output/profile transition, stop the old pipeline first and leave native
  audio untouched while the target HRIR is prepared. Start HRIR and EQ together.
  If HRIR preparation fails but EQ is valid, run EQ alone and publish the HRIR
  warning. Never briefly run the old device's effects or start EQ early and
  then restart for HRIR.
- Rapid device/profile changes are latest-wins. A stale HRIR completion must not
  publish readiness or restart a pipeline.
- This plan adds no reset/forget UI. Selecting `None` for both effects is the
  phase-one bypass. Plan 002 adds device administration.

## Current state

- `Airwave/AudioPlatformClient.swift:3-21` exposes stable UI-safe metadata,
  including both `uid` and transient `id`, but has no shared support predicate:

  ```swift
  nonisolated struct OutputDeviceDescriptor: Equatable, Sendable {
      let id: ID
      let uid: String
      let name: String
      let transport: String
      let outputChannelCount: Int
      let nominalSampleRate: Double
      let isVirtual: Bool
      let isAggregate: Bool
  }
  ```

- `Airwave/AudioRuntimeController.swift:127-156,267-303` owns default-output
  observation and eagerly calls `start(on:)` after an output callback. Its
  existing generation, cleanup, permission-probe, and retry machinery is the
  lifecycle authority and must remain so.

  ```swift
  try platform.observeDefaultOutput { [weak self] output in
      MainActor.assumeIsolated { self?.defaultOutputChanged(output) }
  }
  // ...
  guard stopForInvalidation() else { return }
  guard let output else { ... }
  start(on: output)
  ```

- `Airwave/AppDelegate.swift:324-362` launches the controller from global
  `HRIRManager.activePreset` and `EqualizerManager.selectedDefinition`, then
  independently subscribes to each. This is the race-prone orchestration that
  the new coordinator replaces.
- `Airwave/HRIRManager.swift:281-419` already performs cancellable off-thread
  HRIR construction and publishes success/failure on the main queue, but its
  activation API has no completion result for a pair-level coordinator.
- `Airwave/EqualizerManager.swift:62-176` mixes library ownership with a single
  persisted selection under `Airwave.Equalizer.SelectedPresetID`.
- `Airwave/SettingsView.swift:40-101` provides a shared `AirwaveTopBar` center
  slot; it is currently `EmptyView()` in Settings mode.
- `Airwave/SettingsView.swift:291-312`,
  `Airwave/EqualizerSettingsView.swift:363-440`, and
  `Airwave/OnboardingView.swift:170-198` render selection from the global
  managers rather than an editing-device profile.
- `Airwave/AirwaveStyle.swift:348-366` and
  `Airwave/EqualizerSettingsView.swift:214-227` automatically select the first
  imported preset. Remove this behavior.
- `AirwaveTests/AudioRuntimeControllerTests.swift:186-257` is the lifecycle
  regression pattern: fake platform, manual scheduler, event ordering, and
  rapid A→B→C coverage. Preserve and extend this style.
- The app target uses a filesystem-synchronized group, but `AirwaveTests` is an
  explicit `PBXGroup` with a fixed Sources build-phase list. New app files under
  `Airwave/` require no manual PBX entries. Add every new test file under
  `AirwaveTests/` to the test group and test target's Sources build phase in
  `Airwave.xcodeproj/project.pbxproj`; this project-file update is explicitly
  in scope and is required for the verification commands to discover the tests.

## Target architecture and interfaces

Create two focused types instead of making the preset libraries device-aware.
Names may change only to match an already-established repository convention;
responsibilities may not be merged into `AudioRuntimeController`.

### `DeviceProfileManager` — persistence and editing source of truth

Add `Airwave/DeviceProfileManager.swift` with `@MainActor` observable state and
injectable `UserDefaults` for tests.

Use Codable value types with this semantic shape:

```swift
struct DeviceAudioProfile: Codable, Equatable, Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    var deviceName: String
    var transport: String
    var hrirPresetID: UUID?
    var equalizerPresetID: UUID?
    var lastSeenAt: Date
}

struct DeviceProfileEnvelope: Codable, Equatable {
    let schemaVersion: Int       // v1 = 1
    var profiles: [DeviceAudioProfile]
}
```

Persist one encoded envelope under `Airwave.DeviceProfiles.v1`. On first v1
initialization, remove `Airwave.Equalizer.SelectedPresetID` and write an empty
v1 store; do not copy its value. Decode failure must fail safe to an empty
in-memory store, log one diagnostic without dumping raw data, and overwrite
only when the next valid mutation occurs.

Publish enough state for SwiftUI and orchestration:

- profiles, sorted current first then remembered alphabetically by localized
  device name with UID as deterministic tie-breaker;
- `currentDeviceUID` (nil for no output or unsupported output);
- `editingDeviceUID` and its resolved profile;
- a typed change event/revision that identifies device UID and changed effect
  (`hrir`, `equalizer`, `metadata`, or both) so the runtime coordinator can
  ignore offline edits and preserve live EQ updates.

Required operations:

- observe an output descriptor: if supported, create/refresh its record and set
  both current and editing UID; if unsupported/nil, clear current and select the
  most recently seen remembered profile as editor fallback (or nil when empty);
- select a remembered editing UID without changing macOS output;
- set HRIR or EQ ID for the editing device;
- set HRIR for the current device (menu/onboarding path);
- clear a set of missing HRIR IDs or EQ IDs across all profiles, persisting one
  batched update and emitting effect-specific changes.

Put the validity predicate on `OutputDeviceDescriptor` (or a small shared policy
type) and call it from both profile observation and runtime validation. Do not
duplicate the three conditions.

### `DeviceProfileRuntimeCoordinator` — pair preparation and app orchestration

Add `Airwave/DeviceProfileRuntimeCoordinator.swift` as the production-level
coordinator. It owns references to the profile manager, HRIR library/engine, EQ
library, and `AudioRuntimeController`; it does not own Core Audio objects or
publish `AudioRuntimeState` directly.

Define a narrow preparation protocol consumed by the controller, for example:

```swift
@MainActor
protocol OutputEffectProfilePreparing: AnyObject {
    func prepare(
        output: OutputDeviceDescriptor,
        completion: @escaping (AudioRuntimeEffectReadiness) -> Void
    )
    func cancelPreparation()
}
```

The controller must hold this collaborator weakly; the app-level coordinator
may retain the controller. `DeviceProfileRuntimeCoordinator.launch()` wires the
collaborator, subscribes to profile/library changes, and launches the controller.
`AppDelegate` calls this one entry point instead of combining manager publishers.

For each supported output:

1. Increment coordinator generation, cancel/deactivate prior HRIR preparation,
   and record the device in `DeviceProfileManager`.
2. Resolve the profile's EQ ID to a definition. Resolve the HRIR ID to a preset.
   If either reference is absent from a fully loaded library, clear only that
   stored reference before continuing.
3. If HRIR is None, complete synchronously with EQ readiness. If HRIR is set,
   activate it at the output nominal sample rate and `.stereo`, then complete
   only for the current generation.
4. On HRIR failure, complete with `spatialReady = false`, the resolved EQ
   definition, and `spatialError`; do not discard or suppress EQ.

Extend `HRIRManager.activatePreset` with a main-actor success/failure completion
or equivalent typed result. Cancellation and stale generations must invoke no
completion. Reuse its existing activation-generation and cancellation token;
do not introduce a second convolution builder.

Library reconciliation must not clear valid saved references during HRIR's
current asynchronous initial directory scan. Add an explicit initial-sync-ready
signal/generation to HRIRManager, then reconcile missing IDs only after HRIR and
EQ initial loads are complete. Later directory watcher removals must reconcile.

### `AudioRuntimeController` — lifecycle authority with prepared output

Keep output observation, permission decisions, pipeline ownership, cleanup,
retry/backoff, sleep/wake, and sole state publication in the controller.
Change only the handoff between output observation and `start(on:)`:

- validate output before asking the coordinator to remember/prepare it;
- stop the prior pipeline and publish `.starting` for the new descriptor while
  the pair is prepared; no private tap exists during this interval;
- store a desired/prepared output and guard preparation completion with the
  controller generation and device UID;
- after the latest completion, set readiness and start that exact output;
- retries use the stored desired output/readiness, not a stale profile and not
  an unconditional fresh `defaultOutputDevice()` start;
- an empty prepared profile performs the existing short permission probe when
  appropriate, then publishes `.inactive` with the correct current output;
- output loss, cleanup failure, permission denial, sleep/wake, unsupported
  output, and backoff behavior remain covered and semantically unchanged.

On an EQ-only change for the current UID, the coordinator resolves the new
definition and uses the existing `.equalizerTarget` live-update path. An HRIR
change, both-effect sanitization, or output change uses full prepare/stop/start.
Edits to remembered non-current profiles only persist; they must not touch the
pipeline.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Safety gates | `scripts/test-audio-safety-invariants.sh && scripts/test-release-version.sh && scripts/verify-2.0-metadata.sh` | exit 0; all three pass messages |
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/DeviceProfileManagerTests -only-testing:AirwaveTests/DeviceProfileRuntimeCoordinatorTests -only-testing:AirwaveTests/AudioRuntimeControllerTests test` | exit 0; selected suites pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; baseline was 173 tests, 1 skipped |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0, `** BUILD SUCCEEDED **` |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | exit 0, no new analyzer errors |

The repository's implicit-configuration test command selected Release and
failed locally at `@testable import Airwave`; the explicit Debug command above
passed. Do not change the scheme or CI workflow in this feature plan.

## Scope

**In scope** (new files included):

- `Airwave/DeviceProfileManager.swift`
- `Airwave/DeviceProfileRuntimeCoordinator.swift`
- `Airwave/AudioPlatformClient.swift`
- `Airwave/AudioRuntimeController.swift`
- `Airwave/AudioRuntimeState.swift` only if a preparation status detail is
  required; do not add a second runtime state owner
- `Airwave/HRIRManager.swift`
- `Airwave/EqualizerManager.swift`
- `Airwave/EqualizerPreset.swift` only for library lookup helpers/types
- `Airwave/AppDelegate.swift`
- `Airwave/MenuBarViewModel.swift`
- `Airwave/AirwaveMenuView.swift`
- `Airwave/SettingsView.swift`
- `Airwave/EqualizerSettingsView.swift`
- `Airwave/OnboardingView.swift`
- `Airwave/AirwaveStyle.swift`
- `AirwaveTests/DeviceProfileManagerTests.swift`
- `AirwaveTests/DeviceProfileRuntimeCoordinatorTests.swift`
- existing tests directly covering the changed managers, controller, and UI
- `README.md`

**Out of scope**:

- Enumerating every connected output; only current and previously observed
  supported outputs exist in this model.
- A Global profile, inheritance, named reusable templates, profile copying, or
  per-effect inheritance.
- Reset/forget UI or a Devices settings page (Plan 002).
- Changing macOS route, volume, nominal rate, or the process-tap safety contract.
- New realtime DSP, realtime resampling, effect order changes, or EQ limiter.
- Scheme/CI configuration repair, release workflow, signing, and deployment.
- Renaming devices or editing imported preset content.

## Git workflow

- Branch: `codex/001-device-profile-runtime`
- Use logical commits with the repository's conventional style, e.g.
  `feat(profiles): persist per-device effect selections` and
  `test(profiles): cover latest-wins output switching`.
- Do not push or open a PR unless instructed by the operator.

## Steps

### Step 1: Add and characterize the profile store

Create `DeviceProfileManager.swift` and its test file. Implement the v1 envelope,
safe initialization, support predicate, device encounter/update, editor/current
selection, effect mutations, deterministic ordering, and missing-reference
cleanup. Use injected isolated UserDefaults suites and deterministic dates in
tests.

Tests must cover: empty startup; legacy EQ key discarded; first supported device
created as None/None; persistence/relaunch; same UID with new Core Audio ID/name;
unsupported outputs not stored; current and editor follow output changes; manual
remembered selection; corrupt payload fails safe; missing HRIR and EQ clear only
their own fields; one batched persistence mutation.

**Verify**: run the targeted command with only
`-only-testing:AirwaveTests/DeviceProfileManagerTests` → suite passes.

### Step 2: Separate EQ library state from device selection

Refactor `EqualizerManager` into a managed-preset library plus `runtimeEffect`.
Remove reading/writing of the single selected-preset default and make profile
IDs the only persistent EQ selection. Provide lookup by UUID. Update import,
replace, reload, and deletion rollback tests so library correctness remains
covered without a global selection.

Change EQ import to report imported files without selecting any profile. Update
the Settings row model and view to read/write the editing profile's EQ ID and to
derive selected preset/detail/delete target through library lookup. Deleting a
preset must remove it from the library first, then profile reconciliation clears
all references.

**Verify**:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/EqualizerLibraryTests -only-testing:AirwaveTests/ProductSurfaceTests test`
→ both suites pass.

### Step 3: Expose cancellable HRIR preparation completion and library readiness

Extend the existing HRIR activation path rather than duplicating it. Publish a
typed success/failure completion only for the current activation generation.
Add an explicit initial library-sync-ready signal and removal reconciliation
hook. Make HRIR drag/drop/import library-only by removing the `onSelect(first)`
behavior and the unnecessary callback parameter from the view modifier.

Add tests for completion on success/failure, no callback after cancellation or
replacement, and no premature missing-reference cleanup during initial scan.

**Verify**:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/PresetActivationCoordinatorTests -only-testing:AirwaveTests/DeviceProfileRuntimeCoordinatorTests test`
→ selected suites pass.

### Step 4: Introduce pair-level runtime coordination

Implement `DeviceProfileRuntimeCoordinator` and its preparation protocol. Wire
profile resolution, HRIR waiting, EQ definition resolution, missing-reference
reconciliation, generation cancellation, current-only reapplication, and EQ-only
live update. Test with fakes; do not require Core Audio hardware or real WAV
convolution in coordinator unit tests.

Required ordering assertions:

- A→B stops A before B preparation starts; B does not start until B's HRIR
  completion.
- Slow B then fast C publishes/starts only C.
- EQ does not run while HRIR is pending.
- HRIR failure starts EQ-only and carries a warning.
- None/None leaves native passthrough and no live pipeline.
- Editing an offline remembered profile does not call runtime actions.
- EQ-only current edit uses live update without rebuilding HRIR/pipeline.

**Verify**: targeted coordinator and controller command → all selected suites pass.

### Step 5: Adapt the controller without weakening lifecycle guarantees

Replace eager output starts with validate → stop → prepare → generation-check →
start. Preserve all existing cleanup/retry/permission tests, updating fakes to
inject a profile preparer. Add exact tests for preparation wait, stale completion,
empty-profile permission probe, output loss during preparation, sleep/terminate
cancellation, and cleanup failure before a new preparation begins.

Do not move `AudioRuntimeState.publish` calls out of the controller. Do not let
the coordinator acquire/destroy taps, aggregates, or IO units.

**Verify**: `-only-testing:AirwaveTests/AudioRuntimeControllerTests` → all tests
pass and event assertions prove stop-before-prepare/start ordering.

### Step 6: Wire device-targeted product surfaces

Replace `AppDelegate`'s independent HRIR/EQ Combine sinks with one
`DeviceProfileRuntimeCoordinator.launch()` call. Route menu and onboarding HRIR
selection through the current device profile. Route General and Equalizer rows
through the editing profile.

Add the top-bar `Menu` in `SettingsWindowContent.topBarCenter` for Settings mode
only when page is General or Equalizer. Label it with plain current editing
device name and a chevron; use `.buttonStyle(.plain)`, primary text, no capsule,
material, or filled background. Menu order is current first, then remembered
alphabetically; use a checkmark for the editing target and a subtle “Current”
annotation. If no supported/remembered profile exists, show disabled
`No Supported Output` text. Output callbacks always update the editor target.

Disable profile assignment actions when onboarding has no supported current
device. Preserve the existing unsupported-output guidance and permission/setup
flow. Update accessibility labels/values for device target and selected presets.

Update README setup and Equalizer sections: effects are per supported device,
new devices default to None/None, imports do not auto-select, and output routing
still belongs exclusively to macOS.

**Verify**: ProductSurfaceTests plus full build → pass.

### Step 7: Run full regression and inspect scope

Run all commands in "Commands you will need". Review `git diff` for forbidden
route/volume/rate writes and for any remaining production reads/writes of the
legacy EQ selection key. Confirm only plan files plus the declared source/test/
README scope changed.

**Verify**:

```sh
rg -n 'Airwave\.Equalizer\.SelectedPresetID' Airwave
git status --short
```

Expected: the legacy key appears only in the one-time discard/migration path
(or nowhere after initialization is represented another safe way); status shows
only declared files and `plans/README.md`.

## Test plan

- Create `DeviceProfileManagerTests` for Codable persistence, safe defaults,
  UID identity, metadata refresh, unsupported filtering, editor/current state,
  library reconciliation, and legacy selection discard.
- Create `DeviceProfileRuntimeCoordinatorTests` for complete-pair resolution,
  cancellation/generation behavior, HRIR wait/failure, EQ-only updates, and
  offline edit isolation.
- Extend `AudioRuntimeControllerTests` using its existing fake platform,
  pipeline event recorder, and manual scheduler. Preserve all cleanup/backoff,
  permission, sleep/wake, and A→B→C cases.
- Update `EqualizerLibraryTests` to test library persistence and atomic file
  operations independently of global selection.
- Update `ProductSurfaceTests` for import-without-selection, current-device
  onboarding/menu actions, top-bar visibility, plain styling, page persistence,
  unsupported placeholder, and accessibility.
- Full verification: explicit Debug `xcodebuild test` → all tests pass, with no
  decrease in existing test count except tests intentionally replaced by more
  specific profile assertions.

## Done criteria

- [ ] Every supported observed UID has exactly one persisted profile; new
  profiles are None/None.
- [ ] Unsupported outputs are never stored and never receive a profile.
- [ ] No Global/fallback profile or legacy global EQ selection remains active.
- [ ] Output switches cannot start with the previous device's effects; tests
  prove latest-wins and wait-for-pair ordering.
- [ ] HRIR failure degrades to EQ-only with warning; missing presets clear only
  their own references.
- [ ] Imports add to libraries without assigning any device.
- [ ] Menu/onboarding edit current device; General/Equalizer edit the top-bar
  target; output changes always follow the new current device.
- [ ] The device selector is plain text + chevron on General/Equalizer and hidden
  on Application/onboarding.
- [ ] Safety scripts, full Debug tests, build, and analyze all exit 0.
- [ ] No route, volume, nominal-rate, DSP-order, or realtime allocation contract
  changed.
- [ ] No files outside Scope are modified, apart from executor status in
  `plans/README.md`.

## STOP conditions

Stop and report instead of improvising if:

- A stable nonempty Core Audio UID is unavailable for a supported output.
- Supporting profile preparation requires a second default-output observer or
  moving Core Audio resource ownership out of `AudioRuntimeController`.
- HRIR activation cannot expose a latest-wins completion without allocating or
  locking on the render callback.
- The only apparent way to wait for HRIR would mute/drop native audio while no
  Airwave pipeline is running.
- EQ-only failure cannot be represented using existing readiness/warning paths.
- HRIR initial library synchronization cannot distinguish “not loaded yet” from
  “loaded and empty”; add the readiness signal, do not clear every saved ID.
- The feature requires output enumeration, route mutation, a Global profile, or
  device-name identity.
- A verification command fails twice after a reasonable in-scope fix.
- Scheme/CI configuration must change to make explicit Debug tests pass; report
  the pre-existing verification issue separately.

## Maintenance notes

- Device UID changes caused by re-pairing or driver resets intentionally create
  a new bypassed profile; never guess identity from a reused display name.
- Profile schema changes require a new envelope version and explicit migration.
- Review coordinator generations and controller generations together: both
  guards are intentional, one protects DSP preparation and one protects audio
  resource lifecycle.
- Keep preset libraries independent of device selection so future reusable
  templates can be added without returning to global manager state.
- Device reset/forget and cleanup UX are deferred to Plan 002.
