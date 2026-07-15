# Plan 006: Complete Airwave 2.0 docs and safety validation

> **Executor instructions**: This is the release gate. Safety failures block the
> release; latency/CPU measurements are recorded but do not block. Do not publish
> a release, tag, push, or GitHub issue without separate operator instruction.
>
> **Drift check**: `git diff --stat f020179..HEAD -- README.md docs Casks .github Airwave AirwaveTests scripts Airwave.xcodeproj`
> Confirm plans 001–005 are DONE before release validation.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/005-rebuild-product-surfaces.md`
- **Category**: migration / docs / tests
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

Code-only cutover would still direct users toward the hazardous legacy setup and
could offer an incompatible update to macOS 14. Airwave 2.0 needs coherent docs,
package metadata, update compatibility, and a physical safety matrix proving
that route and volume remain native through crashes and failures.

## Current state

- README requirements and setup require BlackHole and a manual aggregate.
- `Casks/airwave.rb:16-23` declares Sonoma and repeats the old setup caveat.
- Current public version is 1.1.1 and CI builds/tests/analyzes on macOS runners.
- Product decisions: call the clean break 2.0; macOS 15 minimum; 1.x is final
  macOS 14 line; safety gates release; performance numbers are informational.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | succeeds |
| Test | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | succeeds |
| Legacy search | `rg -n -i 'blackhole|aggregate device|virtual audio device|microphone permission|setDeviceVolume|setSystemDefaultOutputDevice' README.md docs Airwave AirwaveTests Casks` | no unsupported guidance/code |

## Scope

**In scope**:

- README, relevant `docs/` assets, Cask, project version/deployment metadata,
  Info.plist/entitlements, CI/release workflow, scripts, and a new
  `docs/airwave-2-safety-matrix.md` recording test procedure/results.
- Test additions required by failures found during validation.

**Out of scope**:

- Publishing/tagging/pushing a real release.
- Feature work, UI redesign beyond factual corrections, performance tuning,
  multichannel implementation.

## Git workflow

- Branch: `codex/006-release-and-safety-validation`
- Commit examples: `docs: rewrite setup for Airwave 2.0` and
  `test(audio): add process-tap safety matrix`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Rewrite documentation and packaging

Rewrite README features, requirements, installation, setup, use, troubleshooting,
and credits for process taps, System Audio Capture, HRIR selection, automatic
output following, native volume authority, and native passthrough failure. Remove
legacy screenshots and unsupported setup instructions. Update Cask minimum to
Sequoia/macOS 15 and remove caveats about virtual devices/aggregates.

**Verify**: legacy search command → no matches except an explicitly labeled 1.x
migration note stating BlackHole is unsupported in 2.0.

### Step 2: Version and compatibility metadata

Set marketing version to `2.0.0` when preparing the first release candidate and
keep bundle identity stable. Ensure project/app/test minimums are 15.0. Configure
Sparkle/appcast generation so macOS 14 users remain on the compatible 1.x line
and are not offered an unusable 2.0 update; add a release-script test for minimum
system version metadata. Update Homebrew metadata only with placeholder checksum
until a real artifact exists; do not invent a hash.

**Verify**: release-version script tests pass; built app Info.plist reports 2.0.0
and minimum 15.0; generated/test fixture appcast includes the minimum OS gate.

### Step 3: Add invariant checks to CI

Keep build, unit test, and analyze gates. Add a script/CI step that fails on
legacy mutation helpers and volume selectors, stale BlackHole/aggregate guidance,
or microphone capture metadata. It may allow read-only default-output selectors
inside `CoreAudioPlatformClient`; it must not naively ban all references to the
default-output selector. Ensure normal CI never invokes the signed/live tap test
or triggers TCC.

**Verify**: run the invariant script against the clean tree (pass), then against
a temporary test fixture containing a forbidden symbol (expected nonzero); do
not leave the fixture in the tree.

### Step 4: Execute the physical safety matrix

Document macOS build, hardware, output transport, expected result, actual result,
and logs for at least:

- built-in speakers/headphone output;
- wired/USB DAC;
- Bluetooth/AirPods;
- HDMI/display audio where available;
- AirPlay where available;
- unsupported BlackHole/virtual output;
- default-output switch during playback;
- device disconnect/reconnect and rapid switches;
- permission grant, deny, revoke, and restore;
- sleep/wake;
- normal quit, crash, and force termination;
- tap/pipeline injected failures.

For every case, record that the macOS default output ID and all device volume
scalars are identical before/after Airwave operations, and that native audio
resumes on failure. If a device class is unavailable, mark it NOT TESTED and do
not claim support for it in README/release notes.

**Verify**: every claimed supported class has PASS evidence; no safety row is
FAIL. NOT TESTED classes are documented as best-effort/unsupported.

### Step 5: Record non-blocking performance observations

Record end-to-end added latency estimate, callback underruns, and CPU for a
representative local output and Bluetooth output. Do not fail release solely for
regression; open follow-up findings if materially poor. Functional dropouts or
instability remain safety/functional failures and do block.

**Verify**: measurements and environment are recorded in the safety matrix.

### Step 6: Run the complete release candidate gate

Run build, tests, release analyze, invariant script, release-version tests, and
manual matrix review. Verify signed/ad-hoc packaging preserves required
entitlements and process-tap permission behavior. Do not publish.

**Verify**: all automated commands exit 0; manual safety matrix has no unwaived
safety failure; package opens and processes on macOS 15.

## Test plan

- CI invariant script positive/negative fixtures.
- Release metadata/appcast minimum-OS test.
- Existing unit/integration suite.
- Signed physical safety matrix with native route/volume before/after evidence.
- Force-termination check is mandatory because it validates the main hazard.

## Done criteria

- [ ] Public docs and Cask describe only the 2.0 architecture.
- [ ] 2.0 requires macOS 15 and 1.x remains the macOS 14 line.
- [ ] CI blocks route/volume mutation and stale legacy metadata.
- [ ] Every claimed device class has safety evidence.
- [ ] Crash/force termination resumes native audio without route/volume changes.
- [ ] Performance is measured and recorded but not used as a numeric gate.
- [ ] No release/tag/push occurred.

## STOP conditions

- Any safety-matrix case changes output identity or volume.
- Native audio does not resume after crash/force termination.
- macOS 14 can be offered or install the 2.0 update through current metadata.
- Signed packaging behaves differently from development with respect to tap
  permission or sandbox access.
- A claimed device class cannot be tested; downgrade the claim and report.

## Maintenance notes

Keep the matrix for every audio-backend release. New output classes are not
"supported" until their safety rows pass, even if Core Audio enumerates them.
