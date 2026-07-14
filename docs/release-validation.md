# Airwave 2.0 release validation

Release candidate: Airwave 2.0.0. Minimum OS: macOS 15. Validation date: 2026-07-15. This document distinguishes automated evidence, host observations, and tests still required before release.

## Safety invariants

- Airwave must never change the macOS default output device or any device volume.
- Native output and native volume remain authoritative.
- Failure, sleep, quit, crash, or force termination must leave native audio usable.
- Public virtual and aggregate outputs are unsupported and must produce guidance, never automatic route mutation.
- A release is blocked if macOS 14 is offered Airwave 2.0 through Sparkle or Homebrew.

## Automated gates

Run from repository root:

```bash
scripts/test-audio-safety-invariants.sh
scripts/test-release-version.sh
scripts/verify-2.0-metadata.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze
```

CI runs no TCC or hardware-dependent capture test. Lifecycle tests use injected platform and scheduler fakes. Release workflow verifies the archived bundle requires macOS 15 and refuses an appcast without `sparkle:minimumSystemVersion` 15.0.

## Physical matrix

`PASS` requires output identity and volume measured before/after, native audio resumption, and no audible dropout beyond the transition under test. `NOT TESTED` means no support claim may be made for that class.

| Scenario | Result | Required evidence / observation |
|---|---|---|
| Built-in speakers | NOT TESTED | Active preset, granted capture, before/after device ID and volume, native resume |
| Wired headphones | NOT TESTED | Connect/disconnect, output follow, native resume |
| USB DAC | NOT TESTED | Device ID/volume, disconnect/reconnect with new object ID |
| Bluetooth / AirPods | NOT TESTED | Connect, route transition, latency/CPU observation, native resume |
| HDMI | NOT TESTED | Stereo capability and disconnect behavior |
| AirPlay | NOT TESTED | Capability result, latency/CPU observation, native resume |
| Virtual output | OBSERVED, PARTIAL | Host default was BlackHole 2ch; automated policy blocks processing. Active-preset behavior not physically exercised |
| Public aggregate output | NOT TESTED | Must remain native passthrough with macOS-change guidance |
| A→B output switch | NOT TESTED | Old private chain fully released before B processing |
| Rapid A→B→C | NOT TESTED | Only C remains live; native audio resumes between failures |
| Output disconnect/reconnect | NOT TESTED | No tap read while unavailable; bounded recovery |
| Permission allowed / denied / revoked | NOT TESTED | One explicit retry probe, no retry storm |
| Sleep / wake | NOT TESTED | Zero private resources during sleep, one chain after wake |
| Normal quit | NOT TESTED | Device ID and volume unchanged; native audio resumes |
| Crash | NOT TESTED | Native audio resumes; device ID and volume unchanged |
| Force termination (`kill -9`) | PARTIAL; active case NOT TESTED — RELEASE BLOCKER | Debug app with no active preset kept BlackHole 2ch and volume 63 before/running/after; mandatory active signed case remains |
| Injected lifecycle failures | PASS (automated) | Unit tests cover acquisition unwind, teardown retry, stale generations, bounded retry |

Host inventory observed on 2026-07-15: BlackHole 2ch was default output; MacBook Air Speakers and a legacy public Aggregate Device were present; reported output volume was 63. A Debug build was launched without an active preset and force-killed after two seconds. Default output remained BlackHole 2ch and volume remained 63 before, while running, and after termination. This proves only the no-preset safe-shell path; it is not the mandatory active-processing force-termination pass.

## Performance observations

Record end-to-end latency, callback underruns/dropouts, and CPU with a local physical output and Bluetooth output. Values are informational for 2.0; functional dropouts, unstable recovery, or failed native resumption block release. Both classes are currently **NOT TESTED**.

## Signing and packaging

- Automated build/test/analyze uses unsigned or ad-hoc code and does not establish signed TCC behavior.
- An unsigned universal Release archive was inspected locally: version 2.0.0, build 2000000, minimum OS 15.0, stable bundle ID `com.southneuhof.Airwave`, and arm64/x86_64 slices. Unsigned output provides no signed-entitlement evidence.
- Before release, archive and sign using the release workflow, verify designated requirements and entitlements, then repeat permission, sleep/wake, crash, and force-termination tests.
- If signed behavior differs from the tested build, stop release.
- Replace the Homebrew Cask checksum placeholder only with the SHA-256 of the final 2.0.0 zip. Do not publish the placeholder.

## Release decision

Current decision: **NOT READY FOR RELEASE**. Mandatory active-processing force termination, signed TCC behavior, physical native-resume matrix, and performance observations remain NOT TESTED.
