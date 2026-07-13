# Plan 003: Make device discovery responsive and contributor workflow reproducible

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm expected result. Stop on any STOP condition; do not improvise. When done, update this plan's status row in `plans/README.md`, unless reviewer maintains index.
>
> **Drift check (run first)**:
> `git diff --stat 3592756..HEAD -- .gitignore README.md .github/workflows/ci.yml Airwave.xcodeproj/project.pbxproj Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme Airwave.xcodeproj/xcuserdata Airwave.xcodeproj/project.xcworkspace/xcuserdata Airwave/AudioDevice.swift Airwave/AggregateDeviceInspector.swift Airwave/AudioDeviceQueryService.swift AirwaveTests/AudioDeviceQueryServiceTests.swift`
> Plans 001–002 may legitimately change project/scheme. Reconcile those changes; unexpected overlap is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-realtime-audio-hardening.md`
- **Category**: perf, dx, docs
- **Planned at**: commit `3592756`, 2026-07-14

## Why this matters

`AudioDevice` stores only an ID, so every name, capability, sample-rate, UID, and aggregate check performs synchronous CoreAudio calls. `refreshDevices()` runs those queries and three filter passes on main queue, risking UI stalls when hardware changes. Contributor workflow has no source build/test instructions or CI, personal Xcode state is tracked, and README version `1.1.1` disagrees with built `MARKETING_VERSION = 1.1`. This plan creates immutable device snapshots off main thread and establishes clean, repeatable build/release checks.

## Current state

- `Airwave/AudioDevice.swift` — device model, CoreAudio property calls, listeners, and refresh flow.
- `Airwave/AggregateDeviceInspector.swift` — already creates `SubDeviceInfo` snapshots but rebuilds a device lookup by re-enumerating and re-querying UIDs.
- `.gitignore` — contains only `.DS_Store`.
- Tracked user files include `Airwave.xcodeproj/project.xcworkspace/xcuserdata/gamer.xcuserdatad/UserInterfaceState.xcuserstate`, breakpoint data, and scheme-management state.
- `README.md` documents binary installation, not source build/test workflow.
- `README.md:8` says `1.1.1`; `Airwave.xcodeproj/project.pbxproj:289,349` says `MARKETING_VERSION = 1.1`.
- Plan 001 creates `AirwaveTests`; this plan extends that target.

Current dynamic model (`Airwave/AudioDevice.swift:13-28`):

```swift
struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    var name: String { AudioDeviceManager.getDeviceName(deviceID: id) ?? "Unknown" }
    var hasInput: Bool { AudioDeviceManager.getChannelCount(deviceID: id, scope: kAudioObjectPropertyScopeInput) > 0 }
    var hasOutput: Bool { AudioDeviceManager.getChannelCount(deviceID: id, scope: kAudioObjectPropertyScopeOutput) > 0 }
    var sampleRate: Double { AudioDeviceManager.getSampleRate(deviceID: id) }
    var isAggregateDevice: Bool { AudioDeviceManager.isAggregateDevice(deviceID: id) }
    var uid: String? { AudioDeviceManager.getDeviceUID(self) }
}
```

Current main-thread refresh (`Airwave/AudioDevice.swift:85-96`):

```swift
func refreshDevices() {
    DispatchQueue.main.async { [weak self] in
        let allDevices = Self.getAllDevices()
        self?.inputDevices = allDevices.filter { $0.hasInput }
        self?.outputDevices = allDevices.filter { $0.hasOutput }
        self?.aggregateDevices = allDevices.filter { $0.isAggregateDevice }
        // defaults queried synchronously too
    }
}
```

Conventions to preserve:

- `AudioDevice` equality/hash identity remains based only on `AudioDeviceID`.
- CoreAudio listeners remain callbacks that schedule safe refresh work; do not update `@Published` properties off main actor.
- Device control operations such as setting volume/default output may query live hardware; snapshotting applies to display/classification metadata, not mutable control values.
- `AggregateDeviceInspector.SubDeviceInfo` remains public shape used by views and audio manager.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| All tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | exit 0; `** TEST SUCCEEDED **` |
| Targeted tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:AirwaveTests/AudioDeviceQueryServiceTests` | exit 0; target suite passes |
| CI syntax | `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); puts "valid"'` | exit 0; prints `valid` |
| Tracked user data | `git ls-files | rg '(^|/)xcuserdata/|\.xcuserstate$|xcdebugger/'` | exit 1; no output |

## Suggested executor toolkit

- GitHub's `macos-26` runner and installed Xcode inventory: <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md>.

## Scope

**In scope**:

- `.gitignore`
- `README.md`
- `.github/workflows/ci.yml` (create)
- `Airwave.xcodeproj/project.pbxproj` only for test membership/version reconciliation needed here
- `Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme` only if CI test action needs correction
- Tracked files under `Airwave.xcodeproj/xcuserdata/` and `Airwave.xcodeproj/project.xcworkspace/xcuserdata/` may be removed from Git index
- `Airwave/AudioDevice.swift`
- `Airwave/AggregateDeviceInspector.swift`
- `Airwave/AudioDeviceQueryService.swift` (create if used)
- `AirwaveTests/AudioDeviceQueryServiceTests.swift` (create)

**Out of scope**:

- Deleting untracked user workspace settings or other developer-local files. Ignore them; do not destroy them.
- Audio rendering, HRIR/preset lifecycle, UI redesign, volume/default-device policy, or aggregate channel mapping semantics.
- Signing, notarization, release publishing, or Developer Program enrollment.
- Adding formatter/linter dependencies. Build/test/analyze are sufficient baseline here.
- Changing minimum macOS deployment target.

## Git workflow

- Branch: `codex/003-device-snapshots-workflow`
- Suggested commits: `perf: snapshot CoreAudio device metadata`, then `chore: add reproducible project checks`.
- Use `git rm --cached`, not filesystem deletion, when untracking personal Xcode data that developer may want locally.
- Do not push/open PR unless instructed.

## Steps

### Step 1: Introduce immutable device metadata snapshots

Change `AudioDevice` so normal property reads do not call CoreAudio. Store, at minimum:

- `id`
- `name`
- `uid`
- `inputChannelCount`
- `outputChannelCount`
- `sampleRate`
- `isAggregateDevice`

Derive `hasInput`, `hasOutput`, and existing `channelCount` from stored counts. Keep equality/hash based only on `id` so selections survive refreshed metadata values.

Extract CoreAudio reads behind an internal `CoreAudioDeviceQuerying` protocol or equivalent test seam. Production implementation performs each metadata query once per device snapshot. Keep existing low-level static functions when live hardware operations need them, but views/filtering must read stored values.

Update `getAllDevices`, `getDeviceInfo`, UID translation, and default-device lookup to return complete snapshots. During one refresh, resolve default input/output IDs against already-created snapshots; avoid querying full metadata a second time.

Update `AggregateDeviceInspector.getSubDevices` lookup to use stored `device.uid` rather than querying every UID again. Preserve missing-device behavior and channel-range calculation.

**Verify**: run Build command. Expected: build succeeds without call-site API changes outside scope.

### Step 2: Move enumeration off main thread with stale-refresh protection

Refactor `AudioDeviceManager.refreshDevices()`:

- Perform enumeration and snapshot creation on one dedicated serial query queue or structured detached task.
- Publish `inputDevices`, `outputDevices`, `aggregateDevices`, and defaults together on main actor.
- Use a generation counter or serial ordering so an older slow refresh cannot overwrite a newer result.
- Coalesce bursts from device/default listeners when practical; one short debounce is acceptable, but do not delay initial load by seconds.
- Never publish partial list state between filters.
- Keep CoreAudio listener registration/removal lifecycle unchanged.

Create fake-query tests that prove:

1. Each metadata field is queried at most once per device per refresh.
2. Derived input/output/aggregate lists use snapshot data without further provider calls.
3. Older delayed refresh cannot overwrite newer result.
4. Publication occurs on main thread/main actor.
5. Equality/hash remains ID-only across changed metadata.

**Verify**: run Targeted tests. Expected: all five behaviors pass.

### Step 3: Ignore and untrack personal Xcode state

Expand `.gitignore` with standard Xcode local artifacts:

```gitignore
.DS_Store
DerivedData/
*.xcuserstate
xcuserdata/
*.xccheckout
*.xcscmblueprint
```

Preserve shared scheme and project/workspace files. Untrack currently committed personal state using `git rm --cached` or patch deletions; do not delete untracked local files. Verify shared scheme still tracked.

**Verify**:

`git ls-files | rg '(^|/)xcuserdata/|\.xcuserstate$|xcdebugger/'`

Expected: no output, exit 1.

`git ls-files Airwave.xcodeproj/xcshareddata/xcschemes/Airwave.xcscheme`

Expected: prints shared scheme path.

### Step 4: Document exact source workflow and remove version duplication

Add concise `Development` section to README:

- Prerequisites: macOS, full Xcode 26, macOS SDK, no BlackHole required for unit tests.
- Open project command: `open Airwave.xcodeproj`.
- Unsigned local Build and Test commands from this plan.
- State that manual audio smoke tests require virtual device, microphone permission, aggregate setup, and HRIR preset.
- Explain full Xcode selection when `xcode-select` points at Command Line Tools.

Make Xcode `MARKETING_VERSION` authoritative. Remove hard-coded README version number or generate/display it from release tag without a second manually edited literal. Do not silently choose whether product should be `1.1` or `1.1.1`; removing README duplication is preferred. If maintainer requires README version literal, STOP and request desired source of truth.

**Verify**:

`rg -n 'Version:.*[0-9]+\.[0-9]+' README.md`

Expected: no hard-coded version match.

Then run Build and All tests. Expected: both succeed.

### Step 5: Add CI build, test, and analyze gates

Create `.github/workflows/ci.yml` triggered on pull requests and pushes to `main`:

- Runner: `macos-26`.
- Print `xcodebuild -version` for diagnostics.
- Build unsigned Debug app.
- Run all unit tests with `destination 'platform=macOS'` and `CODE_SIGNING_ALLOWED=NO`.
- Run static analyze.
- Set timeout (15–20 minutes) and cancel superseded runs with workflow concurrency.
- Do not install BlackHole, request permissions, access secrets, or run hardware-dependent app tests.

Use `/Applications/Xcode.app` rather than a minor-version path unless project truly requires an exact Xcode patch. This reduces runner-image churn.

**Verify**: run CI syntax command, then execute the same build/test/analyze commands locally. Expected: YAML valid and all Xcode commands succeed. After push by operator, required external verification is one green CI run; executor must not push without instruction.

## Test plan

- `AudioDeviceQueryServiceTests.swift` uses fake property provider; no real hardware assumptions.
- Assert query counts, complete snapshot fields, ID-only identity, stale-generation rejection, and main-actor publication.
- Run full Plan 001/002 test suite to catch project/scheme regressions.
- Manual smoke: connect/disconnect one output device while Settings is visible. Expected: UI remains responsive, lists update once, current selection semantics unchanged.

## Done criteria

- [ ] Device display/classification properties read immutable stored metadata.
- [ ] One refresh queries each metadata field at most once per device.
- [ ] Enumeration occurs off main; one coherent snapshot publishes on main.
- [ ] Older refresh cannot overwrite newer result.
- [ ] Aggregate inspector reuses snapshot UID lookup.
- [ ] Build, test, and analyze commands succeed locally.
- [ ] CI YAML parses and workflow contains unsigned build/test/analyze on `macos-26`.
- [ ] No personal Xcode state remains tracked; shared scheme remains tracked.
- [ ] README contains source build/test instructions and no duplicate hard-coded version.
- [ ] Existing untracked user files were not deleted.
- [ ] `git diff --name-only` contains only in-scope files plus plan status update.
- [ ] `plans/README.md` row 003 updated.

## STOP conditions

Stop and report if:

- Plan 001 test target is absent or broken.
- Snapshot conversion requires changing equality/hash away from device ID.
- CoreAudio API returns metadata that cannot safely be captured once per refresh and requires live semantics for UI correctness; identify exact property.
- Off-main CoreAudio queries fail under Thread Sanitizer or documented API constraints.
- Existing untracked workspace files would need deletion.
- Maintainer wants README and Xcode version literals both retained but has not chosen source of truth.
- GitHub `macos-26` no longer exists or lacks a compatible full Xcode; report current official runner inventory.
- Any verification fails twice after reasonable correction.
- Out-of-scope file becomes necessary.

## Maintenance notes

- Snapshots intentionally become stale until next CoreAudio notification/refresh. New UI needing instantaneous live data must call explicit query API, not reintroduce computed CoreAudio getters.
- Reviewer should compare listener behavior before/after and inspect query-count tests; UI smoothness alone is weak evidence.
- CI runner images evolve. Keep OS label explicit and Xcode path generic unless toolchain pin is justified.
- Notarization/release automation remains deferred because project currently lacks signing credentials and user did not request external publishing.

