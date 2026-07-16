# Plan 004: Reset permission and audio-tap health

> Implemented against commit `76ecc31` on 2026-07-17. Permission state,
> Core Audio tap health, and processing state are independent. Keep this split
> when changing onboarding or audio lifecycle behavior.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 001, 003
- **Category**: bug
- **Status**: DONE

## Outcome

- The public Core Audio recording start is the permission request boundary; Airwave does not call private TCC SPI.
- The onboarding action starts a bounded tap-backed aggregate probe so macOS presents its native System Audio Recording prompt.
- Permission exposes unknown/checking/granted/denied; tap health exposes idle/checking/ready/failed.
- Setup health requires granted permission, ready tap health, and a supported output. No selected effect remains healthy inactive.
- Permission and tap diagnostics appear as separate cards only in onboarding.
- Terminal permission or tap failure restores menu setup attention without auto-opening onboarding.

## Verification

- `scripts/test-audio-safety-invariants.sh`
- `scripts/test-release-version.sh`
- `scripts/verify-2.0-metadata.sh`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`

All gates passed: 233 tests executed, 1 skipped, 0 failures.

## Manual release checks

Repeat with a signed build: already granted, fresh allow, denial, revocation,
silent system, retry, quit/relaunch, and physical-output transition. Automated
unsigned tests cannot establish real macOS permission behavior.

Apple exposes no public preflight/request API for system-audio-only capture.
Revalidate the Core Audio recording-start boundary on every macOS release.
