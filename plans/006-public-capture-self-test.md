# Plan 006: Replace private TCC checks with a public capture self-test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update this plan and the status row in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 0639706..HEAD -- Airwave AirwaveTests scripts Airwave.xcodeproj/project.pbxproj dev_assets/7.1-fc-gentle.wav`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against live code before proceeding. A material
> mismatch is a STOP condition.

## Status

- **Execution**: IN PROGRESS — implementation and automated verification complete; physical release matrix pending.

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: 004, 005
- **Category**: tech-debt / correctness
- **Planned at**: commit `0639706`, 2026-07-17

## Why this matters

Airwave currently treats private TCC SPI as authoritative for System Audio
Capture permission. That SPI is loaded from a private framework and is not a
supported compatibility contract. Apple documents only the public operational
boundary: starting I/O on an aggregate device containing a Core Audio process
tap prompts for System Audio Recording access.

Replace the permission preflight with one behavioral result: Airwave can or
cannot capture non-silent system PCM now. Explicit setup makes this result
deterministic by playing a bundled WAV through an unmuted, capture-only probe
that includes Airwave's own process. The onboarding page presents one **System
Audio Capture** card, not separate permission and tap-health cards.

This does not create a public permission-status API. A successful self-test
proves current capture capability, not a permanent TCC grant. Ad-hoc signatures
also do not provide a stable identity across rebuilt releases, so permission
may need to be granted again after an update. Do not hide either limitation in
state names, UI copy, or release validation.

## Current state

- `Airwave/CoreAudioPlatformClient.swift:48-104` dynamically opens private
  `TCC.framework`, resolves `TCCAccessPreflight` and `TCCAccessRequest`, and uses
  `kTCCServiceAudioCapture`.
- `Airwave/CoreAudioPlatformClient.swift:590-598` exposes those private results
  through `systemAudioPermissionStatus()` and
  `requestSystemAudioPermission(_:)`.
- `Airwave/CoreAudioPlatformClient.swift:396-425` always builds the global tap
  with `excludingProcesses: [ownProcess]`. A WAV played by Airwave therefore
  cannot be observed by the current tap.
- `Airwave/CoreAudioPlatformClient.swift:755-788` reports `.tapReady` after the
  first successful `AudioUnitRender`, without inspecting captured sample
  values. This proves callback execution, not audible/non-zero capture.
- `Airwave/AudioRuntimeController.swift:266-345` asks private TCC first and only
  starts a public tap after a private `.granted` result.
- `Airwave/AudioRuntimeController.swift:523-526` uses an unmuted tap for the
  no-effect probe and `mutedWhenTapped` for processing.
- `Airwave/AudioRuntimeState.swift:6-18` publishes independent
  `PermissionStatus` and `TapHealth` state machines. `isSetupHealthy` requires
  both.
- `Airwave/OnboardingView.swift:138-163,289-313` renders separate **macOS
  Permission** and **Audio Tap Health** cards.
- `Airwave/AppDelegate.swift:323-326` calls private preflight every time the app
  becomes active.
- `dev_assets/7.1-fc-gentle.wav` is an untracked 1.5-second, 48 kHz, 8-channel,
  16-bit WAV. Its required SHA-256 is
  `5333a3c316b639cbca5af4dbb36d6a120c5cdff92b9e9a9a9acd3a1002fe9588`.
- `Airwave.xcodeproj/project.pbxproj:62-81` uses a file-system-synchronized
  `Airwave` root group. New production Swift and resource files under
  `Airwave/` should be discovered automatically; verify the built bundle rather
  than assuming resource membership.

Repository conventions to preserve:

- `AudioRuntimeController` remains the only owner and publisher of audio
  runtime policy (`Airwave/AudioRuntimeController.swift:69-87`).
- `AudioPipeline` owns strict tap -> private aggregate -> HAL I/O acquisition
  and reverse-order cleanup (`Airwave/AudioPipeline.swift:75-182`). Reuse this
  lifecycle; do not create a second copy of Core Audio cleanup code.
- Production processing excludes Airwave's own process and uses
  `.mutedWhenTapped` to avoid feedback. Verification is unmuted and must write
  silence to its aggregate output so captured audio is not duplicated.
- Core Audio render work must remain allocation-free, lock-free, and log-free.
  Match the callback boundaries enforced by
  `scripts/check-audio-safety-invariants.sh`.
- Runtime/controller behavior is tested with injected fakes in
  `AirwaveTests/AudioRuntimeControllerTests.swift`; pipeline lifecycle ordering
  is tested in `AirwaveTests/AudioPipelineTests.swift`.

## Public platform facts

- Apple documents `AudioHardwareCreateProcessTap` and aggregate-device capture
  as public API on macOS 14.2+.
- Apple states that the first recording start on an aggregate containing a tap
  causes the System Audio Recording prompt.
- `NSAudioCaptureUsageDescription` is the public usage-description key; Airwave
  already has it.
- No public Core Audio, AVFoundation, or Bundle Resources API in the macOS 26.5
  SDK exposes the TCC state for `AudioCapture`. `AVAudioApplication` recording
  permission is microphone/input permission and must not be substituted.
- `tccutil reset AudioCapture <bundle-id>` is the documented reset path for
  testing; it is not an in-app status API.

References:

- <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>
- <https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription>
- <https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos>
- <https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac>

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Asset identity | `shasum -a 256 dev_assets/7.1-fc-gentle.wav` | exact checksum from Current state |
| Safety invariants | `scripts/test-audio-safety-invariants.sh` | `audio safety invariant tests passed` |
| Version tests | `scripts/test-release-version.sh` | exit 0 |
| Metadata | `scripts/verify-2.0-metadata.sh` | exit 0 |
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0 |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | exit 0, no analyzer findings |

The three script gates were run at planning time and passed. Full `xcodebuild`
was not rerun during this read-only planning pass; prior Plan 005 verification
recorded 241 executed tests, 1 skipped, 0 failures.

## Scope

**In scope** (only these files may be modified or created):

- `Airwave/AudioPlatformClient.swift`
- `Airwave/CoreAudioPlatformClient.swift`
- `Airwave/AudioPipeline.swift`
- `Airwave/AudioCaptureProbe.swift` (new, if the implementation needs a
  dedicated coordinator/player/detector)
- `Airwave/Resources/AudioCaptureProbe.wav` (new bundled copy)
- `Airwave/AudioRuntimeController.swift`
- `Airwave/AudioRuntimeState.swift`
- `Airwave/ProductSetup.swift`
- `Airwave/OnboardingView.swift`
- `Airwave/AppDelegate.swift`
- `AirwaveTests/AudioPipelineTests.swift`
- `AirwaveTests/CoreAudioPlatformClientTests.swift`
- `AirwaveTests/AudioRuntimeControllerTests.swift`
- `AirwaveTests/AudioRuntimeStateTests.swift`
- `AirwaveTests/ProductSurfaceTests.swift`
- `scripts/check-audio-safety-invariants.sh`
- `scripts/test-audio-safety-invariants.sh`
- `README.md`
- `docs/release-validation.md`
- `Airwave.xcodeproj/project.pbxproj` only if explicit resource membership is
  required after the synchronized group fails to copy the WAV automatically
- `plans/006-public-capture-self-test.md` and `plans/README.md` for status only

**Read-only input**:

- `dev_assets/7.1-fc-gentle.wav`; copy its bytes, never move or rewrite it.

**Out of scope**:

- HRIR/EQ DSP, preset persistence, and device-profile behavior.
- Default-output or volume writes. Airwave must continue following macOS.
- Microphone APIs, `NSMicrophoneUsageDescription`, ScreenCaptureKit, and screen
  recording permission.
- Any TCC database read, private framework, private symbol, private entitlement,
  shell command, helper process, or Accessibility/Apple Events workaround.
- Persisting a boolean permission grant in `UserDefaults`. Such a value would
  become stale after revocation or a changed ad-hoc signature.
- Changing the app's direct/ad-hoc distribution policy. This plan documents its
  TCC identity limitation but does not require a paid account.

## Git workflow

- Branch: `codex/006-public-capture-self-test`
- Use focused commits matching repo style, for example:
  `fix(audio): verify public capture with known signal`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Lock the behavioral contract in tests

Update existing tests before production code:

1. Replace the two-state setup-health expectations with one capture-access
   state machine: `unverified`, `checking`, `verified`,
   `permissionRequired`, and `failed(reason:)` (equivalent names are acceptable
   only if they retain these meanings).
2. Assert that setup health requires `verified` capture and a supported current
   output; it must not require a separate tap-health property.
3. Assert that one explicit verification request creates at most one live probe,
   reaches `checking`, and only becomes `verified` after a non-silent-capture
   event.
4. Assert that a successful render containing only zero samples never verifies
   capture and eventually produces an actionable retry state.
5. Assert permission-specific HAL errors become `permissionRequired`; generic
   tap/aggregate/render failures become `failed(reason:)` and do not claim
   denial.
6. Assert stale callbacks, output changes, sleep, termination, and repeated
   clicks cannot publish success or leak a player/probe.
7. Assert explicit self-test uses an unmuted, all-process tap and silent output.
   Production still uses a tap excluding Airwave and `.mutedWhenTapped`, but
   only after same-session verification.
8. Replace the source-string test for two onboarding cards with an assertion
   that exactly one **System Audio Capture** card exists and **Audio Tap Health**,
   **macOS Permission**, and private TCC names do not appear in product UI.

**Verify**:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`
must fail only in the newly changed assertions before implementation.

### Step 2: Remove private permission APIs completely

1. Delete `SystemAudioPermissionSPI` and the now-unused `Darwin` import from
   `CoreAudioPlatformClient.swift`.
2. Remove `SystemAudioPermissionStatus`, `systemAudioPermissionStatus()`, and
   `requestSystemAudioPermission(_:)` from `AudioPlatformClient` and every fake.
3. Remove controller preflight/request branches. `requestSystemAudioAccess()`
   must now start the public explicit self-test directly.
4. Replace `refreshSystemAudioAccess()` and its activation call with behavioral
   invalidation only where needed. Opening the Audio Capture Settings pane must
   mark capture unverified; returning to Airwave then starts safe public
   verification, never private preflight.
5. Extend the safety checker to fail on production-source occurrences of:
   `TCC.framework`, `TCCAccessPreflight`, `TCCAccessRequest`,
   `kTCCServiceAudioCapture`, `dlopen`, or `dlsym`. Add a negative fixture test
   proving the new invariant catches private TCC loading.

Do not replace this with `AVAudioApplication.recordPermission`; Apple documents
that surface for microphone/input recording.

**Verify**:
`rg -n 'SystemAudioPermissionSPI|TCCAccess|kTCCServiceAudioCapture|TCC\.framework|dlopen|dlsym|systemAudioPermissionStatus|requestSystemAudioPermission' Airwave AirwaveTests`
returns no matches, and `scripts/test-audio-safety-invariants.sh` passes.

### Step 3: Make tap inclusion and output behavior explicit

Refactor existing pipeline lifecycle instead of duplicating it:

1. Change `GlobalStereoTapRequest` from one mandatory `excludedProcess` to an
   explicit exclusion collection or capture-scope enum.
   - Production: exclude Airwave's own `AudioProcessHandle`.
   - Explicit self-test: exclude no processes, so Airwave can capture its WAV.
   - Passive runtime verification: exclude Airwave to avoid treating unrelated
     app UI sounds as its own stimulus.
2. Add an explicit pipeline output mode.
   - Production mode invokes the existing DSP processor.
   - Verification mode leaves callback output zeroed and never calls DSP. The
     tap is `.unmuted`, so original system audio remains audible once, natively.
3. Replace first-render `.tapReady` semantics with actual sample inspection.
   Implement a small, pure `CaptureSignalPolicy` that consumes the two Float32
   input buffers and reports success only after sustained energy. Use a low but
   non-zero threshold plus a minimum frame count; do not accept a single sample
   spike. Keep constants centralized and unit-tested.
4. Do not perform exact waveform correlation. The source is 8-channel and is
   downmixed by the playback stack/output device, so exact PCM is not stable
   across devices. Known playback plus sustained non-zero capture is sufficient
   evidence that TCC and the tap path are working.
5. Keep all detector work allocation-free, lock-free, file-free, and log-free.
   Report at most one terminal event per I/O context.

Suggested target shape (names may follow nearby conventions):

```swift
nonisolated enum AudioPipelinePurpose: Equatable, Sendable {
    case verification(includeOwnProcess: Bool)
    case processing
}

nonisolated enum AudioCaptureVerificationEvent: Equatable, Sendable {
    case signalDetected
    case permissionDenied
    case renderFailed(OSStatus)
}
```

**Verify**: focused pipeline and platform tests pass; lifecycle order remains
tap -> format -> aggregate -> format -> I/O -> start, with reverse cleanup.

### Step 4: Bundle and play the deterministic stimulus

1. Verify the source checksum. Copy
   `dev_assets/7.1-fc-gentle.wav` byte-for-byte to
   `Airwave/Resources/AudioCaptureProbe.wav`.
2. Add a small injected `AudioProbeStimulusPlaying` boundary and a production
   AVFoundation implementation. Resolve the URL with `Bundle.main`; missing or
   unreadable resource is a generic self-test failure, never permission denial.
3. Play through the current default output. Do not change output device or
   volume. Let macOS/AVFoundation downmix the 7.1 source to the stereo output.
4. Start playback only after the unmuted capture pipeline has successfully
   started. Handle permission-prompt timing without private callbacks:
   - schedule one playback after public recording start;
   - if the app resigns and becomes active while the explicit test is pending,
     replay once after activation;
   - bound each post-playback detection window, but do not fail merely because
     the user left the system permission prompt open for longer than five
     seconds;
   - never loop indefinitely.
5. Stop player and probe on success, denial, failure, timeout, output change,
   sleep, setup dismissal, or app termination.
6. Verification callback output must remain silence. The unmuted original WAV
   is the only audible copy.

**Verify**:

- `cmp dev_assets/7.1-fc-gentle.wav Airwave/Resources/AudioCaptureProbe.wav`
  exits 0.
- After Debug build,
  `find ~/Library/Developer/Xcode/DerivedData/Airwave-*/Build/Products/Debug/Airwave.app/Contents/Resources -name AudioCaptureProbe.wav -print`
  prints exactly one bundled file.
- Unit tests with fake player prove start/replay/stop counts and stale-event
  rejection without producing real sound.

### Step 5: Make runtime startup fail-safe without private preflight

Private preflight currently prevents a denied app from immediately creating a
`mutedWhenTapped` production tap. Preserve that safety property behaviorally:

1. Never start a muted production pipeline while capture is `unverified`,
   `checking`, `permissionRequired`, or `failed`.
2. With an effect selected and no same-session verification, start an unmuted,
   silent-output passive verification pipeline excluding Airwave. Do not play
   the bundled WAV automatically during normal background launch.
3. When real system audio produces sustained non-zero PCM, stop the verifier,
   then build the normal own-process-excluding `.mutedWhenTapped` processing
   pipeline. The first short audio segment remains native; it must never be
   duplicated or silenced.
4. When setup explicitly requests verification, use the all-process probe plus
   WAV from Step 4. After success, stop it and either publish `.inactive` (no
   selected effect) or start production processing.
5. Invalidate same-session verification on output change, wake, and return from
   the Audio Capture Settings pane. Keep generic runtime failures separate from
   permission-required failures.
6. If Core Audio returns a known permission OSStatus during create/start/render,
   publish `permissionRequired`. Otherwise publish `failed(reason:)`; do not
   infer denial from silence alone.
7. Keep retry generation-bound and terminal for explicit setup. Background
   passive verification may wait for audio, but must keep native audio audible
   and own no muted tap while waiting.

**Verify**: controller tests prove no `.mutedWhenTapped` start precedes a
same-session `signalDetected`, and every cancellation path leaves zero live
probe/player resources.

### Step 6: Coalesce product state and onboarding UI

1. Replace `PermissionStatus` plus `TapHealth` with one capture-access state.
   Use `verified`, not `granted`, in internal naming where possible; evidence is
   successful capture, not a public TCC query.
2. Make `isSetupHealthy` require verified capture plus supported current output.
   Keep first-run completion gated by that live result. After setup has already
   been completed, a fresh process's neutral `unverified` state alone must not
   raise setup attention when no effect is selected; only an active verification
   failure, `permissionRequired`, or a selected effect waiting for verification
   should do so.
3. Replace both onboarding cards with one **System Audio Capture** card:
   - unverified: explain that Airwave plays a short sound and listens for it;
   - checking: show progress and say a short test sound may play;
   - verified: state that Airwave successfully captured system audio;
   - permission required: provide **Open System Settings** and **Test Again**;
   - generic failed: show exact safe reason and **Retry Test**.
4. Button label should be **Test System Audio Capture**, not "check permission".
   Do not claim macOS permission is granted unless the copy explicitly says it
   was inferred from a successful capture test.
5. Update progress indicator, completion gating, setup-attention logic, focus
   restoration, settings setup summary, and source-string tests to use the one
   state machine.
6. Keep processing health in the existing runtime `Status` surface. Do not
   recreate a second tap-health card elsewhere.

**Verify**:
`rg -n 'Audio Tap Health|macOS Permission|tapHealth|TapHealth' Airwave AirwaveTests`
returns no matches, and product-surface tests pass.

### Step 7: Update docs and complete automated verification

1. Update README setup copy: Airwave requests System Audio Capture by starting
   its public process tap and verifies access with a short bundled sound.
2. Update release validation with the manual matrix below and the ad-hoc signing
   identity limitation.
3. Run every command in **Commands you will need**.
4. Update plan status only after automated gates and manual checks pass.

**Verify**: all commands exit 0 and `git diff --name-only` contains only files
listed in Scope.

## Test plan

Add or update tests in existing test targets:

- `CoreAudioPlatformClientTests.swift`
  - all-process request produces `excludingProcesses: []`;
  - production request excludes own process;
  - known permission OSStatus mapping remains distinct from generic failures;
  - zero buffers do not trigger signal detection;
  - sustained low-level stereo signal does trigger once;
  - one-sample spike and NaN/Infinity never verify.
- `AudioPipelineTests.swift`
  - explicit verifier is unmuted and silent-output;
  - verifier does not run DSP;
  - production remains own-process-excluding and muted;
  - all acquisition-failure cleanup and idempotent stop tests still pass.
- `AudioRuntimeControllerTests.swift`
  - explicit test success, denial, generic failure, timeout, repeated click;
  - prompt-return replay path;
  - passive launch waits in native audio, then promotes to muted processing;
  - no automatic WAV during background launch;
  - output/sleep/termination cancellation and stale callback rejection;
  - returning from opened System Settings invalidates and safely reverifies;
  - no muted pipeline starts from persisted state or silence alone.
- `AudioRuntimeStateTests.swift`
  - one capture-access state and setup-health truth table.
- `ProductSurfaceTests.swift`
  - one card, truthful copy/actions, progress and focus behavior;
  - no old permission/tap-health terminology.
- Shell invariant tests:
  - private TCC symbol fixture fails;
  - shipping source without private symbols passes.

## Manual release matrix

Run on at least macOS 15 and the current macOS release with the exact ad-hoc
archive shape used for distribution:

1. `tccutil reset AudioCapture com.southneuhof.Airwave`, launch, click test,
   allow, confirm one audible WAV and verified state.
2. Reset, launch, click test, deny, confirm native WAV remains audible,
   permission-required UI appears, and no muted tap remains.
3. Denied -> open System Settings -> enable -> return -> test succeeds without
   restarting Airwave.
4. Granted but otherwise silent Mac -> explicit test succeeds; passive launch
   does not stall onboarding when explicit test was requested.
5. Normal launch with selected effect and real audio -> first brief segment is
   native, then processing starts; no duplication and no silence.
6. Output at 44.1, 48, 88.2, and 96 kHz where hardware supports it.
7. Built-in, USB, HDMI, and Bluetooth outputs supported by release claims.
8. Change output, sleep/wake, revoke while running, close setup mid-test, quit
   mid-test: resources clean up and native audio remains available.
9. Install the exact same archive twice: permission remains associated with the
   unchanged binary.
10. Install a rebuilt/update archive: record whether macOS requests permission
    again. Treat a new prompt as expected ad-hoc identity behavior, not a probe
    regression; document it in release notes.

## Done criteria

- [x] No private TCC framework, symbols, service strings, or dynamic loading in
  production source.
- [x] One capture-access state replaces permission plus tap-health state.
- [x] Onboarding renders one **System Audio Capture** card.
- [x] A completed setup with no selected effect does not show false attention
  merely because a new process has not run a capture test yet.
- [x] Bundled WAV matches supplied SHA-256 and exists once in built app.
- [x] Explicit probe is unmuted, includes Airwave, writes silence, plays one
  audible original, and verifies sustained non-zero captured PCM.
- [x] Passive background verification never plays bundled WAV.
- [x] No muted production tap starts before same-session capture verification.
- [x] Silence alone never becomes verified or permission denied.
- [x] Permission OSStatus, generic failure, timeout, and cleanup each have tested
  truthful states.
- [x] Every automated verification command passes.
- [x] Manual allow/deny/re-enable/silence/revocation/output/sleep/update matrix is
  recorded in `docs/release-validation.md`.
- [x] No files outside Scope are modified.
- [x] Plan and index status updated.

## STOP conditions

Stop and report instead of improvising if:

- Supplied WAV is absent or its SHA-256 differs.
- A public API that directly and specifically reports `AudioCapture` TCC status
  is found in the deployment-target SDK. Provide its public declaration and
  Apple documentation before changing this design.
- The public Core Audio start does not trigger the System Audio Recording prompt
  on a clean macOS 15 or current-macOS test account.
- An all-process unmuted tap cannot observe Airwave's AVFoundation playback on a
  supported physical stereo output.
- Verification-mode zero output attenuates, mutes, or duplicates native audio.
- AVFoundation cannot downmix the supplied 8-channel WAV to a supported stereo
  default output. Report the failing device/format; do not silently replace the
  user-provided asset.
- Safe promotion from unmuted verification to muted production requires a
  default-output or volume write.
- A step requires a private entitlement, TCC database access, helper app, or
  different distribution policy.
- A verification command fails twice after one focused correction.

## Maintenance notes

- Apple may add a public `AudioCapture` authorization API later. Re-check SDK
  headers and Apple docs at each minimum-macOS bump; replace behavioral
  inference only when a specific public API exists.
- Keep explicit self-test and passive runtime verification distinct. Explicit
  setup may play the WAV; background runtime must not.
- Threshold changes require hardware validation. Too high creates false failure
  on quiet/downmixed devices; zero or single-spike acceptance creates false
  success.
- Review every future path to `.mutedWhenTapped`: it must remain gated by
  current-session capture evidence.
- Ad-hoc rebuilds change code identity. Stable cross-version TCC persistence
  requires a stable signing identity; self-test improves recovery and truthfulness
  but cannot change macOS identity rules.
