# Plan 014: Make setup sticky and permission recovery truthful

> **Executor instructions**: Fix only setup/permission semantics and output-change
> recovery described here. Preserve unrelated user work. Run every gate. If a
> STOP condition occurs, report evidence instead of adding another permission
> heuristic or rewriting the audio stack.
>
> **Drift check (run first)**:
> `git diff --stat da92511..HEAD -- Airwave/ProductSetup.swift Airwave/OnboardingView.swift Airwave/AppDelegate.swift Airwave/AudioRuntimeState.swift Airwave/AudioRuntimeController.swift Airwave/CoreAudioPlatformClient.swift Airwave/Airwave.entitlements Airwave/AirwaveRelease.entitlements AirwaveTests/ProductSurfaceTests.swift AirwaveTests/AudioRuntimeStateTests.swift AirwaveTests/AudioRuntimeControllerTests.swift AirwaveTests/CoreAudioPlatformClientTests.swift`
>
> Also run `git diff --stat` because this plan was written against commit
> `da92511` plus an uncommitted failed attempt. Do not discard that diff wholesale.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/004-always-on-recovery.md`, `plans/005-rebuild-product-surfaces.md`
- **Category**: bug
- **Planned at**: commit `da92511`, 2026-07-16

## Why this matters

Completed onboarding is durable product state, not a live audio-health probe.
Connecting an output may restart audio, but must never reopen or warn about setup.
Likewise, generic Core Audio recovery is not a permission request. Current code
can label any `.starting`/`.recovering` state as “Waiting for macOS…” forever and
maps one broad HAL error to permission denial before recording starts.

## Root cause and current state

- `Airwave/ProductSetup.swift:260-267` correctly persists completion, but
  `needsSetupAttention` ignores it and aliases transient `canComplete` health.
- `Airwave/ProductSetup.swift:280-297` still falls back from permission state to
  generic runtime states. After a click, any recovery loop becomes “requesting.”
- `Airwave/AudioRuntimeController.swift:227-255` lets general `retryNow()` mutate
  permission state and re-probes whenever Settings opens. Opening UI can restart
  audio and manufacture a permission workflow.
- `Airwave/AudioRuntimeController.swift:281-289` rebuilds for every default-output
  callback, even when descriptor is unchanged. A spurious callback during device
  attachment tears down a healthy pipeline.
- `Airwave/CoreAudioPlatformClient.swift:283-287` treats
  `kAudioHardwareIllegalOperationError` from tap creation as TCC denial. Apple
  documents the prompt at the point recording starts from the tap aggregate, not
  at tap-object creation. Classify permission only at the I/O start boundary.
- Current uncommitted I/O-proc rewrite follows Apple's sample by using
  `AudioDeviceCreateIOProcIDWithBlock` / `AudioDeviceStart` and the audio-input
  sandbox entitlement. Keep it only if signed validation below proves callback,
  playback, cleanup, and hot-plug behavior. Do not treat source-string tests as
  proof.
- Current selected suite passes 82 tests with 1 skipped. Skipped test is the only
  signed tap integration test; no automated test reproduces this bug.

Relevant product invariant from `plans/README.md`: output changes follow macOS
automatically with native audio during recovery; onboarding remains completed.

Apple reference: `https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/AudioRuntimeControllerTests -only-testing:AirwaveTests/AudioRuntimeStateTests -only-testing:AirwaveTests/CoreAudioPlatformClientTests -only-testing:AirwaveTests/ProductSurfaceTests test` | selected tests pass; signed harness may skip |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED` |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | `ANALYZE SUCCEEDED` |
| Safety | `scripts/test-audio-safety-invariants.sh && scripts/test-release-version.sh && scripts/verify-2.0-metadata.sh` | all pass |
| Diff | `git diff --check` | no output |

## Scope

**In scope**:

- `Airwave/ProductSetup.swift`
- `Airwave/OnboardingView.swift` only if copy/button state needs adjustment
- `Airwave/AppDelegate.swift`
- `Airwave/AudioRuntimeState.swift`
- `Airwave/AudioRuntimeController.swift`
- `Airwave/CoreAudioPlatformClient.swift`
- `Airwave/Airwave.entitlements`
- `Airwave/AirwaveRelease.entitlements`
- Four corresponding test files named in drift check
- `docs/release-validation.md`
- Narrow cleanup of accidental Debug-default changes in project/scheme files

**Out of scope**:

- New permission framework, persisted TCC grant, or repeated background probes
- Route/volume writes, device picker, onboarding redesign, DSP/EQ/HRIR changes
- General Core Audio refactor beyond validating current I/O-proc attempt
- Resetting TCC without operator approval

## Git workflow

- Branch: `codex/014-sticky-setup-permission-recovery`
- Suggested commit: `fix(audio): keep setup sticky across devices`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Lock regressions with state-machine tests

Add failing tests before production edits:

1. Completed persistence plus `.starting`, `.recovering`, unsupported output, or
   missing current output never sets `needsSetupAttention` and never restores the
   “Complete Set Up…” menu condition. Incomplete persistence still does.
2. Voluntary “Set Up Airwave Again” for completed onboarding starts at `.welcome`;
   runtime faults remain runtime-health UI, not setup steps.
3. `requestSystemAudioAccess()` is the only action entering `.requesting`.
   General `retryNow()`, Settings presentation, output change, and effect recovery
   never enter it.
4. Explicit request transitions terminate as `.granted`, `.denied`, or `.unknown`
   after generic failure. No test may leave `.requesting` after a synchronous
   pipeline attempt or its first failure.
5. Emitting the same output descriptor while processing creates/stops nothing;
   A→B still stops A before starting B and preserves granted permission.
6. Tap-creation illegal-operation is a tap failure, while I/O-start
   illegal-operation is `AudioRuntimeError.permissionDenied`.

**Verify**: focused test command fails on these new assertions before Step 2.

### Step 2: Separate durable setup from runtime health

In `OnboardingViewModel`:

- Keep `canComplete` as first-run completion gate.
- Define setup attention from persisted completion only:
  `needsSetupAttention = !persistence.isComplete`.
- Return `.welcome` for voluntary entry when persistence is complete. Do not
  route a completed user back to System Audio or Finish because audio is starting,
  recovering, or following another device.
- Make `permissionPresentation` a direct mapping of
  `runtime.permissionStatus`; remove inference from `runtime.status` and remove
  `didRequestPermission`/`observedPermissionRequest` if no longer needed.
- Resolve permission-window focus by observing permission-state exit from
  `.requesting`, including `.unknown` after a generic failure. Never wait for a
  generic runtime status to look like permission completion.

Settings may still show runtime warnings through `RuntimeMenuPresentation`.
Setup card/menu warning must not.

**Verify**: `ProductSurfaceTests` pass, including every matrix case from Step 1.

### Step 3: Make permission transitions explicit and terminal

In `AudioRuntimeController`:

- Remove permission mutation from `retryNow()`.
- Set `.requesting` only inside `requestSystemAudioAccess()` immediately before
  its one explicit probe.
- Publish `.granted` only after pipeline/probe start succeeds and `.denied` only
  for `AudioRuntimeError.permissionDenied`.
- On any other failure during an explicit request, exit `.requesting` to
  `.unknown` before normal recovery policy. Preserve `.granted` across ordinary
  device/effect recovery.
- Remove `revalidateSystemAudioAccess()` and its call from
  `SettingsWindowPresenter.present`. Startup processing/probe already establishes
  current access; merely opening Settings must have no audio side effect.
- Add one DEBUG log in failure handling containing operation-bearing
  `AudioRuntimeError`, current output UID/name, and whether request was explicit.
  Do not log audio data or external file paths.

**Verify**: controller tests prove general retry and Settings open cannot create
`.requesting`, and every explicit request has a terminal UI state.

### Step 4: Coalesce unchanged output callbacks and narrow TCC classification

In `defaultOutputChanged`, ignore a non-nil descriptor equal to
`state.currentOutput` only while a pipeline is live and status is processing.
Do not suppress callbacks during recovery or when descriptor ID/UID/format truly
changes.

In `CoreAudioPlatformClient`:

- Stop mapping `kAudioHardwareIllegalOperationError` from
  `AudioHardwareCreateProcessTap` to permission denial; preserve operation and
  numeric OSStatus as `tapCreationFailed`.
- Map that status to `permissionDenied` at actual aggregate I/O start only.
- Preserve operation/code in all create/start/stop/destroy errors.
- Keep current Apple-sample-style I/O-proc implementation and
  `com.apple.security.device.audio-input` entitlement only through Step 5. Remove
  brittle tests whose sole assertion is source text; callback bridge tests and
  signed behavior are required evidence.

Restore accidental attempt-only project noise manually: project default
configuration and scheme LaunchAction remain Release, and PBX entry ordering is
not changed merely by this fix. Do not blanket-checkout project files.

**Verify**: focused tests pass; `git diff --check` is empty.

### Step 5: Run signed physical acceptance before keeping backend changes

Run from Xcode as a signed Debug app with stable bundle ID and entitlements.
Record results in `docs/release-validation.md`:

1. Fresh authorized state: active HRIR produces processed audio; callback fires.
2. Connect second output without selecting it: pipeline remains active, no setup
   warning/menu item, no permission UI.
3. Change macOS default A→B: A stops before B starts, native audio remains usable,
   processing resumes, no permission prompt.
4. Quit and relaunch: onboarding stays complete and no permission prompt appears.
5. Explicitly revoked/denied access: only this case shows permission guidance;
   Allow/Retry never remains “Waiting for macOS…” after an error.
6. Normal quit releases I/O proc, aggregate, and tap; default output and volume
   are unchanged throughout.

If current I/O-proc backend fails callback/playback/cleanup while HEAD AUHAL passes
the same matrix, restore only the I/O-proc and entitlement portions of the failed
attempt and keep Steps 1-4's state/output fixes. Do not ship an unvalidated backend
rewrite to solve presentation state.

**Verify**: all six rows recorded PASS with output identity/volume and shortest
decisive DEBUG error line where relevant.

### Step 6: Run full gates

Run full tests, build, analyze, safety scripts, and diff check. Confirm only
in-scope files changed. Update this plan row in `plans/README.md`.

## Done criteria

- [ ] Completed onboarding remains complete across connect, switch, quit, relaunch.
- [ ] Setup warning depends only on incomplete onboarding.
- [ ] `.requesting` begins only from explicit permission action and always exits.
- [ ] Generic HAL/device recovery never renders as permission request.
- [ ] Same-output callbacks do not rebuild; real A→B still recovers safely.
- [ ] Permission denial is classified at recording start, with actionable logs.
- [ ] Signed physical matrix passes; all automated gates pass.

## STOP conditions

- Signed run cannot distinguish tap creation failure from I/O-start failure even
  with operation/code logs.
- TCC behavior differs between Debug and release signing identities.
- I/O-proc callback layout is not noninterleaved stereo or processed output does
  not reach selected physical device.
- Fix requires persisting a guessed permission grant or changing default output/
  volume.
- Three distinct backend fixes have already failed; stop and review architecture.

## Maintenance notes

Onboarding completion and runtime health are separate domains. Future device,
sleep, EQ, or HRIR recovery must update runtime health only. Future permission
changes must preserve one invariant: only explicit user action displays
“requesting,” and every request has a terminal result.
