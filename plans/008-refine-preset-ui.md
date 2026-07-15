# Plan 008: Refine branding, HRIR selection, and Settings layout

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. This
> plan is presentation-only: do not add file importing or change application
> activation/menu-bar lifecycle. When done, update this plan's row in
> `plans/README.md` unless a reviewer says they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 9b6b871..HEAD -- Airwave/AirwaveStyle.swift Airwave/AirwaveMenuView.swift Airwave/SettingsView.swift Airwave/OnboardingView.swift Airwave/Assets.xcassets/AirwaveMark.imageset AirwaveTests/ProductSurfaceTests.swift Airwave.xcodeproj/project.pbxproj`
> This plan was written while the UI restoration was still uncommitted. Also
> run `git diff --stat` and compare the live symbols and strings with “Current
> state.” Preserve those existing changes; do not reset or overwrite them.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/005-rebuild-product-surfaces.md` (DONE)
- **Category**: direction
- **Planned at**: commit `9b6b871`, 2026-07-15

## Why this matters

Settings and onboarding currently use native `Picker(.menu)` controls while the
menu bar uses a polished animated accordion. The mismatch makes the primary
Airwave setting feel less intentional outside the menu. Settings also stacks
two independent sections vertically despite having enough desktop space for a
clear spatial/application split. This plan makes those surfaces consistent
without touching audio, persistence, importing, or application lifecycle.

## Current state

- `Airwave/AirwaveMenuView.swift` contains the visual behavior to reuse:
  `MenuAccordion` rotates a chevron and transitions expanded content with
  opacity plus a move from the top; `MenuSelectionRow` supplies hover and
  checkmark states. These types are currently private and menu-sized.
- `Airwave/SettingsView.swift` renders `pageHeader`, `spatialProfileSection`,
  and `applicationSection` in one vertical `VStack` constrained to 680 points.
  Its preset control is a fixed-size native menu picker in a 180-point trailing
  column.
- `Airwave/OnboardingView.swift` uses the same native picker on only the
  `.hrirPreset` page. Selection is correctly routed through
  `menuViewModel.selectPreset(...)`; preserve this data flow.
- `Airwave/AirwaveStyle.swift` is the shared design-system exemplar. Use
  `AirwavePalette.canvas/raised/hover`, 24-point major spacing, 12-point
  section/card spacing, the shared corner radius and row padding, and
  `accessibilityReduceMotion` for animation decisions.
- `Airwave/Assets.xcassets/AirwaveMark.imageset/airwave-mark.svg` contains the
  prior weight-200 path. The requested replacement is
  `/Users/gamer/Downloads/airwave_24dp_E3E3E3_FILL0_wght300_GRAD0_opsz24.svg`.
  The source file must remain untouched; only its SVG contents are copied into
  the existing template-rendered asset.
- Settings currently defaults to 820×650 in `Airwave/AirwaveApp.swift` and the
  root view uses a 760-point minimum width. Onboarding remains 820×590 and must
  not be widened by this plan.

## Commands you will need

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for all Xcode
commands because this workspace may otherwise select Command Line Tools.

| Purpose | Command | Expected on success |
|---|---|---|
| Debug build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exits 0 with `BUILD SUCCEEDED` |
| Product tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/ProductSurfaceTests test` | exits 0; all product tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exits 0; all tests pass |
| Release build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exits 0 with `BUILD SUCCEEDED` |
| Safety | `scripts/check-audio-safety-invariants.sh && scripts/test-audio-safety-invariants.sh` | both print their passed messages |
| Whitespace | `git diff --check` | no output, exit 0 |

## Scope

**In scope** (the only production files to modify):

- `Airwave/Assets.xcassets/AirwaveMark.imageset/airwave-mark.svg`
- `Airwave/AirwaveStyle.swift`
- `Airwave/AirwaveMenuView.swift`
- `Airwave/SettingsView.swift`
- `Airwave/OnboardingView.swift`
- `Airwave/AirwaveApp.swift`
- `AirwaveTests/ProductSurfaceTests.swift`
- `Airwave.xcodeproj/project.pbxproj` only if a new shared Swift file must be
  registered; prefer placing the component in `AirwaveStyle.swift` to avoid it.

**Out of scope**:

- `HRIRManager`, preset directory watching, file copying, drag-and-drop and
  replacement confirmation. Plan 009 owns all import behavior.
- `Info.plist`, `AppDelegate`, `LaunchAtLoginManager`, `MenuBarExtra` insertion,
  Dock policy, reopen behavior, or new `UserDefaults` keys. Plan 009 owns these.
- Audio-runtime contracts, output handling, permission state, onboarding
  completion gates, and HRIR activation semantics.
- Reintroducing a custom accent color or public output-device messaging.

## Git workflow

- Branch: `codex/008-refine-preset-ui`
- Use one logical commit, matching current history, for example:
  `feat(ui): refine preset selection surfaces`.
- Do not stage, commit, push, or open a PR unless instructed by the operator.

## Steps

### Step 1: Replace the wave mark with the supplied weight-300 SVG

Copy the complete SVG markup from the supplied Downloads file into the existing
asset file. Preserve the imageset name, filename, template-rendering metadata,
24×24 dimensions, view box, and use of the asset in the menu bar, menu header,
Settings header, and onboarding header. Do not redesign or rasterize it.

**Verify**:

```sh
python3 - <<'PY'
from pathlib import Path
def normalized(path): return ''.join(Path(path).read_text().split())
assert normalized('Airwave/Assets.xcassets/AirwaveMark.imageset/airwave-mark.svg') == normalized('/Users/gamer/Downloads/airwave_24dp_E3E3E3_FILL0_wght300_GRAD0_opsz24.svg')
PY
```

Expected: exit 0 with no output. If the Downloads file is unavailable, stop;
do not approximate its path.

### Step 2: Extract a reusable animated preset accordion

Create a shared internal SwiftUI component usable at normal card width. Keep
menu-specific typography/padding in the existing menu implementation, but share
the interaction model and selection-row treatment where practical. The card
variant must provide:

- A collapsed button row labeled “HRIR Preset,” showing the active preset or
  “None,” plus a trailing chevron.
- Inline expansion below an inset divider; rotate the chevron and transition
  the list with opacity plus top-edge movement. With Reduce Motion enabled,
  use a short opacity-only transition.
- Alphabetical ordering via `MenuBarViewModel.sortedPresets` and a “None” row
  followed by presets. Selected rows display a trailing checkmark.
- Full-row hit targets, keyboard activation, hover background, selected and
  expanded accessibility values, and no custom orange tint.
- A maximum list height near 220 points with scrolling for long lists. Do not
  let expansion grow either window without bound.
- A non-interactive empty message when no presets exist. Keep the surrounding
  folder-management action visible.

The component accepts values and closures; it must not own or observe
`HRIRManager`, call Core Audio, or create a second selection model. Both callers
continue selecting through `MenuBarViewModel.selectPreset`.

**Verify**: run the ProductSurfaceTests command. Expected: all existing sorting
and target-sample-rate tests pass. Add source-oriented assertions only for
stable behavior (shared component is used twice, native `.pickerStyle(.menu)`
is absent from Settings/onboarding); do not test private layout constants by
copying source text unnecessarily.

### Step 3: Adopt the accordion in Settings and onboarding

Replace only the native HRIR picker in the Spatial Profile Settings card and on
the onboarding HRIR page. Keep “Manage Files” / “Open Preset Folder” aligned to
the same trailing edge as the accordion value and preserve existing empty-state
copy without repeating the selected preset elsewhere. Expansion state is local
to each surface and initially collapsed each time the window/page is created.

Do not modify the menu bar’s visible behavior: it remains a compact 280-point
popover with its current HRIR accordion.

**Verify**:

```sh
rg -n 'pickerStyle\(\.menu\)|Picker\("", selection: presetSelection\)' Airwave/SettingsView.swift Airwave/OnboardingView.swift
```

Expected: no matches. Then run the Debug build.

### Step 4: Convert Settings to a balanced two-column layout

Keep the page header full width. Under it, render a top-aligned two-column grid
or `HStack` with 12 points between equal-width columns:

- Left column: Spatial Profile.
- Right column: Application, including Launch at Login, Software Update, Set Up
  Airwave Again, and About Airwave.
- Debug-only runtime diagnostics: full width below the two-column production
  area, not squeezed into either column.

Widen the Settings scene and root view to an ideal/default size of 1080×680 and
a minimum width of 960. Constrain the central content to approximately 1000
points so both columns have useful row width. Retain the branded chrome, scroll
fades, 24-point page spacing, 12-point inter-column/card spacing, shared row
padding and corner radius. Keep vertical scrolling for smaller displays and do
not alter onboarding dimensions.

**Verify**: run Debug and Release builds. Manually resize to the minimum and
confirm neither column overlaps, truncates action controls beyond existing
line limits, nor introduces horizontal scrolling.

### Step 5: Complete regression validation

Run the full tests, both safety scripts, and `git diff --check`. Inspect the diff
and confirm no persistence key, import method, audio-runtime call, output copy,
or onboarding completion predicate changed.

**Verify**:

```sh
git diff --name-only -- Airwave AirwaveTests Airwave.xcodeproj | sort
```

Expected: only files listed in this plan's in-scope section.

## Test plan

- Extend `AirwaveTests/ProductSurfaceTests.swift`, following its existing
  preset-sorting tests, to cover any extracted pure presentation model: sorted
  names, selected ID, “None,” and empty collection.
- Exercise selection through `MenuBarViewModel`; do not instantiate live audio
  or TCC in tests.
- Manual accessibility checks: VoiceOver announces collapsed/expanded state and
  selected preset; keyboard can expand and choose a row; Reduce Motion avoids
  movement.
- Manual visual checks: menu remains compact, Settings columns align, both new
  accordions animate cleanly, long lists scroll, and onboarding dimensions do
  not change.

## Done criteria

- [ ] Bundled `AirwaveMark` is byte-insensitively equivalent to the supplied
  weight-300 SVG and remains template-rendered everywhere.
- [ ] Settings and onboarding use one shared animated HRIR accordion and no
  native menu picker.
- [ ] Selection still flows through `MenuBarViewModel.selectPreset`.
- [ ] Settings is two-column at 1080×680 ideal size; Debug Health is full width.
- [ ] Menu and onboarding window sizes/structure are otherwise unchanged.
- [ ] Debug build, Release build, full tests, safety scripts, and
  `git diff --check` all pass.
- [ ] No files outside this plan's scope are modified by the executor.
- [ ] `plans/README.md` marks Plan 008 DONE.

## STOP conditions

Stop and report rather than improvising if:

- The supplied SVG is missing or its view box/path cannot be preserved.
- Sharing the accordion would require moving audio activation or manager
  observation into the component.
- The current working tree no longer contains the restored dark UI described
  above, or completing the layout would discard unrelated uncommitted work.
- A two-column layout cannot fit at 960 points without changing existing copy
  or removing controls; report the measured minimum instead.
- Any step requires changes to `HRIRManager`, `Info.plist`, `AppDelegate`, menu
  insertion, persistence schema, or audio-runtime code.

## Maintenance notes

Plan 009 will turn the Spatial Profile/onboarding HRIR card into a drop target;
keep the accordion container composable so it can receive a drop-overlay state
without duplicating the selector. Reviewers should focus on a single source of
selection truth, reduced-motion behavior, window sizing on smaller displays,
and accidental regressions to custom accent or legacy output UX.
