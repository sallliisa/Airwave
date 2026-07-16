# Plan 002: Validate native-rate processing on signed physical outputs

> **Executor instructions**: Execute only after Plan 001 is implemented and automated gates pass. This plan records hardware evidence; it does not authorize source fixes. If a failure occurs, preserve shortest decisive format/error evidence, mark BLOCKED, and stop.
>
> **Drift check (run first)**: `git diff --stat bb9a8bf..HEAD -- Airwave/AudioPlatformClient.swift Airwave/AudioPipeline.swift Airwave/CoreAudioPlatformClient.swift AirwaveTests/CoreAudioPlatformClientTests.swift docs/release-validation.md`
> Confirm Plan 001 behavior exists before testing.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/001-bind-tap-to-output-rate.md`
- **Category**: tests / docs
- **Planned at**: commit `bb9a8bf`, 2026-07-16

## Why this matters

Unsigned CI cannot exercise System Audio Capture, physical clocks, Bluetooth, or signed TCC behavior. Known 44.1 kHz Bluetooth probe previously stopped at `formatMismatch` before callback/playback. Support claim requires signed proof that EQ-only, HRIR-only, and combined processing produce audio at device-native rates while preserving output identity, volume, cleanup, and native resumption.

## Current state

- `AirwaveTests/CoreAudioPlatformClientTests.swift` contains opt-in `testSignedManualPipelinePreservesDefaultOutput`, gated by `AIRWAVE_RUN_SIGNED_TAP_TESTS=1`.
- `docs/release-validation.md:70-87` records exact known blocker: 48 kHz interleaved tap against 44.1 kHz Bluetooth output.
- Physical matrix and performance sections remain `NOT TESTED`; documentation forbids support claims without recorded evidence.
- Plan 001 should make tap rate equal selected output rate and retain native-rate HRIR/EQ preparation.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Automated baseline | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | `** TEST SUCCEEDED **` |
| Safety | `scripts/test-audio-safety-invariants.sh` | `audio safety invariant tests passed` |
| Signed harness | `AIRWAVE_RUN_SIGNED_TAP_TESTS=1 xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' test -only-testing:AirwaveTests/CoreAudioPlatformClientTests/testSignedManualPipelinePreservesDefaultOutput` | `** TEST SUCCEEDED **` with locally valid signing/TCC |

If command-line signing cannot access granted TCC identity, run same test/product through Xcode “Sign to Run Locally” and record that exact method. Never disable TCC or change route/volume programmatically.

## Scope

**In scope**:

- `docs/release-validation.md`
- `plans/README.md` status only

**Out of scope**:

- Production/test source changes.
- Claiming virtual, aggregate, multichannel, or untested transport support.
- Changing device sample rate, default output, or volume to manufacture a pass.
- Adding SRC after a failure; failure returns to advisor as new evidence.

## Git workflow

- Branch: `codex/002-native-rate-validation`
- Commit evidence separately, e.g. `docs(audio): record native-rate validation`.
- Do not push or open PR unless instructed.

## Steps

### Step 1: Establish automated baseline

Run full unsigned tests and safety invariant script on Plan 001 implementation. Record Xcode/macOS version and tested commit in release validation.

**Verify**: both baseline commands pass.

### Step 2: Re-run known 44.1 kHz Bluetooth blocker

With physical Bluetooth output already selected by macOS and reporting 44.1 kHz, run signed harness. Record before/during/after output UID, nominal rate, and user-visible volume; tap format; aggregate rate; pipeline start/result; native audio resumption. Do not change output or volume from Airwave.

Then test EQ-only, HRIR-only, and HRIR+EQ with audible source. Each must produce non-silent processed audio and return cleanly to native output when effects become None or app quits.

**Verify**: no `formatMismatch`; signed harness passes; all three processing modes produce audio; same output UID and volume remain before/after.

### Step 3: Exercise at least one second native rate

Use built-in/wired/USB physical stereo output at 48 kHz, or another available native rate such as 96 kHz. Repeat signed harness and three processing modes. For 96 kHz, use EQ filters below Nyquist and confirm HRIR activation finishes before judging audio.

**Verify**: selected rate equals reported tap/aggregate/callback processing rate; audio works; output UID/volume unchanged; native resumption succeeds.

### Step 4: Validate transitions and bounded recovery

While processing at 44.1 kHz, switch default output in macOS to validated second-rate physical output, then back. Exercise EQ-only and HRIR+EQ. Confirm old private chain stops before new chain starts, current preset is prepared for new rate, no retry storm occurs, and only final output remains active. Disconnect/reconnect Bluetooth once.

**Verify**: both directions recover to processed audio; None/quit restores native audio; no stale chain or persistent silence.

### Step 5: Record evidence without overclaiming

Update blocker section and relevant physical/performance rows in `docs/release-validation.md` with date, commit, signing method, device class/name, exact native rate, result, and concise observations. Mark only performed rows PASS. Retain NOT TESTED for unavailable rates/transports. State native-rate architecture; do not say “all devices” based on two samples. Supported contract is physical stereo outputs whose device-bound tap matches selected stream.

**Verify**: `git diff --check` exits 0; documentation contains tested commit/rates and no unsupported universal claim; `git status --short` lists only documentation and plan index status.

## Test plan

- Required: 44.1 kHz Bluetooth, matching exact known failure.
- Required: one second physical stereo rate, preferably 48 kHz built-in plus 96 kHz if hardware exists.
- Per rate: signed harness; EQ-only; HRIR-only; HRIR+EQ; None; quit.
- Transition: 44.1→second rate→44.1; Bluetooth disconnect/reconnect.
- Measurements: output UID, nominal rate, tap format, aggregate rate, volume before/after, native resumption, silence/dropout, CPU/latency observation.

## Done criteria

- [ ] Automated baseline and safety gates pass on Plan 001.
- [ ] Known 44.1 kHz Bluetooth `formatMismatch` no longer occurs.
- [ ] EQ-only, HRIR-only, and combined processing produce audio at 44.1 kHz.
- [ ] Same modes pass at least one second native rate.
- [ ] Cross-rate output transitions rebuild and recover without stale pipeline.
- [ ] Output UID and volume remain unchanged except user-initiated macOS route selection.
- [ ] Native audio resumes after None and quit.
- [ ] Release validation records exact evidence and preserves NOT TESTED rows.
- [ ] `plans/README.md` row updated.

## STOP conditions

Stop and mark BLOCKED if:

- Device-bound tap rate differs from selected output stream rate.
- Signed harness starts but callback is silent, under-runs continuously, or returns Core Audio render errors.
- Airwave changes default output, device rate, or volume.
- Native audio fails to resume after stop, quit, disconnect, or failed start.
- Only way to continue appears to require realtime SRC, ring buffers, or source edits.
- Verification fails twice after confirming signing/TCC setup.

## Maintenance notes

Hardware evidence is rate- and transport-specific. Future macOS releases, new output transports, multistream devices, or changes to tap initializer require re-running matrix. Reviewers should reject conversion claims based only on mocked formats; signed callback audio is acceptance boundary.

