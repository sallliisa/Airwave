# Plan 002: Add a dedicated device profile management page

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0e64fa7..HEAD -- Airwave/DeviceProfileManager.swift Airwave/SettingsView.swift Airwave/AppDelegate.swift AirwaveTests/DeviceProfileManagerTests.swift AirwaveTests/ProductSurfaceTests.swift`
> This plan is intentionally written before Plan 001 exists. First confirm Plan
> 001 is marked DONE and that its live profile types/operations match the
> assumptions in "Current state after Plan 001." Any mismatch is a STOP
> condition; update this plan rather than guessing.

## Status

- **Priority**: P2
- **Effort**: M (a day-ish)
- **Risk**: MED — destructive persistence actions can affect active processing
- **Depends on**: `plans/001-device-profile-runtime.md`
- **Category**: direction
- **Planned at**: commit `0e64fa7`, 2026-07-17

## Why this matters

Plan 001 intentionally remembers every supported output Airwave encounters and
provides no administrative deletion UI. Over time, stale devices can accumulate,
and returning a device to a known bypassed state requires changing HRIR and EQ
separately. This follow-up adds one focused Devices page for inspection, atomic
reset, and safe forgetting without complicating the first runtime rollout.

## Product decisions (do not reinterpret)

- “Reset Profile” atomically sets HRIR and EQ to None but keeps the remembered
  device and its refreshed metadata.
- “Forget Device” deletes the profile record entirely. It is allowed only when
  the device is not the current default output because Airwave does not enumerate
  all connected devices; call this state “Not Current,” not “Disconnected.”
- If a forgotten UID becomes current later, Plan 001 recreates it as None/None.
- Both destructive actions require confirmation. Reset is disabled when already
  None/None. Forget is disabled for the current output.
- The page is reachable from the General settings navigation cards. The shared
  top-bar device editor is hidden on this management page, just as on Application.
- No Global profile, inheritance, reusable templates, connected-device scan,
  rename, or bulk actions are added.

## Current state after Plan 001

The executor must confirm these facts in live code before editing:

- `DeviceProfileManager` persists one `DeviceAudioProfile` per supported UID,
  publishes ordered profiles and `currentDeviceUID`, and routes effect mutations
  through typed change events consumed by `DeviceProfileRuntimeCoordinator`.
- A profile contains display metadata, optional HRIR/EQ preset IDs, and last-seen
  time. Both nil means native bypass.
- `SettingsPage` currently has General, Equalizer, and Application. General's
  `applicationSection` uses `AirwaveNavigationCard` for secondary pages.
- `SettingsWindowContent.topBarCenter` displays the Plan 001 device selector only
  on General and Equalizer.
- `ProductSurfaceTests` uses small pure presentation models where possible and
  source-surface assertions for shared window/style invariants. Match that mix;
  do not make persistence tests depend on rendered SwiftUI.

Relevant pre-Plan-001 exemplars at planning commit:

```swift
// Airwave/SettingsView.swift:324-348
AirwaveNavigationCard(title: "Equalizer", subtitle: "Configure your sound preference.") {
    withAnimation(settingsPageAnimation) { page.wrappedValue = .equalizer }
}
```

```swift
// Airwave/AppDelegate.swift:171-183
enum SettingsPage: String, CaseIterable {
    case general
    case equalizer
    case application
}
```

## Target interfaces and behavior

Extend `DeviceProfileManager` with two atomic operations:

```swift
@discardableResult
func resetProfile(deviceUID: String) -> Bool

@discardableResult
func forgetProfile(deviceUID: String) -> Bool
```

- Reset returns false/no-op for missing or already-empty profiles. Otherwise it
  clears both IDs, persists once, and emits one “both effects changed” event so
  a current-device reset causes one coordinated runtime transition, not separate
  HRIR and EQ transitions.
- Forget returns false/no-op for missing or current UID. Otherwise it removes
  and persists once. If it was `editingDeviceUID`, select current UID if present,
  otherwise the most recently seen remaining profile, otherwise nil. Emit a
  metadata/removal event but no runtime reconfiguration for a non-current UID.

Add `Airwave/DeviceManagementView.swift`. Keep destructive-action state in a
small coordinator/presentation model so behavior is unit-testable without UI
automation. Each row shows:

- device name as primary text;
- transport and `Current` or `Not Current` as secondary metadata;
- resolved HRIR and EQ display names, using `None` for nil/missing;
- Reset Profile and Forget Device actions with appropriate disabled states.

Use existing Airwave palette/layout/card components. Use confirmation dialogs:

- Reset: “Reset <device> profile?” / explanation that both HRIR and EQ become
  None / destructive button “Reset Profile”.
- Forget: “Forget <device>?” / explanation that a future encounter recreates a
  blank profile / destructive button “Forget Device”.

After either action, keep the page stable and announce the result accessibly.
Do not navigate away automatically.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/DeviceProfileManagerTests -only-testing:AirwaveTests/DeviceProfileManagementTests -only-testing:AirwaveTests/ProductSurfaceTests test` | exit 0; selected suites pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; all suites pass |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0, build succeeds |
| Safety gates | `scripts/test-audio-safety-invariants.sh && scripts/test-release-version.sh && scripts/verify-2.0-metadata.sh` | exit 0; all pass |

Use the explicit Debug configuration; do not repair the pre-existing implicit
Release test/scheme behavior in this plan.

## Scope

**In scope**:

- `Airwave/DeviceProfileManager.swift`
- `Airwave/DeviceManagementView.swift` (new)
- `Airwave/SettingsView.swift`
- `Airwave/AppDelegate.swift` for the `SettingsPage` case/title only
- `Airwave/AirwaveStyle.swift` only if an existing reusable component cannot
  express the row without duplication
- `AirwaveTests/DeviceProfileManagerTests.swift`
- `AirwaveTests/DeviceProfileManagementTests.swift` (new)
- `AirwaveTests/ProductSurfaceTests.swift`
- `README.md` only for a short Devices-page management note

**Out of scope**:

- Any change to runtime output observation/preparation, DSP, permission, retry,
  pipeline, HRIR activation, EQ processing, or Core Audio platform code.
- Forgetting the current output, route changes, or connected-device enumeration.
- Global/default profiles, inheritance, templates, profile copy/export/import,
  renaming, bulk reset/forget, or automatic stale-device expiry.
- Adding reset/forget actions to the menu-bar popover or top-bar dropdown.
- Preset-file deletion behavior; Plan 001 already reconciles missing references.
- Scheme/CI/release configuration.

## Git workflow

- Branch: `codex/002-device-profile-management`
- Conventional commits, e.g. `feat(profiles): add device management page`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Verify Plan 001 contract and add manager operations

Confirm Plan 001 is DONE and inspect its live profile manager/change-event API.
Add atomic reset and guarded forget without changing stored schema. Extend tests:

- reset clears both IDs with one persistence write/change event;
- reset missing/already-empty is false and writes nothing;
- current reset emits one current runtime-relevant event;
- forget non-current removes/persists and repairs editing fallback;
- forget current and missing are false/no-op;
- forgotten UID encountered again is recreated None/None.

**Verify**: targeted `DeviceProfileManagerTests` → pass.

### Step 2: Build a pure presentation/coordinator layer

Create testable row models and confirmation state in
`DeviceManagementView.swift`. Resolve preset names through the existing HRIR/EQ
libraries, but never mutate those libraries. Define deterministic row ordering
using the profile manager's current-first ordering. Test labels, button enabled
states, confirmation cancel/confirm paths, manager-call counts, and accessible
result message.

**Verify**: targeted `DeviceProfileManagementTests` → pass.

### Step 3: Add the Devices settings page

Add `SettingsPage.devices`, title/subtitle, a “Devices” navigation card on
General, and the page content. Preserve back navigation and fixed 900×600 layout;
use scrolling for unbounded remembered profiles. Hide the shared top-bar profile
selector on Devices. Follow existing reduce-motion and card styling.

Run ProductSurfaceTests and add assertions for page navigation, selector
visibility rules, confirmation copy, current forget disabled, empty state, and
scrolling container.

**Verify**: targeted ProductSurfaceTests plus build → pass.

### Step 4: Run regressions and update docs

Add a concise README note describing Devices → Reset Profile/Forget Device and
the not-current restriction. Run all commands. Confirm the diff contains no
runtime/audio files outside Scope and no unrelated style rewrite.

**Verify**: full tests and safety gates → pass; `git status --short` contains
only declared files and plan status.

## Test plan

- Extend `DeviceProfileManagerTests` for exact persistence and event semantics.
- Create `DeviceProfileManagementTests` for pure row/action/confirmation behavior.
- Extend `ProductSurfaceTests` for Settings navigation and visual contract.
- Regression cases: resetting current active HRIR+EQ yields one pair change;
  resetting inactive device does not touch runtime; forgetting selected remembered
  device picks deterministic fallback; forgetting current is impossible; empty
  profile list renders useful guidance.
- Run the full explicit Debug suite after targeted tests.

## Done criteria

- [ ] Devices is reachable from General and renders all remembered profiles in
  a scrollable current-first list.
- [ ] Reset atomically persists None/None and produces one coordinated change.
- [ ] Forget removes only non-current profiles and repairs editor selection.
- [ ] Confirmation is required for both actions; disabled/no-op cases are tested.
- [ ] The top-bar profile selector is hidden on Devices.
- [ ] Re-encountering a forgotten device recreates a blank profile.
- [ ] Targeted tests, full tests, build, and safety gates all exit 0.
- [ ] No runtime/audio source outside Scope changed.

## STOP conditions

Stop and report instead of improvising if:

- Plan 001 is not complete or its manager lacks a typed single-event way to
  represent both-effect reset.
- Determining “connected” would require output enumeration; retain the
  current/not-current contract instead.
- Forgetting a non-current profile triggers runtime reconfiguration.
- Resetting the current profile cannot be expressed as one coordinated
  transition without changing Plan 001 architecture; revise Plan 001 first.
- The page cannot fit the fixed settings window with scrolling and existing
  layout tokens.
- Any verification fails twice after a reasonable in-scope fix.

## Maintenance notes

- “Not Current” is intentional and accurate; Airwave does not know whether a
  remembered output is physically disconnected.
- Do not add automatic profile expiry without a separate retention decision.
- Future named templates should be separate entities referenced/copied by a
  device profile; they must not turn this list into implicit Global inheritance.
- Review destructive-action event counts and persistence writes, not just UI.

