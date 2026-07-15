# Plan 009: Add safe HRIR importing and hidden menu-bar app lifecycle

> **Executor instructions**: Follow this plan step by step and run every
> verification gate. This plan changes persistence, filesystem mutation, and
> application presentation; do not combine those concerns with unrelated audio
> refactors. When done, update this plan's row in `plans/README.md` unless a
> reviewer says they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 9b6b871..HEAD -- Airwave/AirwaveApp.swift Airwave/AppDelegate.swift Airwave/Info.plist Airwave/SettingsView.swift Airwave/OnboardingView.swift Airwave/HRIRManager.swift Airwave/MenuBarViewModel.swift AirwaveTests Airwave.xcodeproj/project.pbxproj`
> Confirm Plan 008 is DONE and its shared preset accordion exists. This plan was
> authored while the restored UI was uncommitted, so also inspect `git diff` and
> preserve all pre-existing UI changes.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/008-refine-preset-ui.md`
- **Category**: migration / direction
- **Planned at**: commit `9b6b871`, 2026-07-15

## Why this matters

Airwave currently requires users to open a managed Finder folder and copy HRIR
files manually. It also always inserts its status item even though users want a
hidden mode. Because `Info.plist` sets `LSUIElement=true`, simply removing the
status item would strand the running app with no Dock icon or reliable route
back to Settings. This plan adds a validated, recoverable import boundary and a
tested accessory-app lifecycle where external launches reopen Settings without
making background/login launches intrusive.

## Current state

- `Airwave/AirwaveApp.swift` declares an unconditional `MenuBarExtra` and two
  SwiftUI `Window` scenes. Settings is opened from the menu with
  `openWindow(id: "settings")`.
- `Airwave/Info.plist` has `LSUIElement` set to true. Keep it true: the product
  decision is no Dock icon, even when the menu item is hidden.
- `Airwave/AppDelegate.swift` launches audio in
  `applicationDidFinishLaunching`, observes sleep/wake, and can only front a
  Settings window after its `SettingsWindowAccessor` has registered one. It has
  no cold-launch/reopen route that creates Settings.
- `Airwave/HRIRManager.swift` owns a private Application Support
  `Airwave/presets` directory, scans `.wav` files, validates new discoveries via
  `WAVLoader.load`, persists `presets.json`, and watches the directory with
  FSEvents. It exposes only folder opening/removal/activation; there is no
  explicit import API or injectable preset directory for filesystem tests.
- `MenuBarViewModel.selectPreset` is the authoritative UI activation path. It
  chooses the active output sample rate with a 48 kHz fallback and stereo input
  layout. Imported preset activation must go through this method.
- Plan 008 provides the shared animated preset accordion and the two-column
  Settings shell. Add import/drop and preference UI to those surfaces rather
  than recreating their styling.
- Product decisions already made: “Show in Menu Bar” defaults on; turning it
  off keeps Airwave and processing running with no Dock icon; reopening Airwave
  through Finder, Spotlight, or Applications opens Settings; dropped files are
  copied, never moved; duplicate names require confirmation; all valid files
  import and the first successful file in drop order becomes active.

## Commands you will need

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Xcode
commands.

| Purpose | Command | Expected on success |
|---|---|---|
| Debug build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exits 0 with `BUILD SUCCEEDED` |
| Product/import tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/ProductSurfaceTests test` | exits 0; all selected tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exits 0; all tests pass |
| Release build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exits 0 with `BUILD SUCCEEDED` |
| Safety | `scripts/check-audio-safety-invariants.sh && scripts/test-audio-safety-invariants.sh` | both print their passed messages |
| Metadata | `scripts/verify-2.0-metadata.sh` | exits 0 and reports valid metadata |
| Whitespace | `git diff --check` | no output, exit 0 |

## Scope

**In scope**:

- `Airwave/AirwaveApp.swift`
- `Airwave/AppDelegate.swift`
- `Airwave/Info.plist` only if required to preserve/document accessory behavior;
  `LSUIElement` must remain true.
- `Airwave/HRIRManager.swift`
- `Airwave/MenuBarViewModel.swift`
- `Airwave/SettingsView.swift`
- `Airwave/OnboardingView.swift`
- At most two new focused production files for menu visibility/presentation and
  HRIR importing; register them in `Airwave.xcodeproj/project.pbxproj` if needed.
- `AirwaveTests/ProductSurfaceTests.swift` and one new focused
  `AirwaveTests/HRIRImportTests.swift` if separating filesystem tests improves
  clarity.

**Out of scope**:

- Changing `LSUIElement` to false, showing a Dock icon, quitting when menu
  visibility is disabled, or pausing audio processing.
- Changing Launch at Login behavior except ensuring it does not open Settings
  during a background login launch.
- File bookmarks or using HRIR files in place from external folders. All files
  remain copied into managed Application Support.
- New HRIR formats, DSP/channel-map semantics, output selection, runtime sample
  rate policy, directory relocation, or deletion of existing presets.
- Automatic overwrite, silent duplicate renaming, file moves, or recursively
  importing directories.
- UI redesign beyond adding matching Application rows and drop states to the
  components produced by Plan 008.

## Git workflow

- Branch: `codex/009-import-hidden-lifecycle`
- Prefer two logical commits, for example `feat(app): add hidden menu lifecycle`
  and `feat(hrir): import dropped presets safely`.
- Do not stage, commit, push, or open a PR unless instructed by the operator.

## Steps

### Step 1: Introduce a testable menu-bar visibility preference

Add one `@MainActor` observable manager with an injected `UserDefaults` store.
Use a namespaced key such as `Airwave.Application.ShowInMenuBar`. Its behavior:

- Missing key means `true`; do not add it to legacy-reset keys.
- Updating the published value persists immediately.
- `AirwaveApp` binds `MenuBarExtra(isInserted:)` directly to the manager so the
  status item appears/disappears live. Do not conditionally construct a second
  menu scene or terminate/relaunch the app.
- Disabling visibility has no calls into `AudioRuntimeController`,
  `HRIRManager`, Launch at Login, or onboarding persistence.

Inject the manager into views through environment or the same singleton pattern
used by `LaunchAtLoginManager`; keep one production instance.

**Verify**: add isolated-suite tests proving default true, false/true round-trip
across manager instances, and no interaction with login/audio fakes. Run the
ProductSurfaceTests command.

### Step 2: Establish a reliable Settings presentation path for an LSUIElement app

Centralize Settings opening so menu actions and AppKit delegate callbacks use
the same presenter. The presentation path must both create the SwiftUI Settings
surface when absent and front its registered window when present. Prefer a
native SwiftUI `Settings` scene plus the platform Settings command/action if it
works on the macOS 15 deployment target; otherwise use one AppKit coordinator
with a single `NSHostingController`, not parallel SwiftUI/AppKit Settings
windows. Never leave two Settings windows or two independently constructed
`MenuBarViewModel` instances.

Wire AppKit lifecycle callbacks as follows:

- `applicationShouldHandleReopen(_:hasVisibleWindows:)`: if the menu item is
  hidden, open/front Settings and return true. If visible, preserve normal
  menu-bar behavior and do not force Settings over another visible Airwave
  window.
- Handle an interactive cold launch with no visible window by opening Settings
  when the menu preference is hidden. Use the AppKit open-untitled/reopen event
  path rather than unconditionally opening from `applicationDidFinishLaunching`.
- Launch-at-login/background launches must remain silent even when the menu item
  is hidden. Do not infer interactivity only from “no visible windows”; verify
  the chosen AppKit callback is not issued for the login-item path.
- Keep onboarding automatic presentation behavior unchanged when the menu item
  is visible. If onboarding is unfinished while hidden, an explicit external
  reopen still opens Settings as requested; “Set Up Airwave Again” can resume
  onboarding from there.

Refactor menu Settings action to call the centralized presenter after closing
the popover. Preserve the current activation/fronting workarounds and window
identifiers where they remain necessary.

**Verify**: unit-test a pure presentation decision function for hidden/visible,
running reopen, interactive cold launch, login launch, and already-visible
Settings. Then perform the manual lifecycle matrix in the Test plan. If macOS
does not provide a reliable distinction between interactive cold launch and
SMAppService login launch, stop and report; do not make every login open
Settings.

### Step 3: Add the preference controls to Settings and onboarding

Add “Show in Menu Bar” immediately below “Launch at Login” in the Application
card in both Settings and the final onboarding page. Use the same icon, title,
subtitle, divider, padding, and switch styling on both surfaces. Recommended
subtitle: “Keep Airwave available from the macOS menu bar.” Toggling off should
remove the status item immediately while leaving the current window open, so it
can be toggled back before closing.

Do not gate onboarding completion on this preference and do not add it to other
onboarding pages.

**Verify**: source/test assertions find exactly two production labels, both
bound to the shared manager, and `OnboardingViewModel.canComplete` is unchanged.
Run Debug build and ProductSurfaceTests.

### Step 4: Add a deterministic, injectable HRIR import API

Refactor `HRIRManager` construction just enough to inject a managed presets
directory and `FileManager` for tests while keeping `shared` behavior and the
existing on-disk directory unchanged. Add structured import types:

- A collision policy with at least `reject` and `replace`.
- A preflight result listing acceptable WAV URLs, same-name conflicts, and
  immediately rejected URLs/reasons.
- A final result preserving input order with imported presets, declined/skipped
  conflicts, and per-file failures suitable for concise UI copy.

For each external URL:

1. Use `startAccessingSecurityScopedResource()` when available and balance every
   successful call with `stopAccessingSecurityScopedResource()` via `defer`.
2. Reject directories, unreadable files, and extensions other than `.wav`
   case-insensitively.
3. Validate with the existing `WAVLoader.load` before changing managed files.
   Keep existing HRIR channel-count validation and error vocabulary.
4. Derive the destination only from `lastPathComponent`; verify the standardized
   destination remains directly inside the managed directory.
5. For new files, copy to a temporary sibling and atomically move it into place.
   For approved replacements, validate first and use an atomic replacement so a
   failed copy never destroys the existing preset.
6. Reconcile `presets` and `presets.json` on the main actor without waiting for
   FSEvents. Preserve the UUID for a same-name replacement, refresh channel/sample
   metadata, and make watcher reconciliation idempotent.
7. If the replaced preset was active, return enough information for the caller
   to reactivate it through `MenuBarViewModel`; do not directly invent a sample
   rate inside the importer.

Batch import is partial-success, not transactional across all files. Process in
the supplied drop order and return all results. Never modify source files.

**Verify**: new filesystem tests use a temporary injected managed directory and
real minimal WAV fixtures accepted by `WAVLoader`. Cover valid copy, uppercase
extension, invalid extension, malformed WAV, directory URL, traversal-resistant
basename handling, partial batch success, reject collision, approved atomic
replacement, replacement validation failure preserving old bytes/metadata,
stable UUID on replacement, and metadata persistence/reload.

### Step 5: Add shared drop handling and duplicate confirmation

Add a small `@MainActor` import coordinator shared by Settings and onboarding,
or a reusable view modifier backed by the manager API. Use SwiftUI’s macOS 15
typed URL drop support. It must:

- Accept multiple file URLs only on the Settings Spatial Profile card and the
  onboarding `.hrirPreset` page/card.
- Show a system-colored dashed/solid border and “Drop HRIR WAV files” affordance
  while targeted; use no custom accent.
- Preflight all files. If conflicts exist, present one confirmation dialog that
  names/counts conflicts and clearly states replacement. “Cancel” declines only
  the conflicting files while still importing non-conflicting valid files;
  “Replace” imports them with replacement policy.
- Show a concise inline result for validation/copy failures and partial success;
  never expose raw paths or internal runtime/output details. Make the result
  accessible and dismiss/replace it on the next drop.
- After completion, activate the first successfully imported preset in original
  drop order through `MenuBarViewModel.selectPreset`. If none imported, preserve
  the current selection. Replacing the active preset must reactivate its
  refreshed value.
- Keep the animated accordion and folder-management action usable during and
  after import. Disable only the drop/import action while one batch is actively
  processing; serialize or reject concurrent drops explicitly.

**Verify**: coordinator tests cover conflict cancel plus non-conflict success,
replace, first-success activation, all-failure preserving selection, partial
error presentation, and concurrent-drop handling. Run ProductSurfaceTests and
Debug build.

### Step 6: Run application and safety regression validation

Run full tests, Debug and Release builds, metadata validation, both safety
scripts, and `git diff --check`. Search the production diff to ensure no Dock
activation policy, device/output selector, engine toggle, route mutation, file
move from external source, or raw filesystem-path copy entered public UI.

**Verify**:

```sh
plutil -extract LSUIElement raw Airwave/Info.plist
```

Expected: `true`.

```sh
git diff --name-only -- Airwave AirwaveTests Airwave.xcodeproj | sort
```

Expected: only files explicitly allowed by this plan, plus the completed Plan
008 files already present before execution.

## Test plan

### Automated

- Menu visibility preference: default, persistence, live binding decision, and
  independence from audio/login state.
- Reopen decision model: visible status item, hidden status item, existing
  Settings window, interactive cold launch, running reopen, and login launch.
- Import manager: all validation, collision, atomicity, ordering, metadata, and
  source-preservation cases listed in Steps 4–5.
- UI coordinator: duplicate confirmation choices, partial success, first import
  selection through a fake `MenuBarViewModel` boundary, and concurrent drops.
- Existing onboarding completion, preset target sample rate, runtime, DSP, and
  audio-safety tests remain unchanged and green.

### Manual macOS 15 lifecycle matrix

Use a locally signed Debug app where Launch at Login behavior can be exercised:

1. Menu visible, app running: reopen from Applications; no duplicate app or
   Settings window appears unexpectedly.
2. Turn menu visibility off in Settings: status item disappears immediately;
   Settings stays open; audio continues processing.
3. Close Settings, keep app running, reopen through Finder/Spotlight: one
   Settings window appears and fronts on the active Space.
4. Quit while hidden, launch through Applications: Settings opens and no Dock
   icon/status item appears.
5. Enable Launch at Login while hidden, log out/in or use a controlled login-item
   validation: Airwave starts silently, does not open Settings, has no Dock/menu
   icon, and continues processing when otherwise ready.
6. Reopen that running hidden instance externally: Settings appears; toggling
   “Show in Menu Bar” restores the status item immediately.
7. With onboarding open on HRIR Preset, drop one valid WAV, multiple mixed
   valid/invalid files, and a duplicate. Repeat on Settings. Verify source files
   remain, confirmation behavior matches the decision, the first successful
   import is selected once, and other onboarding pages reject/no-op the drop.

Record the tested macOS build and results in the implementation PR description;
do not add a new tracked validation document unless requested.

## Done criteria

- [ ] “Show in Menu Bar” defaults on, persists, and appears in Settings and the
  final onboarding Application card.
- [ ] Turning it off removes only the status item; audio and open windows remain.
- [ ] `LSUIElement` remains true and no Dock icon is introduced.
- [ ] Interactive external launches/reopens of a hidden Airwave instance open
  exactly one Settings window; Launch at Login stays silent.
- [ ] Settings and only the onboarding HRIR page accept multi-file WAV drops.
- [ ] Imports validate before mutation, copy into the existing managed folder,
  ask before replacement, preserve sources, and report partial failures.
- [ ] The first successful import in input order activates through
  `MenuBarViewModel`; failed batches preserve current selection.
- [ ] Replacement failure preserves existing file bytes and metadata; successful
  replacement preserves preset identity and refreshes metadata.
- [ ] Debug/Release builds, full tests, metadata validation, safety scripts, and
  `git diff --check` pass.
- [ ] `plans/README.md` marks Plan 009 DONE.

## STOP conditions

Stop and report rather than improvising if:

- macOS 15 cannot reliably distinguish an interactive cold launch from an
  SMAppService login launch; do not make login launches open Settings.
- Creating Settings on demand requires showing a Dock icon, changing
  `LSUIElement`, or maintaining duplicate SwiftUI/AppKit Settings windows.
- The menu insertion binding recreates or terminates the audio runtime.
- Testable importing would require relocating/deleting the existing preset
  directory or changing HRIR/DSP formats.
- Atomic replacement is unavailable on the target filesystem; preserve the old
  file and report the limitation instead of falling back to delete-then-copy.
- Security-scoped URLs cannot be read through the typed SwiftUI drop API on the
  macOS 15 target.
- Existing uncommitted UI changes would be overwritten or a verification gate
  fails twice after a reasonable correction.

## Maintenance notes

The hidden state deliberately creates an app with no persistent visible UI.
Future Settings-scene or activation-policy changes must rerun the manual
lifecycle matrix, especially Launch at Login. Future HRIR formats should extend
the importer’s validation contract rather than bypass it in the view. Reviewers
should scrutinize atomic replacement, security-scope balancing, FSEvent/import
races, exact single-window behavior, and any accidental coupling between menu
visibility and audio readiness.
