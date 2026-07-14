# Plan 006: Make views passive and apply resolved routes transactionally

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm expected result. Stop and report on any STOP condition; do not improvise. When done, update this plan's row in `plans/README.md`, unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6f2978f..HEAD -- README.md Airwave/DeviceSelectionPolicy.swift Airwave/DeviceSelectionCoordinator.swift Airwave/MenuBarViewModel.swift Airwave/SettingsView.swift Airwave/AirwaveMenuView.swift Airwave/AudioGraphManager.swift AirwaveTests/AudioDeviceQueryServiceTests.swift`
> Plans 004–005 intentionally change policy/coordinator/view-model/test files. Reconcile those final versions; unexpected changes are a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/005-device-selection-coordinator.md`
- **Category**: bug, tech-debt, docs
- **Planned at**: commit `6f2978f`, 2026-07-14

## Why this matters

After Plan 005, selection policy has one owner but legacy mutable fields and view-local refresh code still provide backdoors. `SettingsView` currently changes behavior simply by being open, and `AudioGraphManager` mixes user preference, discovered devices, channel mapping, and audio runtime state. This plan closes those backdoors: both views render coordinator state and send commands, while the graph accepts one validated resolved route transaction.

The user-visible result is explicit and predictable: the UI distinguishes the preferred device from a temporary fallback, automatically returns to the preferred device when it comes back, and never claims a fallback was the user's selection.

## Current state

- `Airwave/SettingsView.swift:52-95` installs five view-lifetime observers/refresh hooks.
- `Airwave/SettingsView.swift:774-983` implements aggregate selection, input switching, refresh, fallback, validation, and persistence independently.
- `Airwave/AirwaveMenuView.swift:319-360` renders from `AudioGraphManager` and delegates output choices to `MenuBarViewModel`.
- `Airwave/AudioGraphManager.swift:20-46` publishes both audio-engine state and selection/inventory state.
- `Airwave/AudioGraphManager.swift:139-224` stops, restores system audio, switches input, and sets up the HAL unit through several separately mutable properties.
- `Airwave/DeviceSelectionCoordinator.swift` from Plan 005 owns policy and currently mirrors resolved state to the legacy graph properties.

Current Settings refresh (`Airwave/SettingsView.swift:859-950`) can clear/select devices and persist fallback solely because the window appeared or a count changed. Current graph startup (`Airwave/AudioGraphManager.swift:149-168`) reads aggregate, selected input, and selected channel-range properties separately, so a partially updated route is representable.

Repository conventions to preserve:

- SwiftUI views observe shared `ObservableObject` instances and use explicit `Binding` adapters for pickers.
- UI strings are currently inline English; match that convention rather than introducing a localization system here.
- Volume safety ordering is intentional: capture current volume, set the target before switching, switch to the virtual input, then ramp the physical output. Preserve this behavior.
- CoreAudio setup and render code remain in `AudioGraphManager`; selection policy remains outside it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **`; tests execute |
| Selection tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/DeviceSelectionPolicyTests -only-testing:AirwaveTests/DeviceSelectionCoordinatorTests` | exit 0; suites pass |
| Legacy writer scan | `rg -n 'audioManager\.(aggregateDevice|availableInputs|availableOutputs|selectedInputDevice|selectedOutputDevice)\s*=' Airwave/SettingsView.swift Airwave/AirwaveMenuView.swift Airwave/MenuBarViewModel.swift` | exit 1; no matches |

## Scope

**In scope**:

- `Airwave/DeviceSelectionPolicy.swift`
- `Airwave/DeviceSelectionCoordinator.swift`
- `Airwave/MenuBarViewModel.swift`
- `Airwave/SettingsView.swift`
- `Airwave/AirwaveMenuView.swift`
- `Airwave/AudioGraphManager.swift`
- `AirwaveTests/AudioDeviceQueryServiceTests.swift`
- `README.md`
- `plans/README.md` (status only)

**Out of scope**:

- DSP/convolution, HRIR activation, FFT, WAV loading, and render callback logic.
- CoreAudio discovery and persistence internals completed in Plan 005.
- Xcode project/scheme files, app visual redesign, localization migration, or new device-priority UI.
- Changing the volume safety policy or automatically mutating the macOS default device when the engine is stopped.

## Git workflow

- Branch: `codex/006-device-selection-ui-routing`
- Suggested commits: `refactor: make selection views passive`, then `refactor: apply resolved audio routes`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Introduce one immutable runtime route

Add an `AudioRoute` value type at the coordinator/graph boundary containing:

- live aggregate `AudioDevice`;
- live input/output `SubDeviceInfo`;
- validated input and stereo output channel ranges;
- the inventory generation from which all values were derived.

The initializer must fail for mixed aggregates/generations, missing channel ranges, mono output, or out-of-bounds ranges. `AudioGraphManager` receives `apply(route:)` and `clearRoute()` methods. Applying a route updates aggregate, input, output, and both channel ranges as one main-actor transaction before any HAL reconfiguration.

Make selection/inventory properties read-only from outside the graph during migration (`private(set)`) and then remove `availableInputs`/`availableOutputs` from the graph entirely once views use the coordinator. Keep only `currentRoute` plus engine/error state.

**Verify**: add tests for valid route, mixed-generation rejection, mono rejection, and atomic replacement; Build and Selection tests pass.

### Step 2: Make route changes latest-wins and restart at most once

Implement one coordinator-to-graph effect for route transitions:

- engine stopped + valid new route → apply/configure without changing system default output;
- engine running + same aggregate/live IDs, only channel mapping changed → update/reconfigure once as required;
- engine running + aggregate/input/output live handle changed → stop internal unit without restoring through an obsolete route, apply the complete new route, switch system audio according to the new input, restart once;
- no valid route → stop safely, restore the last valid physical/system output, clear route, remain stopped;
- a newer inventory generation arriving during setup invalidates the older apply request; older completion must not overwrite the current route.

Preserve the existing volume ordering and saved-system-output fallback. Cancel or generation-check delayed volume ramp blocks so a ramp scheduled for an old output cannot execute after a route change.

**Verify**: fake-graph tests assert exact effect ordering and that callback bursts produce no multiple restart loop or stale volume effect.

### Step 3: Remove all selection behavior from SettingsView

Observe `DeviceSelectionCoordinator.shared`. Replace picker bindings so getters read coordinator preferences/effective state and setters call `selectAggregate(uid:)`, `selectInput(uid:)`, or `selectOutput(uid:)`.

Delete from `SettingsView`:

- device-count and aggregate-subdevice `.onChange` selection handlers;
- `selectAggregateDevice`, `selectInputDevice`, `selectOutputDevice` implementations that write the graph;
- `refreshAvailableOutputs`, `validateCurrentSelection`, and view-local fallback;
- direct `SettingsManager` writes and direct system-default output switching.

Keep `.onAppear` only for diagnostics/UI work. The Refresh button may call `coordinator.refresh()` and diagnostics refresh, but it must not select or persist anything directly.

**Verify**: Legacy writer scan returns no matches; `rg -n 'SettingsManager|setSystemDefaultOutputDevice|startMonitoringAggregateDevice' Airwave/SettingsView.swift` returns no matches.

### Step 4: Make menu and view model passive selection clients

Render menu output choices and selected values from coordinator state. Device row actions call coordinator commands directly or thin `MenuBarViewModel` forwarding methods with no side effects of their own.

Remove remaining device-selection storage and mirroring from `MenuBarViewModel`. It may continue to own preset/menu actions, but it must not observe device lists, decide fallbacks, configure routes, or save device UIDs.

**Verify**:

- Legacy writer scan returns no matches.
- `rg -n 'AudioDeviceManager|AggregateDeviceInspector|SettingsManager' Airwave/MenuBarViewModel.swift` returns no selection-related matches.
- Build succeeds.

### Step 5: Show preferred versus effective fallback explicitly

When status is fallback, show concise secondary text in Settings:

- `Preferred “<name>” is unavailable; using “<fallback>” temporarily.` when the preferred name is known from recent snapshot/history;
- otherwise `Preferred device is unavailable; using “<fallback>” temporarily.`

The picker/checkmark should represent the preferred UID when present in its list. If the preferred device is absent, show the effective fallback as active routing without displaying it as the saved preference. Use one small warning/status line; do not add dialogs or silently change preference.

When no route is possible, disable engine start and show the coordinator's explicit reason. When the preferred device returns, the warning disappears after the route transaction succeeds.

Add accessibility labels that state both preferred and effective devices during fallback.

**Verify**: coordinator/view-model tests expose four display states—preferred, fallback, unavailable, unconfigured—with exact strings or structured labels; Build succeeds.

### Step 6: Document the invariant table

Add a short “Device selection behavior” subsection to README Development or usage documentation:

| Event | Saved preference | Effective route |
|---|---|---|
| User chooses device | Update UID | Use chosen device |
| Refresh, same UID/new ID | Unchanged | Update live handle |
| Preferred device disconnects | Unchanged | Keep valid route or temporary fallback |
| Preferred device reconnects | Unchanged | Return automatically |
| Preferred aggregate disappears | Unchanged | Stop/clear route |
| App relaunches while preferred is absent | Unchanged | Temporary fallback; do not forget preference |

State that numeric CoreAudio IDs are never persisted and fallback never changes saved preference.

**Verify**: `rg -n 'Device selection behavior|temporary fallback|CoreAudio IDs' README.md` → all concepts present.

### Step 7: Run full regression and inspect final ownership

Run Build, All tests, Selection tests, and Legacy writer scan. Search for every assignment to device selection fields and confirm the coordinator/graph adapter is the only owner.

**Verify**:

- `rg -n '(aggregateDevice|selectedInputDevice|selectedOutputDevice|selectedInputChannelRange|selectedOutputChannelRange)\s*=' Airwave --glob '*.swift'` → assignments occur only inside `DeviceSelectionCoordinator` policy application and private `AudioGraphManager` route application.
- Full tests report `** TEST SUCCEEDED **` and execute all suites.
- `git diff --name-only` contains only Scope files.

## Test plan

- Retain all Plan 004 policy tests and Plan 005 coordinator/settings/inventory tests.
- Add audio-route validation and ordered-effect tests with a fake graph—no live CoreAudio.
- Add presentation-state assertions for preferred, fallback, unavailable, and unconfigured.
- Manual hardware smoke tests after automation passes:
  1. choose non-first input/output, quit/relaunch, verify both return;
  2. unplug preferred output while running, verify one fallback and one restart;
  3. relaunch while preferred is absent, verify preference remains visible as unavailable;
  4. reconnect it, verify automatic return;
  5. repeat with Settings closed, then open—the route must not change;
  6. switch aggregates and verify no input from the previous aggregate survives;
  7. repeat reconnection where CoreAudio assigns a new numeric ID;
  8. rapidly unplug/replug once and verify no restart loop or callback accumulation.

## Done criteria

- [ ] Views and MenuBarViewModel contain no selection/fallback/persistence writers.
- [ ] `AudioGraphManager` owns engine state and one immutable current route, not preference or inventory policy.
- [ ] Route application is atomic, generation-checked, and restarts at most once per accepted transition.
- [ ] Delayed volume work cannot affect a stale route.
- [ ] UI distinguishes saved preference from temporary fallback and inaccessible states.
- [ ] Opening/closing Settings cannot change selection.
- [ ] README invariant table documents disconnect, reconnect, relaunch, and ID churn.
- [ ] Build, all tests, selection tests, and scans pass.
- [ ] Manual smoke matrix passes on supported virtual and physical devices.
- [ ] No files outside Scope are modified.
- [ ] `plans/README.md` row 006 is DONE.

## STOP conditions

Stop and report if:

- Plans 004–005 are not DONE or their tests fail.
- A safe route transition requires changing real-time render/DSP code.
- macOS/CoreAudio cannot apply the documented route without an intermediate system-default device state not represented above; record the observed transition and ask for a policy decision.
- A supported aggregate exposes channel topology that cannot be validated against one inventory generation.
- The UI framework cannot represent an absent preferred picker value without implicitly invoking its setter; replace the Picker with a command menu only after reviewer approval, not by silently changing intent.
- Existing dirty project/scheme changes would be overwritten.

## Maintenance notes

- Future device-priority or “never fallback” features belong in `DeviceSelectionPolicy`; views must remain passive.
- Reviewers should trace every user-visible device change back to either an explicit command or one policy reconciliation event.
- Keep the preferred/effective distinction in logs and diagnostics so support reports can say “preferred unavailable, effective fallback X” instead of only “selected X.”

