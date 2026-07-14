# Plan 004: Define and test one deterministic device-selection policy

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If a STOP condition occurs, stop and report; do not improvise. When done, update this plan's status row in `plans/README.md`, unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6f2978f..HEAD -- Airwave/AudioDevice.swift Airwave/AggregateDeviceInspector.swift Airwave/DeviceSelectionPolicy.swift AirwaveTests/AudioDeviceQueryServiceTests.swift`
> If any in-scope file changed, compare the excerpts and contracts below with live code. Any material mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/003-device-snapshots-and-reproducible-workflow.md` (DONE)
- **Category**: tests, bug, tech-debt
- **Planned at**: commit `6f2978f`, 2026-07-14

## Why this matters

Device selection currently has no executable specification. The same hardware event is interpreted differently by `MenuBarViewModel` and `SettingsView`, and automatic fallback overwrites the user's durable preference in several paths. Before replacing those paths, this plan introduces a pure selection policy whose tests define the intended behavior: UIDs represent user intent, numeric CoreAudio IDs are live handles only, and fallback is temporary.

This plan does not connect the new policy to production UI or audio routing. It creates a safe seam and a regression matrix for Plans 005–006.

## Current state

- `Airwave/AudioDevice.swift` — immutable live device snapshots; equality is intentionally based on transient `AudioDeviceID`.
- `Airwave/AggregateDeviceInspector.swift` — creates aggregate subdevice channel ranges and exposes `SubDeviceInfo`.
- `AirwaveTests/AudioDeviceQueryServiceTests.swift` — only device-adjacent suite; covers snapshot properties, ID equality, and stale refresh rejection.
- `Airwave/MenuBarViewModel.swift` — current UID-aware restoration and fallback policy; not modified by this plan.
- `Airwave/SettingsView.swift` — second, ID-aware policy; not modified by this plan.

Current runtime identity (`Airwave/AudioDevice.swift:12-34`):

```swift
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String?
    // ...snapshot metadata...

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }
}
```

Current launch fallback (`Airwave/MenuBarViewModel.swift:315-324`):

```swift
if let outputUID = settings.selectedOutputDeviceUID,
   let output = audioManager.availableOutputs.first(where: { $0.uid == outputUID }) {
    audioManager.selectedOutputDevice = output
    lastUserSelectedOutputUID = output.uid
} else if let firstOutput = audioManager.availableOutputs.first {
    audioManager.selectedOutputDevice = firstOutput
    lastUserSelectedOutputUID = firstOutput.uid
}
```

Current Settings fallback (`Airwave/SettingsView.swift:901-937`) matches by `device.id`, selects the first available output/input when the ID is absent, and persists the input fallback.

Repository conventions to preserve:

- Models are small Swift value types with derived properties; follow `AudioDevice` and `AudioDeviceRefreshResult`.
- Hardware-independent tests use synthetic `AudioDevice` values; follow `AirwaveTests/AudioDeviceQueryServiceTests.swift:7-24`.
- Main-actor UI ownership is not needed in the pure policy. Do not import SwiftUI, AppKit, Combine, or call CoreAudio from `DeviceSelectionPolicy.swift`.
- Do not change `AudioDevice` equality/hash semantics in this plan; the policy must compare logical devices by non-optional UID explicitly.

The audit working tree had user-owned changes removing `AirwaveTests` from the shared scheme. A clean checkout of commit `6f2978f` contains the test action. Do not overwrite or revert the dirty scheme. If the test command still reports that the scheme is not configured for testing, STOP and ask the operator to reconcile that existing change.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **`; tests are actually listed as executed |
| Targeted policy tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/DeviceSelectionPolicyTests` | exit 0; all policy cases pass |

## Scope

**In scope** (the only files you should modify):

- `Airwave/DeviceSelectionPolicy.swift` (create)
- `AirwaveTests/AudioDeviceQueryServiceTests.swift` (append `DeviceSelectionPolicyTests`; keep the existing suite intact so project metadata need not change)
- `plans/README.md` (status only)

**Out of scope** (do not touch):

- `Airwave.xcodeproj/project.pbxproj` and `Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme` — user-owned dirty changes exist; this plan must not overwrite them.
- `Airwave/MenuBarViewModel.swift`, `Airwave/SettingsView.swift`, `Airwave/AudioGraphManager.swift`, and `Airwave/SettingsManager.swift` — production behavior changes in later plans.
- CoreAudio listener scheduling, aggregate inspection queries, volume behavior, system-default output switching, and engine start/stop.

## Git workflow

- Branch: `codex/004-device-selection-policy`
- Use conventional commits; suggested commit: `test: define device selection policy`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add hardware-independent selection types

Create `Airwave/DeviceSelectionPolicy.swift` with value types that make previously conflated concepts explicit:

- `DeviceSelectionPreferences`: optional `aggregateUID`, `inputUID`, and `outputUID`. These are durable user intent.
- `DeviceSelectionInventory`: one aggregate UID plus ordered input/output `SubDeviceInfo` arrays from one discovery snapshot. The ordered arrays preserve aggregate channel order.
- `EffectiveDeviceSelection`: resolved aggregate/input/output subdevices, plus an explicit status for each preference (`preferred`, `fallback(preferredUID:)`, `unavailable(preferredUID:)`, or `unconfigured`). Do not represent fallback by mutating preferences.
- `DeviceSelectionState`: preferences plus the current effective selection.
- `DeviceSelectionEvent`: `restorePreferences`, `inventoryChanged`, `userSelectedAggregate`, `userSelectedInput`, and `userSelectedOutput`.
- `DeviceSelectionPolicy.reduce(state:event:inventory:) -> DeviceSelectionState` as a pure deterministic function.

If importing `AggregateDeviceInspector.SubDeviceInfo` makes pure test construction awkward, define a minimal policy input containing `uid`, `liveDeviceID`, `inputChannelRange`, `outputChannelRange`, and inventory order. Provide a conversion initializer in the same file. Do not duplicate CoreAudio queries.

**Verify**: run the Build command → `** BUILD SUCCEEDED **` and no new concurrency warnings.

### Step 2: Encode the resolution rules in one place

Implement these rules exactly and document them beside the reducer:

1. Only `userSelected*` events change the corresponding preferred UID.
2. `restorePreferences` loads intent without inventing a first-device preference.
3. Resolution matches devices by UID. A new numeric `AudioDeviceID` for the same UID updates the effective live handle without changing intent.
4. If the preferred device is available and routable, it is effective.
5. If preferred is absent, keep the current effective device when it remains available; otherwise choose the first routable device in aggregate channel order as a temporary fallback.
6. A fallback never changes preferences.
7. When a preferred device returns, it becomes effective automatically.
8. If the preferred aggregate is unavailable, clear all effective aggregate/input/output values but retain every preferred UID.
9. Changing the preferred aggregate resolves input/output atomically against the new aggregate inventory; no subdevice from the old aggregate may survive.
10. Outputs with fewer than two channels are not routable as stereo. Inputs may use `lowerBound..<min(lowerBound + 2, upperBound)` and must never cross their actual range.
11. If no preference exists, the effective selection may use a temporary first routable device for onboarding, but its status must be `fallback(preferredUID: nil)` and it must not become durable until the user explicitly selects it.

Do not sort by display name. Aggregate channel order determines the first fallback; retaining the current effective device prevents unrelated inventory reorder from switching routes.

**Verify**: `rg -n 'UserDefaults|AudioObject|AudioGraphManager|SwiftUI|Combine' Airwave/DeviceSelectionPolicy.swift` → no matches.

### Step 3: Add the transition matrix tests

Append `@MainActor final class DeviceSelectionPolicyTests: XCTestCase` to `AirwaveTests/AudioDeviceQueryServiceTests.swift`. Use small helpers to create policy devices with stable UIDs and replaceable numeric IDs.

Cover at least these named cases:

- saved aggregate/input/output all present → all preferred devices resolve;
- same UID with new `AudioDeviceID` → preference is unchanged and live handle updates;
- preferred output temporarily absent → current valid route is retained or a fallback is chosen, but output preference is unchanged;
- preferred output returns → it automatically replaces the fallback;
- preferred input absent at launch → fallback is effective and preference remains absent UID;
- preferred aggregate absent → effective route is empty and all three preferred UIDs remain intact;
- aggregate changes → no old input/output object survives;
- inventory order changes while current fallback remains available → current fallback remains selected;
- current fallback disappears → next first routable output is chosen deterministically;
- mono output is excluded from stereo resolution;
- one-channel input range remains one channel and never overlaps the next subdevice;
- explicit user selection is the only event that changes the preferred UID;
- empty inventory produces explicit unavailable/unconfigured status without a crash.

**Verify**: run Targeted policy tests → all cases execute and pass.

### Step 4: Confirm this is a behavior-neutral seam

Review the diff and ensure no production caller uses `DeviceSelectionPolicy` yet. This plan must not alter selection, persistence, fallback, or audio routing in the running app.

**Verify**:

- `rg -l 'DeviceSelectionPolicy|DeviceSelectionState' Airwave --glob '*.swift'` → only `Airwave/DeviceSelectionPolicy.swift`.
- `git diff --name-only` → only the two in-scope source/test files and optional `plans/README.md` status update.
- Run All tests → `** TEST SUCCEEDED **` with a non-zero executed test count.

## Test plan

- Add the transition matrix above to the existing device test file so no Xcode project edit is necessary.
- Keep every test hardware-independent and deterministic: no live CoreAudio calls, sleeps, timers, or `UserDefaults.standard`.
- Each test asserts both durable preferences and effective selection/status; checking only the selected UID is insufficient.
- Verification: targeted policy tests and the full suite both pass.

## Done criteria

- [ ] Build exits 0 with `** BUILD SUCCEEDED **`.
- [ ] Full test command exits 0 with `** TEST SUCCEEDED **` and executes tests.
- [ ] At least 13 named selection-policy cases pass.
- [ ] Same-UID/new-ID, temporary absence, reconnect, aggregate change, empty inventory, and mono routing are covered.
- [ ] No production caller uses the new policy yet.
- [ ] No file outside Scope is modified.
- [ ] `plans/README.md` row 004 is updated to DONE.

## STOP conditions

Stop and report if:

- The shared scheme still has no test action; do not repair or revert the operator's existing dirty scheme change in this plan.
- `SubDeviceInfo` cannot be constructed without live CoreAudio and a minimal policy input would require changing existing public types.
- A policy rule above conflicts with a product decision documented after commit `6f2978f`.
- Any step requires changing current production behavior.
- A verification fails twice after a reasonable correction.

## Maintenance notes

- These tests are the product contract for Plans 005–006. Reviewers should reject later code that updates preferred UIDs during automatic fallback.
- UID-less CoreAudio devices are deliberately unresolved by this policy. If real supported hardware lacks UIDs, stop and design an explicit secondary identity strategy; never silently persist numeric IDs.
- Keep fallback ordering based on aggregate routing order, not localized names.

