# Plan 013: Add the Equalizer Settings section and product validation

> **Executor instructions**: Build the approved import/select/inspect product
> surface on the completed library/runtime. Do not add editing or downloads.
> Run every gate and update `plans/README.md` when complete.
>
> **Drift check (run first)**:
> `git diff --stat 28b0210..HEAD -- Airwave/SettingsView.swift Airwave/AirwaveStyle.swift Airwave/AppDelegate.swift Airwave/MenuBarViewModel.swift AirwaveTests/ProductSurfaceTests.swift README.md docs/release-validation.md`
> Confirm plans 010-012 are DONE and use their public interfaces rather than
> duplicating parser, persistence, or readiness logic in SwiftUI.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/012-compose-eq-runtime.md`
- **Category**: direction / docs
- **Planned at**: commit `28b0210`, 2026-07-16

## Why this matters

Users need a clear opt-in surface that does not imply Airwave ships or
recommends headphone curves. A dedicated Settings page gives drag-and-drop
import enough room for library selection, read-only inspection, and actionable
errors while preserving the existing General layout.

## Current state

- `SettingsView` is a fixed 900×600 dark canvas with a General-style two-column
  layout and no internal navigation.
- `AirwaveSectionHeader`, palette/layout constants, preset rows, and
  `AirwaveHRIRDropModifier` in `AirwaveStyle.swift` define the visual and drop
  conventions to reuse.
- `SettingsWindowContentState` already switches the entire window between
  Settings and onboarding. The new General/Equalizer page choice belongs inside
  Settings and must not create another `NSWindow` or interfere with setup.
- `EqualizerManager` from Plan 010 is the only source for library, selection,
  import, collision, delete, and error state. `AudioRuntimeState` remains the
  source for runtime health.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Product tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/ProductSurfaceTests -only-testing:AirwaveTests/EqualizerLibraryTests test` | selected tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | `ANALYZE SUCCEEDED` |
| Release/safety | `scripts/test-audio-safety-invariants.sh && scripts/test-release-version.sh && scripts/verify-2.0-metadata.sh` | all pass |
| Whitespace | `git diff --check` | no output |

## Scope

**In scope**: General/Equalizer page switching, a focused EQ Settings view/drop
modifier if needed, import/open-folder/delete controls, read-only details,
errors/accessibility, product tests, README, and manual validation notes.

**Out of scope**: band editing, rename/export, response graphs, downloads,
bundled presets, menu-bar EQ controls, onboarding changes, full EqualizerAPO
support, limiter/headroom automation, or redesign of existing General cards.

## Git workflow

- Branch: `codex/013-equalizer-settings`
- Suggested commit: `feat(ui): add equalizer settings section`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add Settings-local page navigation

Introduce `SettingsPage.general` and `.equalizer` as Settings-local state,
defaulting to General whenever a newly created Settings surface opens. Add a
compact top segmented picker directly beneath/alongside the “Settings” heading.
Keep the existing General page content and 900×600 window size unchanged; only
its header subtitle may become page-specific. Do not persist the page choice.

Use “General” and “Equalizer” labels. Keyboard focus and VoiceOver must expose
the picker as navigation, and reduced-motion users must get a simple opacity/no
movement transition.

**Verify**: product tests exercise page state/default and source assertions find
one Settings window and one shared `MenuBarViewModel` construction path.

### Step 2: Build the library and detail layout

Use the Equalizer page's full content width with two cards:

- Left library: synthetic “None” first and selected by default, then imported
  presets sorted by the manager. Each row shows name and selection state. Add
  Import, Show in Finder, and Delete controls. Disable Delete for None.
- Right detail: for None, explain that EQ is bypassed and selecting a preset is
  the opt-in. For a preset, show display name, managed filename, prominent
  preamp, and a read-only ordered list with ON/OFF, PK/LSC/HSC, frequency, gain,
  and Q. Preserve OFF rows visually but clearly muted.

Selecting a row immediately calls the manager. Do not add Apply, master toggle,
or a second selection cache. The active selection remains visible even when a
runtime sample-rate error causes safe EQ bypass.

**Verify**: model/view tests cover None, populated/empty library, exact details
for the reference fixture, OFF presentation, and selection persistence.

### Step 3: Add drag/drop and accessible file import

Make the complete Equalizer page a typed URL drop target for files and reuse
the HRIR overlay/inline-result visual language with EQ-specific copy: “Drop
EqualizerAPO .txt presets.” Add an Import button using a multi-select
`NSOpenPanel` restricted to plain-text/`.txt` files so keyboard and VoiceOver
users have equivalent functionality.

Preflight before mutation. If same-name conflicts exist, present one Replace / 
Keep Existing confirmation; either choice still imports valid non-conflicting
files. Each file remains atomic and batch results may be partial. After import,
select the first successfully imported preset in input order. On zero successes,
preserve selection. Replacing the active preset keeps its stable ID and triggers
the processor's live crossfade.

Show concise inline success/partial failure. For parse errors, show filename and
line-numbered reasons without raw external paths. Announce results through an
accessibility live region and replace/dismiss old messages deterministically.

**Verify**: UI coordinator tests cover input order, conflict choices, partial
success, zero-success selection preservation, active replacement, and messages.

### Step 4: Implement folder and deletion actions

“Show in Finder” opens/reveals the managed `Equalizer Presets` directory, not an
external source. Always confirm deletion with preset name and managed-copy
wording. Deleting the active preset selects None, allows the 20 ms transition,
and lets runtime policy stop only when no HRIR remains. Never allow deletion of
None or deletion outside the managed directory.

If deletion fails, retain the library row and selection and show the manager's
structured error. Do not optimistically remove UI state before filesystem
success.

**Verify**: product/library tests cover confirmation decisions, inactive and
active deletion, failure preservation, Finder target, HRIR+EQ deletion, and
EQ-only deletion.

### Step 5: Document compatibility and validate the product

Update README with a short Equalizer section: Airwave ships no curves; import
EqualizerAPO-style `.txt`; supported v1 directives are Preamp plus PK/LSC/HSC
with Q; None is default; EQ can run alone; when combined, order is HRIR then EQ;
preamp is applied exactly and no limiter/auto-headroom exists; files are copied
to managed storage. Link the upstream configuration reference.

Add manual validation rows to `docs/release-validation.md` for import/collision,
relaunch persistence, EQ-only, HRIR+EQ, live switching, deletion, incompatible
sample rate, sleep/wake, output changes, and audible click inspection. Do not
mark hardware/audio observations PASS without performing them.

**Verify**: Product tests, full tests, build, analyze, release/safety scripts,
and `git diff --check` pass.

## Test plan

- Automated: navigation, None default, empty/populated library, reference
  details, drop/import/collision/error actions, delete, accessibility labels,
  persistence, and no second source of selection truth.
- Manual: drag one/many files, malformed file, duplicate replacement, relaunch,
  EQ-only and combined listening, preset and None transitions, active deletion,
  44.1/48/96 kHz output changes, sleep/wake, permission loss, and native audio
  after the final effect is removed.

## Done criteria

- [ ] Settings has separate General and Equalizer pages without another window.
- [ ] No bundled preset exists; None is first/default and selection is opt-in.
- [ ] Drag/drop and Import provide equivalent, atomic managed-copy behavior.
- [ ] Users can inspect but cannot edit imported preamp/filter parameters.
- [ ] Errors preserve the last working selection and are actionable/accessibly
  announced.
- [ ] Documentation states the exact subset, processing order, and no-limiter
  behavior; every automated gate passes.

## STOP conditions

- The UI requires duplicating manager selection/import state in a view model.
- Typed URL drops or `NSOpenPanel` cannot balance security-scoped access through
  the Plan 010 import boundary.
- Settings cannot fit at 900×600 without truncating filter rows or making
  primary controls inaccessible; report measurements before resizing.
- A manual test reveals clicks, silence, feedback, route mutation, volume
  mutation, or a tap remaining active after neither effect is selected.

## Maintenance notes

The two-page switcher is intentionally preferred over a sidebar for only two
pages. Reconsider navigation only when a third durable Settings destination is
approved. Keep future EQ authoring or graphs in separate plans.

