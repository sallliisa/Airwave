# Plan 003: Discover and configure selectable output devices before switching macOS output

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md` — unless a reviewer dispatched you and told you they maintain
> the index.
>
> **Drift check (run first)**: `git diff --stat bcd74be..HEAD -- Airwave/AudioPlatformClient.swift Airwave/CoreAudioPlatformClient.swift Airwave/DeviceProfileManager.swift Airwave/DeviceProfileRuntimeCoordinator.swift Airwave/OutputDeviceDiscoveryCoordinator.swift Airwave/SettingsView.swift Airwave/DeviceManagementView.swift Airwave/AppDelegate.swift AirwaveTests/DeviceProfileManagerTests.swift AirwaveTests/DeviceProfileRuntimeCoordinatorTests.swift AirwaveTests/OutputDeviceDiscoveryCoordinatorTests.swift AirwaveTests/ProductSurfaceTests.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-device-profile-runtime.md`, `plans/002-device-profile-management.md` (both DONE)
- **Category**: direction
- **Planned at**: commit `bcd74be`, 2026-07-17

## Why this matters

Airwave currently learns a supported output only after macOS makes that device
the default output. A user with several selectable outputs therefore cannot
prepare the HRIR/EQ pair for another device before switching to it. Airwave
must observe Core Audio's device inventory, show every currently available
supported physical stereo output in the existing Settings device selector, and
allow its profile to be configured in advance.

Discovery and persistence are deliberately separate. Merely appearing in the
Core Audio inventory, being selected in Airwave, or becoming the current output
must not write a blank profile. A discovered device remains transient until the
user selects a non-`None` HRIR or EQ preset; saved profiles continue to remain
selectable when their hardware is unavailable.

## Product behavior and decisions

- “Available” means present in Core Audio's current
  `kAudioHardwarePropertyDevices` inventory, not “previously seen” and not a
  device Airwave attempts to activate.
- Apply the existing `OutputDeviceDescriptor.isSupportedProfileOutput` policy:
  stable non-empty UID, physical, non-aggregate, and exactly two output
  channels. Input-only, virtual, aggregate, and non-stereo devices never appear.
- Airwave remains read-only with respect to routing. Selecting a device in
  Airwave changes only the Settings editing target; it never changes the macOS
  default output.
- The General/Equalizer top-bar selector is the merged surface: current output
  first, then all other targets alphabetically. Targets comprise available
  supported outputs plus saved profiles whose devices are unavailable, deduped
  by UID.
- The selector labels the macOS default output `Current`. Do not label other
  inventory entries “Connected”; Core Audio inventory presence is the exact
  claim Airwave can make.
- `Settings -> Devices` remains a management page for **saved profiles only**.
  Transient inventory entries have nothing to reset or forget and must not be
  added there.
- Selecting an available unsaved target shows `None` for HRIR and EQ. Selecting
  a non-`None` preset materializes one saved `DeviceAudioProfile` using the
  latest descriptor metadata. Selecting `None` while no profile exists is a
  no-op and performs no persistence write.
- Once materialized, a profile remains saved even if both effects later become
  `None` through ordinary edits or Reset. Only Forget removes it.
- Becoming the current output no longer materializes a blank profile. Runtime
  resolution treats an absent profile as the effective pair `None / None`.
- Existing v1 blank profiles must be preserved. They may represent an
  intentional Reset and cannot safely be distinguished from old automatically
  created profiles, so there is no storage migration or schema bump.
- When an unsaved unavailable target disappears while being edited, select the
  current supported target if one exists; otherwise fall back to the most
  recently seen saved profile; otherwise clear the editing target.
- Inventory refresh failures must not interrupt audio processing. A top-level
  refresh failure retains the last successful inventory and logs once per
  failed refresh. Failure to describe one Core Audio object skips only that
  object.

## Current state

Relevant files and roles:

- `Airwave/AudioPlatformClient.swift` — declares the stable output descriptor,
  shared support policy, and runtime-focused Core Audio protocol.
- `Airwave/CoreAudioPlatformClient.swift` — can describe only the default output
  and listens only for `kAudioHardwarePropertyDefaultOutputDevice`.
- `Airwave/DeviceProfileManager.swift` — conflates current-output observation,
  blank-profile creation, persisted profiles, and editor targets.
- `Airwave/DeviceProfileRuntimeCoordinator.swift` — currently requires
  `profiles.observe(output)` to return a stored profile before resolving effects.
- `Airwave/SettingsView.swift` — top-bar menu renders only `sortedProfiles`, so
  unsaved devices cannot be selected.
- `Airwave/DeviceManagementView.swift` — correctly renders persisted profiles;
  it should remain saved-profile-only.
- `Airwave/AppDelegate.swift` — launches the device-profile runtime coordinator.
- `AirwaveTests/DeviceProfileManagerTests.swift` — currently codifies automatic
  blank-profile creation and must be revised to the new storage boundary.

Current support policy (`Airwave/AudioPlatformClient.swift:22-26`):

```swift
var isSupportedProfileOutput: Bool {
    !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isVirtual && !isAggregate && outputChannelCount == 2
}
```

Current automatic persistence (`Airwave/DeviceProfileManager.swift:81-110`):

```swift
func observe(_ output: OutputDeviceDescriptor?) -> DeviceAudioProfile? {
    guard let output, output.isSupportedProfileOutput else { ... }
    currentDeviceUID = output.uid
    editingDeviceUID = output.uid
    ...
    profiles.append(DeviceAudioProfile(
        deviceUID: output.uid, deviceName: output.name, transport: output.transport,
        hrirPresetID: nil, equalizerPresetID: nil, lastSeenAt: timestamp
    ))
    ...
    return profile(for: output.uid)
}
```

Current runtime dependency on a stored profile
(`Airwave/DeviceProfileRuntimeCoordinator.swift:62-74`):

```swift
guard output.isSupportedProfileOutput, let profile = profiles.observe(output) else {
    completion(.init(spatialReady: false, equalizerDefinition: nil))
    return
}
var resolvedProfile = profile
```

Current selector source (`Airwave/SettingsView.swift:107-124`):

```swift
if let editing = profiles.editingProfile {
    Menu {
        ForEach(profiles.sortedProfiles) { profile in
            Button {
                profiles.selectEditingDevice(uid: profile.deviceUID)
            } label: { ... }
        }
    } label: {
        Text(editing.deviceName)
    }
}
```

Conventions to preserve:

- Main-thread observable coordination uses `@MainActor`, `ObservableObject`,
  `@Published private(set)`, and idempotent `launch()` methods; match
  `DeviceProfileRuntimeCoordinator`.
- Platform structs/protocols crossing the audio boundary are `nonisolated` and
  `Sendable`; match `OutputDeviceDescriptor` and `AudioPlatformClient`.
- Core Audio listeners are installed on `.main`, removed explicitly, and use
  weak captures; match `CoreAudioPlatformClient.observeDefaultOutput` and
  `stopObservingDefaultOutput`.
- Xcode uses filesystem-synchronized source groups. New `.swift` files under
  `Airwave/` and `AirwaveTests/` should not require manual PBX file entries.
- UI uses plain SwiftUI menus, existing typography/palette primitives, and
  accessibility labels. Do not redesign the fixed 900x600 Settings window.

## Target interfaces and state ownership

Add a discovery-only capability rather than adding inventory methods to the
runtime-heavy `AudioPlatformClient` mock surface:

```swift
typealias AvailableOutputChangeHandler = ([OutputDeviceDescriptor]) -> Void

nonisolated protocol OutputDeviceDiscovering: AnyObject {
    func availableOutputDevices() throws -> [OutputDeviceDescriptor]
    func observeAvailableOutputs(_ handler: @escaping AvailableOutputChangeHandler) throws
    func stopObservingAvailableOutputs()
}
```

`CoreAudioPlatformClient` may conform to both protocols so its descriptor
construction helpers are shared, but `OutputDeviceDiscoveryCoordinator.shared`
must own a separate `CoreAudioPlatformClient` instance. The audio runtime keeps
its existing private instance and remains the sole owner of taps, aggregate
devices, IO, permission flow, output switching, retry, and runtime publication.

Add an identifiable merged projection owned by `DeviceProfileManager`:

```swift
struct DeviceProfileTarget: Equatable, Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    let deviceName: String
    let transport: String
    let isAvailable: Bool
    let isCurrent: Bool
    let savedProfile: DeviceAudioProfile?
}
```

Exact names may be adjusted to match the live code, but preserve these
semantics:

- `availableOutputs` is transient, filtered, UID-deduplicated descriptor state.
- `targets` merges availability with `profiles`; inventory metadata wins while
  available, saved metadata is the fallback while unavailable.
- `editingTarget` is valid even when `editingProfile` is nil.
- `observeCurrentOutput(_:)` updates current/editing identity and transient
  metadata without creating a profile.
- `updateAvailableOutputs(_:)` replaces the transient snapshot without writing
  UserDefaults or emitting runtime-relevant `DeviceProfileChange` events.
- `selectEditingDevice(uid:)` accepts any merged target, not only a saved profile.
- `setHRIRPresetID` / `setEqualizerPresetID` lazily create a profile only for a
  known supported target and only when the requested ID is non-nil. The creation
  and selected-effect mutation are one persistence write and one typed change.

`OutputDeviceDiscoveryCoordinator` owns observation lifecycle only: initial
snapshot, listener callback, filtering handoff to `DeviceProfileManager`,
idempotent launch, and logging/recovery. It must not own profiles, effect
selection, audio runtime state, or route changes.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Drift | `git diff --stat bcd74be..HEAD -- <all in-scope paths from the drift check>` | no unreviewed mismatch |
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/DeviceProfileManagerTests -only-testing:AirwaveTests/DeviceProfileRuntimeCoordinatorTests -only-testing:AirwaveTests/OutputDeviceDiscoveryCoordinatorTests -only-testing:AirwaveTests/DeviceProfileManagementTests -only-testing:AirwaveTests/ProductSurfaceTests test` | exit 0; selected suites pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; no failures |
| Audio invariants | `scripts/test-audio-safety-invariants.sh` | exit 0; all invariant checks pass |
| Release version | `scripts/test-release-version.sh` | exit 0 |
| Metadata | `scripts/verify-2.0-metadata.sh` | exit 0 |

Do not use the scheme's implicit configuration for tests. The established local
baseline requires explicit `-configuration Debug` so `@testable import Airwave`
is enabled.

## Scope

**In scope** (the only source/test/docs files you should modify):

- `Airwave/AudioPlatformClient.swift`
- `Airwave/CoreAudioPlatformClient.swift`
- `Airwave/DeviceProfileManager.swift`
- `Airwave/DeviceProfileRuntimeCoordinator.swift`
- `Airwave/OutputDeviceDiscoveryCoordinator.swift` (new)
- `Airwave/SettingsView.swift`
- `Airwave/DeviceManagementView.swift` (copy/status text only if required to
  clarify saved-only behavior; do not change its row source)
- `Airwave/AppDelegate.swift`
- `AirwaveTests/DeviceProfileManagerTests.swift`
- `AirwaveTests/DeviceProfileRuntimeCoordinatorTests.swift`
- `AirwaveTests/OutputDeviceDiscoveryCoordinatorTests.swift` (new)
- `AirwaveTests/DeviceProfileManagementTests.swift` (only if saved-only
  regression coverage requires it)
- `AirwaveTests/ProductSurfaceTests.swift`
- `README.md`
- `plans/README.md` (status only at completion)

**Out of scope** (do NOT touch, even though related):

- Changing the macOS default output, device volume, sample rate, or any Core
  Audio device property. Discovery is read-only.
- Audio tap, private aggregate, AUHAL, pipeline, retry, permission, or DSP code.
- Supporting virtual, aggregate, input-only, or non-stereo devices.
- Persisting the current availability list or adding a second UserDefaults key.
- Changing `DeviceProfileEnvelope` schema version or deleting existing blank
  profiles.
- Showing transient unsaved devices in `Settings -> Devices`.
- Adding Reset/Forget actions to the top-bar menu.
- Onboarding device selection; onboarding continues to configure only the
  current supported macOS output.
- Menu-bar device selection; the menu bar continues to represent/configure the
  current output only.
- Redesigning Settings or changing its fixed dimensions.

## Git workflow

- Branch: `codex/003-discover-available-output-devices`
- Keep commits logical; recent descriptive examples include
  `fix(audio): bind tap to output rate` and `docs(audio): record native rate validation`.
- Do not push or open a PR unless the operator explicitly asks.

## Steps

### Step 1: Add the read-only Core Audio inventory capability

In `AudioPlatformClient.swift`, add `AvailableOutputChangeHandler` and the narrow
`OutputDeviceDiscovering` protocol shown above. Do not add these requirements to
`AudioPlatformClient`; doing so would force unrelated runtime fakes to implement
device-catalog behavior.

In `CoreAudioPlatformClient.swift`:

1. Extract the body that converts an `AudioObjectID` into an
   `OutputDeviceDescriptor` so both default-output lookup and inventory lookup
   use exactly the same UID/name/transport/sample-rate/channel/virtual/aggregate
   interpretation.
2. Read `kAudioHardwarePropertyDevices` from the system object using the
   property-data-size then property-data pattern, producing `[AudioObjectID]`.
3. Describe every returned object. Skip and log an individual object that
   disappears or fails metadata reads during enumeration; do not fail the whole
   inventory for one racing device.
4. Return only descriptors satisfying `isSupportedProfileOutput`, deduped by
   UID and sorted deterministically by localized case-insensitive name with UID
   as the tie-breaker. The manager will reapply ordering with current-first.
5. Add/remove a listener for `kAudioHardwarePropertyDevices` on the system
   object and `.main`. A callback must perform a fresh inventory read, not infer
   deltas from Core Audio object IDs.
6. Ensure `stopObservingAvailableOutputs()` is idempotent and does not disturb
   the existing default-output listener.

Do not assert that every object returned by the system inventory is selectable;
the support policy is the product filter.

**Verify**: `xcodebuild` the targeted suites after Step 2 compiles the new fake
and coordinator → exit 0.

### Step 2: Add an independently testable discovery coordinator

Create `Airwave/OutputDeviceDiscoveryCoordinator.swift` as an `@MainActor`,
idempotently launched coordinator. Production `shared` owns a discovery-only
`CoreAudioPlatformClient`; tests inject `OutputDeviceDiscovering` and
`DeviceProfileManager`.

On `launch()`:

1. Fetch and publish the initial inventory to the manager.
2. Install inventory observation.
3. On each callback, replace the manager's transient snapshot.

If the initial read fails, log and still attempt listener installation so a
later hardware change can recover. If listener installation fails, log and keep
the initial snapshot. If a later refresh fails, the Core Audio implementation
must call no handler (or the coordinator must reject the failed refresh), so the
last successful manager snapshot is retained. Repeated `launch()` calls must not
duplicate listeners.

Create `AirwaveTests/OutputDeviceDiscoveryCoordinatorTests.swift` with a fake
discovery client. Cover:

- initial inventory is published on launch;
- listener updates replace the snapshot;
- idempotent launch installs one listener;
- unsupported and duplicate UID descriptors are filtered/deduped even when a
  fake bypasses production Core Audio filtering (defense at manager boundary);
- initial-read failure can recover through a later callback;
- refresh failure retains the previous snapshot (model the production failure
  contract explicitly).

Do not write a hardware-dependent assertion about the developer machine's
device names or count.

**Verify**: targeted `OutputDeviceDiscoveryCoordinatorTests` → all pass.

### Step 3: Separate transient targets from persisted profiles

Refactor `DeviceProfileManager` without changing the v1 envelope:

1. Add transient available-descriptor state and the merged
   `DeviceProfileTarget` projection described above.
2. Replace `observe(_:)` with an explicitly named current-output operation.
   Supported current output updates `currentDeviceUID`, makes it the editing
   target, and merges its descriptor into transient state, but does not append a
   profile or call `persist()`. Unsupported/unavailable current output clears
   `currentDeviceUID` and applies the deterministic editing fallback.
3. Make inventory refresh replace only inventory-derived availability while
   preserving the current supported descriptor if callbacks arrive out of
   order. Deduplicate by UID and never retain unsupported descriptors.
4. Merge targets by stable UID. Available metadata wins; saved metadata supplies
   unavailable targets. Sort current first and all remaining entries by
   localized case-insensitive name, then UID.
5. Let manual editor selection target any merged target without changing
   `currentDeviceUID` or macOS output.
6. Make both effect setters lazily materialize a profile on the first non-nil
   selection. Use the target's current metadata and `now()` timestamp. Creation
   plus effect assignment must make one UserDefaults write and emit one typed
   effect change, not a preceding metadata change.
7. A nil selection for an unsaved target is a true no-op: no profile, write,
   revision, or change event.
8. Preserve current reset/forget behavior for saved profiles. Forget of an
   available non-current profile removes persistence but leaves the transient
   target selectable at effective `None / None`; update its confirmation copy if
   needed so “recreate” does not imply a route switch is required.
9. Inventory metadata changes for an already saved profile may refresh its saved
   display metadata, but only when materially different and without emitting an
   HRIR/EQ runtime change. Do not update `lastSeenAt` or write UserDefaults on
   every identical inventory callback.

Update `DeviceProfileManagerTests` to cover, with exact write/event assertions:

- available unsaved device appears as a target but not in `profiles` or storage;
- merely selecting it remains non-persistent;
- becoming current remains non-persistent and edits no route;
- first HRIR selection and first EQ selection each materialize correctly from a
  clean context (one write, one matching typed event);
- nil on unsaved is a zero-write no-op;
- available + saved UID merges once and uses live metadata;
- disconnected saved profile remains a target;
- unsupported inventory entries never become targets or profiles;
- disappearing unsaved editor uses the specified fallback;
- forgetting an available saved non-current device leaves an unsaved target;
- existing encoded blank v1 profile survives load unchanged.

Retain or adapt all existing reset, missing-preset, corrupt-store, sorting, and
UID-stability tests. Replace tests whose only expected behavior was automatic
blank creation.

**Verify**: targeted `DeviceProfileManagerTests` → all pass.

### Step 4: Make runtime resolve absent profiles as native audio

Update `DeviceProfileRuntimeCoordinator.prepare` to:

1. Reject unsupported output exactly as today.
2. notify the manager of the current supported descriptor without requiring a
   persisted profile;
3. resolve the saved profile optionally;
4. treat absent HRIR/EQ IDs as `None / None`, complete immediately with native
   readiness, and do not create or persist anything.

Keep missing-preset sanitization, HRIR library readiness, generation checks,
latest-wins cancellation, EQ-only fallback, and runtime change filtering intact.
`outputBecameUnsupportedOrUnavailable()` must call the renamed manager operation.

Extend `DeviceProfileRuntimeCoordinatorTests`:

- preparing an unsaved supported current output completes with neither effect
  and performs zero profile-store writes;
- a preconfigured available device uses its saved pair immediately when it later
  becomes current;
- editing/materializing a non-current available target does not call runtime;
- editing the current unsaved target materializes and triggers exactly the same
  EQ update/HRIR reprepare behavior as an existing saved profile.

**Verify**: targeted manager + runtime coordinator suites → all pass.

### Step 5: Launch discovery and render merged Settings targets

Launch `OutputDeviceDiscoveryCoordinator.shared` once from
`AppDelegate.applicationDidFinishLaunching`, adjacent to the existing profile
runtime launch. Discovery failure must not prevent runtime launch.

Update the Settings top-bar device menu to use `editingTarget` and `targets`
instead of requiring `editingProfile` and `sortedProfiles`. Preserve the plain
text + chevron styling, General/Equalizer visibility, Current annotation, and
accessibility behavior. An unsaved target must show `None` selections through
the existing optional profile reads, and choosing a preset must call the lazy
materializing manager setters.

Do not add transient targets to `DeviceManagementCoordinator.rows`; it must
continue mapping `sortedProfiles`. Adjust Devices-page and confirmation copy
only where it now falsely says a device must first be “encountered.” Suggested
saved-only subtitle: “Inspect and manage the HRIR and EQ profiles you have
saved.”

Update `ProductSurfaceTests` so source assertions distinguish the merged
Settings selector from saved-only management. Prefer behavior assertions in
manager/coordinator tests; keep source-text assertions only for fixed product
surface invariants already used by this suite.

**Verify**: all targeted suites → exit 0 with no failures.

### Step 6: Update documentation and run full verification

Update `README.md`:

- Setup: selectable supported outputs can be configured in Settings before they
  become the macOS default.
- New devices are effectively `None / None`; clarify that a profile is saved on
  the first effect selection, not merely on observation.
- Device management: remove “Airwave does not enumerate connected devices.”
  State that the top-bar selector shows currently available supported outputs
  plus saved unavailable profiles, while Devices manages saved profiles only.
- Preserve the statement that Airwave never changes output selection or volume.

Run the full test and invariant commands. Manually inspect `git diff --stat` and
confirm only in-scope files changed.

**Verify**: full Debug tests, three scripts, and scope check all pass.

## Test plan

- `AirwaveTests/OutputDeviceDiscoveryCoordinatorTests.swift` (new): discovery
  lifecycle, update/recovery semantics, filtering, deduplication, idempotence.
- `AirwaveTests/DeviceProfileManagerTests.swift`: transient/saved separation,
  lazy materialization, merged ordering/metadata, disappearance fallback, exact
  persistence and change-event counts, existing v1 compatibility.
- `AirwaveTests/DeviceProfileRuntimeCoordinatorTests.swift`: native resolution
  without a profile, preconfiguration before output switch, current versus
  non-current edit effects.
- `AirwaveTests/DeviceProfileManagementTests.swift`: saved-only rows and Forget
  behavior when the forgotten hardware remains available, if not fully covered
  at manager level.
- `AirwaveTests/ProductSurfaceTests.swift`: discovery launch and merged selector
  versus saved-management wiring.
- Model new fakes after the existing injected manager/runtime fakes. Do not add
  timing sleeps, real device switching, or machine-specific device assertions.

## Done criteria

All must hold:

- [ ] On launch, every currently available descriptor satisfying
  `isSupportedProfileOutput` is represented once in the Settings selector by UID
  without first becoming the macOS default.
- [ ] Inventory add/remove callbacks update transient Settings targets without
  starting/stopping the audio pipeline or changing macOS routing.
- [ ] Discovery, editor selection, and current-output observation of an unsaved
  device perform zero profile-store writes.
- [ ] The first non-nil HRIR/EQ choice for an unsaved target creates exactly one
  saved profile with one write and one typed effect event.
- [ ] Saved unavailable profiles remain selectable; transient unsaved devices do
  not appear on the Devices management page.
- [ ] An unsaved current device resolves to native `None / None`; a device
  configured in advance applies its saved pair when macOS later selects it.
- [ ] Unsupported virtual, aggregate, input-only, empty-UID, and non-stereo
  entries never appear or persist.
- [ ] Existing v1 data, including saved blank profiles, loads unchanged; storage
  key and schema version remain `Airwave.DeviceProfiles.v1` / `1`.
- [ ] Targeted and full explicit-Debug test commands exit 0 with no failures.
- [ ] Audio safety, release-version, and metadata scripts exit 0.
- [ ] `git status --short` lists no modified source/test/docs files outside Scope.
- [ ] Plan 003 status in `plans/README.md` is updated to DONE.

## STOP conditions

Stop and report back; do not improvise if:

- Current Core Audio inventory APIs cannot distinguish output-capable devices
  using the existing output-channel descriptor policy.
- Enumerating `kAudioHardwarePropertyDevices` requires changing any system route,
  volume, nominal sample rate, or device property.
- The implementation would require `AudioRuntimeController` to expose or share
  its private platform instance with UI/discovery code.
- A transient target cannot be edited without changing the v1 persisted schema;
  first attempt the merged projection/lazy-materialization design, then stop if
  a schema change is still necessary.
- Inventory observation interferes with the default-output listener, audio tap,
  private aggregate lifecycle, sleep/wake cleanup, or permission flow.
- Supporting a requested device would require relaxing the existing physical
  stereo support policy.
- Any in-scope current-state excerpt has materially drifted from this plan.
- A verification command fails twice after a reasonable correction.
- Completion requires modifying an out-of-scope file.

## Maintenance notes

- Core Audio object IDs are transient; all merge and persistence identity must
  remain based on device UID.
- The inventory and default-output listeners are separate event streams and may
  arrive in either order. Review fallback/merge code for flicker, accidental
  editor changes, and write amplification.
- Review every persistence call: inventory refresh is expected to be frequent
  during docks, displays, Bluetooth, and sleep/wake changes.
- If future product work wants to show unsaved devices on the Devices page,
  define explicit actions and labels first; Reset/Forget currently apply only to
  persisted profiles.
- Hardware validation should cover built-in output, USB DAC hot-plug, HDMI/display
  appearance, and Bluetooth appearance where available. Automated tests remain
  deterministic and hardware-independent.

