# Plan 005: Authoritative permission and fail-safe probe

> Implemented against the live Plan 004 worktree on 2026-07-17. This follow-up
> supersedes permission inference from successful Core Audio startup or render.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 004
- **Category**: bug
- **Status**: DONE

## Outcome

- TCC `kTCCServiceAudioCapture` preflight/request is the sole permission authority.
- Missing, unexpected, or conflicting TCC results remain unknown and never start muted processing.
- Permission requests are idempotent, generation-bound, and rechecked by preflight.
- Permission and no-effect tap probes use an unmuted process tap.
- Only TCC-granted effect processing uses `mutedWhenTapped`.
- Successful I/O startup and render callbacks update tap health but never grant permission.
- App activation refreshes TCC state and stops processing after revocation.

## Verification

- `scripts/test-audio-safety-invariants.sh`
- `scripts/test-release-version.sh`
- `scripts/verify-2.0-metadata.sh`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`

All gates passed: 241 tests executed, 1 skipped, 0 failures.

## Manual release checks

Use one stable Developer ID-signed bundle and bundle identifier for fresh allow,
deny, grant in Settings, revocation, silence, retry, quit/relaunch, and output
transition checks. Remove stale ad-hoc TCC entries before comparing Settings with
the running build. Private TCC SPI must be revalidated for every macOS release.
