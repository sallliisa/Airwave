# Implementation Plans

Generated and extended by `improve` on 2026-07-14. Plans 001–003 were written at commit `3592756`; Plans 004–006 were written at commit `6f2978f`. Execute in order below unless dependencies say otherwise. Each executor must read its plan fully, honor STOP conditions, run every gate, and update its row.

## Execution order and status

| Plan | Title | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| 001 | Make real-time audio processing frame-safe and non-blocking | P1 | L | — | DONE |
| 002 | Make preset activation cancellable, deduplicated, and latest-wins | P1 | M | 001 | DONE |
| 003 | Make device discovery responsive and contributor workflow reproducible | P2 | M | 001 | DONE |
| 004 | Define and test one deterministic device-selection policy | P1 | M | 003 | REJECTED — omitted virtual-output invariant; superseded by 008–010 |
| 005 | Make one coordinator own preferences, discovery, and fallback | P1 | L | 004 | REJECTED — production coordinator caused route feedback loop; superseded by 009–010 |
| 006 | Make views passive and apply resolved routes transactionally | P1 | L | 005 | REJECTED — transition contract and hardware gates incomplete; superseded by 010 |

Status values: `TODO`, `IN PROGRESS`, `DONE`, `BLOCKED — <reason>`, `REJECTED — <reason>`.

## Dependency notes

- Plan 001 goes first because it creates test infrastructure and changes renderer-state/frame-processing contracts used by Plan 002.
- Plan 002 follows Plan 001 because clean deactivation and matching-state publication must use Plan 001's state handoff and frame adapter.
- Plan 003 needs Plan 001's test target, but otherwise does not depend on Plan 002. It can run parallel with Plan 002 only in isolated branches/worktrees; both may touch Xcode project metadata, so reconcile carefully before merge.
- Recommended merge order: 001 → 002 → 003.
- Plan 004 is the mandatory characterization seam for the device-selection rewrite. It must land before behavior changes.
- Plan 005 depends on Plan 004's preferred-versus-effective contract and centralizes persistence, inventory, and listener ownership.
- Plan 006 depends on Plan 005's coordinator; it removes the legacy view/graph backdoors and exposes fallback honestly in the UI.
- Plans 004–006 were rolled back after introducing a default-output feedback loop and virtual-output regression. Their code is archived outside the repository; replacement work must follow Plans 007–010 below.

## Recovery continuation

| Plan | Title | Priority | Depends on | Status |
|---|---|---|---|---|
| 007 | Restore and verify pre-004 routing baseline | P0 | — | DONE |
| 008 | Isolate routing effects and characterize virtual-output rules | P1 | 007 | DONE |
| 009 | Build coordinator off production path | P1 | 008 | DONE |
| 010 | Cut over to transactional routing behind a safety gate | P0 | 009 | IN PROGRESS — coordinator default; hardware soak ongoing |
- Recommended continuation order: 004 → 005 → 006. Do not parallelize them.

## Audit coverage represented

- Plan 001 coalesces missing verification baseline, arbitrary CoreAudio callback-size correctness, Release capacity bounds, callback allocation, and blocking render-path synchronization.
- Plan 002 covers duplicate/stale preset builds and explicit deactivation.
- Plan 003 covers main-thread CoreAudio metadata queries, tracked Xcode user state, missing contributor/CI workflow, and duplicate version source.
- Plan 004 covers the missing selection-state verification matrix and defines deterministic UID/fallback semantics without changing production behavior.
- Plan 005 covers split settings caches, racing refresh generations, torn aggregate snapshots, accumulated listeners, transient-ID matching, and the absence of a single selection owner.
- Plan 006 covers duplicate Settings/menu control paths, partial route mutation, stale route effects, fallback visibility, and missing behavior documentation.

## Findings considered and rejected

- Sorting preset arrays during SwiftUI renders: expected lists are small; not worth added cache invalidation complexity.
- Debug logger formatting: compiled out of Release via `#if DEBUG`; not production hot-path issue.
- Fixed 64-channel/4096-frame preallocation: only a few MB and intentional real-time tradeoff; retain unless measurements show memory pressure.
- Full WAV read when discovering a newly added preset: off steady-state hot path; activation coordination has higher leverage.
- Dependency cleanup: project has no third-party package dependencies.
- Treating `ConfigurationManager.swift` as part of device selection: rejected; it only loads external URLs.
- Repairing `AppSettings` legacy initialization for an omitted optional input UID: rejected after build verification; Swift's optional memberwise parameter defaults to `nil`, and the unsigned Debug build succeeds.
- Persisting numeric `AudioDeviceID` as a reconnect fallback: rejected because CoreAudio IDs are explicitly observed to change while UIDs remain stable.
- Making fallback the new preference after a timeout: rejected for now; no product requirement supports silently discarding user intent. If desired later, it must be an explicit policy and UI choice.

## Shared execution rules

- Preserve user's pre-existing dirty Xcode workspace changes. Do not delete or overwrite untracked local workspace settings.
- Never add real HRIR files, generated DerivedData, credentials, signing profiles, or personal Xcode state.
- No executor may push, create PR, publish release, or change signing/notarization without explicit operator instruction.
- Full Xcode is required. Command Line Tools alone produce: `tool 'xcodebuild' requires Xcode`.
- At audit time, the unsigned Debug build succeeded, but the documented test command exited 66 because user-owned dirty changes removed `AirwaveTests` from the shared scheme's test action. Plans 004–006 must not overwrite those changes; execute from a clean worktree or have the operator reconcile the scheme first.
