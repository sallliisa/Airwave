# Multichannel release validation (plan 043)

Durable result table for multichannel release acceptance. Step 1 (software
guidance) is recorded in the plan evidence; hardware, long-duration, and
signed-update gates below stay BLOCKED/NOT RUN. Raw logs, recordings, and
traces belong under `build/`; use `build/Plan043-manual.md` as the session
log with links to those artifacts.

Airwave's output is always stereo. A live physical device can store two
distinct destination channels from **Settings > Registered Devices >
Configure output…**; the saved pair may be reversed or nonadjacent. Without a
saved pair, Airwave uses a valid preferred stereo pair or channels 1–2. Output
selection remains separate from the automatically resolved source feed.
The channel editor uses a native popover; Save applies both destinations
together, while outside-click or Escape dismissal retains the in-memory draft
and Cancel discards it. Manual popover acceptance remains NOT RUN.

Two-channel and ambiguous four-channel duplicate-stereo or unlabeled sources
use a preferred stereo source pair or channels 1–2. Surround input still needs
a resolvable source layout; standard-order fallback applies to unlabeled
6/8/12-channel layouts. LFE content is omitted from the stereo fold-down.
Virtual and aggregate outputs remain unsupported. Actual BOOM jack/source
identity, microphone-prefix behavior, multistream behavior, and listening
acceptance remain NOT RUN; software tests do not establish physical channel
identity.

## Step 1 — software guidance (DONE per plan evidence)

- `OnboardingViewModel.recommendedVoluntaryEntryStep` uses the shared
  runtime routability result (`AudioRuntimeState.isCurrentOutputRoutable`),
  which delegates to the source-aware `OutputRoutingResolver`; there is no
  second output-width check, and permission and setup ordering are kept.
- `RuntimePresentations` and `README.md` distinguish automatic source capture
  from two-channel output destinations; explicit destinations are configured
  per device in Registered Devices.
- `ProductSurfaceTests` covers stereo, resolved multichannel, unresolved
  layout, multi-stream, virtual, aggregate, and narrow cases as
  routing/presentation behavior.

## Step 2 — hardware matrix (BLOCKED, NOT RUN)

Give every row a case ID, source commit plus working diff identity, macOS,
architecture, device/transport, stream count, rate, channel labels,
stimulus, steps, expected result, observed result, and evidence path.
Test stereo headphones and physical 6/8-channel hardware at 44.1 and 48 kHz
where supported, with one identifiable signal per channel; check 12/16
channels where support is claimed and equipment exists. Missing equipment is
NOT RUN and blocks that claim. Cover HRIR/EQ/both/None and reset
transitions; A→B→A during activation; same-ID file replacement; same-device
rate/layout change; sleep/wake; disconnect/reconnect; restoration of native
routing on all device channels after teardown. Use low output volume; stop a
case on unexpected full-scale output, missing native restoration, or unsafe
teardown.

| Case ID | Device/transport/width/rate | Stimulus + steps | Expected | Observed | Evidence |
|---|---|---|---|---|---|
| MC-HW-01 | NOT RUN | One signal per channel on stereo headphones | Stereo on the saved/preferred pair or fallback ch 1–2 | NOT RUN | — |
| MC-HW-02 | NOT RUN | One signal per channel on physical 6ch | Resolved 5.1 source maps to stereo on the selected pair | NOT RUN | — |
| MC-HW-03 | NOT RUN | One signal per channel on physical 8ch | Resolved 7.1 source maps to stereo on the selected pair | NOT RUN | — |
| MC-HW-04 | NOT RUN | 12/16ch where claimed + equipment | Correct mapping or explicit NOT RUN | NOT RUN | — |
| MC-HW-05 | NOT RUN | HRIR/EQ/both/None + reset transitions | Audible output matches selection | NOT RUN | — |
| MC-HW-06 | NOT RUN | A→B→A, same-ID replacement, rate/layout change, sleep/wake, disconnect/reconnect | No failure, restoration correct | NOT RUN | — |
| MC-HW-07 | NOT RUN | Teardown on multichannel device | Native routing restored on all device channels | NOT RUN | — |

## Step 3 — long-duration ownership and CPU (BLOCKED, NOT RUN)

Use the final Release app for at least four hours: initial settled
checkpoint, 30 minutes steady playback, 500 counted preset changes,
100 counted None/resume cycles, repeated inventory reads. Settled
Allocations checkpoints after warm-up, steady playback, workload batches,
and final shutdown: live pipeline count, retained renderer/EQ objects,
process CPU, observed callback gaps, tool and method. At most one live
pipeline; zero after final shutdown; bounded retained DSP state after
control drain. Store traces and counts in the session log.

| Case ID | Workload | Observed | Evidence |
|---|---|---|---|
| MC-LONG-01 | 4 h session with counted workloads | NOT RUN | — |

## Step 4 — distribution checks (software gates PASS on final source; signed/hardware BLOCKED)

Software gates run by orchestrator 2026-09-13 on final source state
(branch `advisor/022-multichannel-capture` + full uncommitted working diff,
Step 1 edits included; default DerivedData path):

- Full Debug XCTest: 415 tests, 0 failures (`TEST SUCCEEDED`).
  Log: `build/Plan043-full-debug.log`.
- Separate Release build: `BUILD SUCCEEDED`.
  Log: `build/Plan043-release.log`.
- Separate Debug build: `BUILD SUCCEEDED`.
  Log: `build/Plan043-debug-build.log`.
- Both bundle checks: eight source-matching presets each (`exit 0`).
  Log: `build/Plan043-bundle-final.log`. Caveat: Debug app binary
  timestamp (13:40) predates the full-test relink (13:44); 043 edits
  touch no resources, so bundle content is unaffected.
- Safety invariants: PASS. Version script: PASS. 2.0 metadata: PASS
  (Cask checksum pending artifact, by design). `git diff --check`: clean.
  Log: `build/Plan043-step4-gates.log`.
- Plan-025 CPU evidence: `build/Plan025-perf-pass{1,2,3}.log`,
  `build/Plan025-benchmark-run{1,2,3}.json` (reviewed, current engine).
- Plan-028 signed-update evidence: software pin only; signed gate BLOCKED.

| Case ID | Check | Observed | Evidence |
|---|---|---|---|
| MC-DIST-01 | Full Debug (415/0) + Release + Debug builds + both bundles + scripts | PASS software; signed/hardware stay BLOCKED | `build/Plan043-full-debug.log`, `build/Plan043-release.log`, `build/Plan043-debug-build.log`, `build/Plan043-step4-gates.log`, `build/Plan043-bundle-final.log` |
| MC-DIST-02 | Signed update matrix | BLOCKED — no release/appcast authorized | plan 028 |
