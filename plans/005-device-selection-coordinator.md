# Plan 005: Make one coordinator own preferences, discovery, and fallback

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm expected result before moving on. Stop and report on any STOP condition; do not improvise. When done, update this plan's row in `plans/README.md`, unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6f2978f..HEAD -- Airwave/DeviceSelectionPolicy.swift Airwave/DeviceSelectionCoordinator.swift Airwave/SettingsManager.swift Airwave/AudioDevice.swift Airwave/AggregateDeviceInspector.swift Airwave/MenuBarViewModel.swift AirwaveTests/AudioDeviceQueryServiceTests.swift`
> Plan 004 intentionally adds the policy and tests. Reconcile its final code; unexpected changes elsewhere are a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/004-device-selection-policy.md`
- **Category**: bug, tech-debt
- **Planned at**: commit `6f2978f`, 2026-07-14

## Why this matters

Airwave currently has two selection controllers and two settings caches. CoreAudio callbacks, menu restoration, and an open Settings window can all write overlapping state, so the final device depends on event order. This plan creates one main-actor coordinator that consumes serialized inventory snapshots, applies Plan 004's pure policy, and persists only explicit user intent.

The existing `AudioGraphManager` remains the audio runtime during this plan. The coordinator mirrors its resolved selections into that manager through one adapter so behavior can migrate without a single high-risk rewrite.

## Current state

- `Airwave/MenuBarViewModel.swift` — always-alive controller; restores settings, observes aggregate lists, manages a separate aggregate listener, applies output fallback, and saves full snapshots.
- `Airwave/SettingsView.swift` — independently observes device counts and aggregate changes, applies different ID-based fallback rules, and persists inputs through another settings instance. Plan 006 removes this duplication; this plan provides the coordinator it will call.
- `Airwave/SettingsManager.swift` — full-record cached persistence with a warning that only `.shared` may be used.
- `Airwave/AudioDevice.swift` — async device query manager, three system listeners, and one correctly removable aggregate monitor.
- `Airwave/AggregateDeviceInspector.swift` — currently re-enumerates all devices while building each aggregate map.
- `Airwave/DeviceSelectionPolicy.swift` — pure reducer from Plan 004; its rules are authoritative.

Split settings writers (`Airwave/MenuBarViewModel.swift:23-28` and input save sites):

```swift
let deviceManager = AudioDeviceManager.shared
private let settingsManager = SettingsManager()
// ...
SettingsManager.shared.setInputDevice(input.device)
```

The settings store itself warns against this (`Airwave/SettingsManager.swift:42-55`):

```swift
/// **IMPORTANT**: Always use `SettingsManager.shared` to avoid cache divergence.
/// Each instance maintains its own cache and debounce timer, which can lead to
/// stale reads or lost saves if multiple instances are used.
```

Duplicate listener (`Airwave/MenuBarViewModel.swift:439-494`) registers a local CoreAudio callback on every aggregate selection, but its removal method only clears flags. `AudioDeviceManager.startMonitoringAggregateDevice` / `stopMonitoringAggregateDevice` at `Airwave/AudioDevice.swift:217-271` already provides symmetrical add/remove behavior.

Repository conventions to preserve:

- Published application state is mutated on `@MainActor`; follow `MenuBarViewModel`.
- CoreAudio property callbacks schedule work rather than mutating SwiftUI state directly.
- Immutable device metadata comes from `AudioDeviceQueryService`; do not restore synchronous per-view enumeration.
- Heavy/audio setup errors remain logged and exposed through `AudioGraphManager.errorMessage`.
- Preserve the current JSON key `Airwave.AppSettings` and decode existing installations; no preference reset is acceptable.

The audit working tree had user-owned project/scheme changes. They are outside scope. If full tests cannot run because the test action is absent, STOP rather than editing those files.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **`; tests execute |
| Selection tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/DeviceSelectionPolicyTests -only-testing:AirwaveTests/DeviceSelectionCoordinatorTests` | exit 0; both suites pass |

## Scope

**In scope**:

- `Airwave/DeviceSelectionPolicy.swift`
- `Airwave/DeviceSelectionCoordinator.swift` (create)
- `Airwave/SettingsManager.swift`
- `Airwave/AudioDevice.swift`
- `Airwave/AggregateDeviceInspector.swift`
- `Airwave/MenuBarViewModel.swift`
- `AirwaveTests/AudioDeviceQueryServiceTests.swift`
- `plans/README.md` (status only)

**Out of scope**:

- `Airwave/SettingsView.swift` and `Airwave/AirwaveMenuView.swift` — migrated in Plan 006.
- `Airwave/AudioGraphManager.swift` internals, DSP, HAL setup, volume ramps, and system-default output restore logic.
- Xcode project/scheme files and user Xcode state.
- Redesigning presets or `autoStart` semantics beyond preventing selection fallback from overwriting them.

## Git workflow

- Branch: `codex/005-device-selection-coordinator`
- Suggested commits: `refactor: centralize selection persistence`, then `refactor: coordinate device inventory`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Make settings persistence a single serialized store

Mark `SettingsManager` as `@MainActor` (or otherwise enforce one serialized executor consistent with app usage). Make its initializer private after tests no longer require direct construction. Add a mutation API such as:

```swift
func update(_ mutate: (inout AppSettings) -> Void) {
    var settings = loadSettings()
    mutate(&settings)
    saveSettings(settings)
}
```

Add explicit methods to update selection preferences, preset ID, and auto-start/running preference without rebuilding an `AppSettings` from unrelated runtime state. Existing decode/migration must preserve all fields. Ensure pending debounced data can be flushed synchronously on termination through a public `flushPendingSave()`.

Replace `MenuBarViewModel`'s `SettingsManager()` with injected/default `.shared`. Remove every remaining `SettingsManager()` construction.

Append tests using an isolated `UserDefaults(suiteName:)` injected into a test-only/internal initializer. Cover interleaved output, input, preset, and auto-start mutations; the final record must contain every latest field. Do not use `UserDefaults.standard` in tests.

**Verify**:

- `rg -n 'SettingsManager\(\)' Airwave --glob '*.swift'` → exactly the singleton construction inside `SettingsManager`, or no match if expressed differently.
- Selection tests pass, including interleaved settings updates.

### Step 2: Publish coherent inventory generations

Extend the query result or add a `DeviceInventorySnapshot` containing:

- a monotonically increasing generation owned on one actor/serial queue;
- all device snapshots;
- a UID lookup built from that same array;
- default input/output IDs;
- the selected aggregate's full subdevice UID list and derived channel map when monitoring one.

Serialize `refreshGeneration` mutation and refresh scheduling. CoreAudio's device/default callbacks must enqueue/coalesce a refresh on that owner; they must not race on an unsynchronized integer.

Refactor `AggregateDeviceInspector` to build channel maps from the supplied snapshot lookup instead of calling `AudioDeviceManager.getAllDevices()` internally. Keep one live CoreAudio read for the aggregate's subdevice UID list, then pair it with one explicitly supplied device generation. If the topology changes during that operation, discard/retry the whole generation rather than publishing a partially compressed map.

Expose only stereo-routable outputs to policy resolution; preserve mono devices in diagnostics if useful, but never create `startChannel..<(startChannel + 2)` beyond the actual range.

**Verify**:

- `rg -n 'getAllDevices\(\)' Airwave/AggregateDeviceInspector.swift` → no matches.
- Add a concurrent refresh test that invokes refresh scheduling from multiple queues and asserts published generations are monotonic and only the newest result is used.
- All tests pass.

### Step 3: Create the single main-actor coordinator

Create `@MainActor final class DeviceSelectionCoordinator: ObservableObject` with injected defaults for:

- `AudioDeviceManager.shared` / an inventory protocol;
- `AggregateDeviceInspector` / a topology protocol;
- `SettingsManager.shared` / a preferences-store protocol;
- a narrow audio-routing adapter backed initially by `AudioGraphManager.shared`.

Its published state is Plan 004's `DeviceSelectionState` plus user-facing availability/degraded information. It owns initialization state and Combine subscriptions. It must expose commands, not mutable public selection fields:

- `start()` / initialize once;
- `selectAggregate(uid:)`;
- `selectInput(uid:)`;
- `selectOutput(uid:)`;
- `refresh()` for an explicit user refresh;
- an internal inventory-change handler.

Initialization must wait for the first real inventory snapshot, then restore settings exactly once. Remove the fixed one-second delay. Every inventory/topology change runs through the policy reducer as one event. Update the audio adapter only after a complete state is resolved.

Only explicit `select*` commands persist preferred UIDs. Inventory changes, automatic first-device onboarding, fallback, disappearance, and reconnect must never call settings updates for device preferences.

**Verify**: coordinator tests with fakes cover startup before inventory, inventory then restore, callback burst coalescing, same-UID/new-ID, fallback, reconnect, and aggregate atomicity. No sleeps or live hardware.

### Step 4: Give the coordinator the only aggregate monitor

Use `AudioDeviceManager.startMonitoringAggregateDevice` when the effective/preferred aggregate changes and `stopMonitoringAggregateDevice` when cleared or replaced. Remove `MenuBarViewModel.addAggregateDeviceListener`, `removeAggregateDeviceListener`, its flags, and its callback.

One topology event must cause one coordinator reconciliation. Ensure switching A → B removes A's callback before registering B. Add a fake-monitor test asserting `stop(A)` precedes `start(B)` and an event from A after switching is ignored by generation/ownership.

**Verify**:

- `rg -n 'AudioObject(Add|Remove)PropertyListener|aggregateListenerAdded|currentMonitoredAggregate' Airwave/MenuBarViewModel.swift` → no matches.
- Coordinator listener lifecycle tests pass.

### Step 5: Route MenuBarViewModel through the coordinator

Inject/use `DeviceSelectionCoordinator.shared` in `MenuBarViewModel`. Delete its direct device-list observer, fixed-delay initialization, settings restoration for device UIDs, fallback/reconnect helpers, and device persistence. Keep HRIR/preset responsibilities temporarily.

For compatibility until Plan 006, `selectAggregateDevice`, `selectOutputDevice`, and any input command should delegate to coordinator commands. They must not write `AudioGraphManager` selection properties directly. The coordinator's narrow audio adapter may mirror effective values into `AudioGraphManager.availableInputs`, `availableOutputs`, `selectedInputDevice`, `selectedOutputDevice`, channel ranges, and aggregate device in one method.

When the effective route changes while the engine is running, preserve current stop/setup/restart behavior in the adapter, but do not let those `isRunning` changes save device preferences.

**Verify**:

- `rg -n 'lastUserSelectedOutputUID|waitForDevicesAndInitialize|restoreUserPreferredDevice|handleOutputDeviceDisconnected|refreshAvailableOutputsIfNeeded' Airwave/MenuBarViewModel.swift` → no matches.
- All tests and Build pass.

### Step 6: Add coordinator effect tests and verify no fallback persistence

Append `DeviceSelectionCoordinatorTests` to the existing test file. Use fake inventory, settings, monitor, and audio adapter types. Assert exact effect sequences for:

- explicit output choice: persist preferred UID, then apply resolved route;
- output disappears while running: retain preference, stop/apply fallback/restart exactly once;
- preferred output returns: apply preferred route without persistence write;
- aggregate disappears: retain all preferences, stop and clear route;
- aggregate returns with new ID: resolve by UID and update live route;
- aggregate changes: clear old route before applying the new atomic route;
- callback burst: one latest inventory result/effect sequence;
- interleaved input/output/preset settings mutations: no lost field.

**Verify**: Selection tests and All tests pass with actual executed counts.

## Test plan

- Continue using the existing test source file to avoid project metadata conflicts.
- Pure policy tests remain unchanged from Plan 004.
- Coordinator tests assert durable state and ordered effects separately.
- Inventory concurrency tests exercise multiple callback queues without real hardware.
- Settings tests use an isolated defaults suite and delete it in teardown.

## Done criteria

- [ ] Exactly one settings store instance and serialized mutation path exist.
- [ ] Exactly one aggregate subdevice monitor exists.
- [ ] Inventory generations are serialized; concurrent callback test passes.
- [ ] Aggregate channel mapping consumes one explicit snapshot lookup and never re-enumerates devices internally.
- [ ] One coordinator owns preferred and effective selection state.
- [ ] Only explicit user commands persist device UIDs.
- [ ] MenuBarViewModel contains no independent restore/fallback/listener algorithm.
- [ ] Build and full tests succeed; coordinator and policy suites execute.
- [ ] No files outside Scope are modified.
- [ ] `plans/README.md` row 005 is DONE.

## STOP conditions

Stop and report if:

- Plan 004 is not DONE or its policy tests do not pass.
- The shared scheme test action is unavailable in the execution worktree.
- Existing supported devices are observed without stable UIDs; this needs a product identity decision.
- A coherent aggregate topology snapshot cannot be obtained without a second CoreAudio generation token; do not silently accept torn data.
- Preserving engine state requires changing DSP/HAL internals outside the narrow adapter.
- Existing dirty Xcode project/scheme changes would be overwritten.

## Maintenance notes

- Review every persistence call: no callback, refresh, fallback, or reconnect path may update desired UIDs.
- `AudioDeviceID` is a live handle only. It may appear in applied routes and listener registrations, never in durable preference matching.
- Plan 006 removes the temporary mirrored selection fields from `AudioGraphManager` and makes both views read coordinator state directly.

