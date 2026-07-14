# Plan 007: Prove multichannel feasibility before committing

> **Executor instructions**: This is a research/spike plan. Do not merge
> multichannel code into the 2.0 stereo runtime. Produce evidence and a go/no-go
> recommendation, then update the index.
>
> **Drift check**: `git diff --stat f020179..HEAD -- Airwave AirwaveTests docs`
> Confirm the stereo 2.0 release gate in plan 006 is DONE.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/006-release-and-safety-validation.md`
- **Category**: direction / migration
- **Planned at**: commit `f020179`, 2026-07-15

## Why this matters

The retained models describe 5.1, 7.1, and 7.1.4 layouts, but the current and
2.0-effective DSP seam processes only stereo. Process taps may preserve wider
device stream layouts in some configurations, but availability, channel labels,
protected content, clocking, and binaural output behavior must be proven before
promising a feature. This spike prevents speculative complexity from destabilizing
the safety-focused stereo release.

## Current state

- `VirtualSpeaker.InputLayout.detect` recognizes 2, 6, 8, and 12 channels.
- `RealtimeAudioProcessor.processPendingBlock` intentionally processes at most
  two renderers (`min(renderers.count, 2)`).
- Global stereo process-tap capture is the locked 2.0 contract.
- Product decision: multichannel starts with a research gate, not a committed
  implementation phase.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Baseline tests | `xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all pass |
| Build spike | Use a separate disposable branch/worktree and the standard build command | succeeds without changing release runtime |

## Scope

**In scope**:

- Add `docs/multichannel-process-tap-spike.md` with experiment design, raw format/
  layout observations, device matrix, safety results, and recommendation.
- Disposable spike/test-harness code outside the release path; remove it before
  finishing unless it is a reusable opt-in diagnostic target.
- Analysis of required DSP/data-model changes and a future plan outline.

**Out of scope**:

- Shipping multichannel capture, changing the default stereo tap, changing HRIR
  formats, or advertising multichannel support.
- Broad DSP optimization or new virtual-device dependencies.

## Git workflow

- Branch: `codex/007-multichannel-feasibility`
- Commit documentation only unless an opt-in diagnostic harness is intentionally
  retained. Do not push or open a PR unless instructed.

## Steps

### Step 1: Define hypotheses and success conditions

Document the questions before coding: which macOS 15 tap initializer preserves
the destination device stream instead of stereo mixdown; whether process output
actually contains discrete 5.1/7.1 channels; whether channel labels/order are
recoverable; whether Airwave can emit binaural stereo safely to the same current
output; and whether muted-when-tapped/native passthrough remains reliable.

Success requires repeatable labeled discrete-channel capture on at least two
relevant configurations without route/volume mutation or public virtual devices.

**Verify**: spike document contains hypotheses, apparatus, and pass/fail criteria
before experiment results.

### Step 2: Build an isolated capture inspection harness

On a disposable branch/worktree, adapt the concrete client to create a
device/stream-specific non-mixdown tap without changing production defaults.
Record ASBD, channel layout/labels, callback buffer structure, and test-tone
energy by channel. Do not connect experimental buffers to the release DSP until
capture semantics are proven.

**Verify**: baseline release tests still pass; no production file diff remains
unless explicitly retained as an opt-in diagnostic target.

### Step 3: Test representative layouts and transitions

Where hardware/software permits, test 5.1 and 7.1 sources/destinations, sample-
rate changes, layout changes, device switches, sleep/wake, failure, and force
termination. Record unsupported/protected content behavior without attempting to
bypass platform restrictions. Confirm default output and volume invariants in
every experiment.

**Verify**: each matrix row has environment, observed ASBD/layout, per-channel
result, passthrough result, and route/volume evidence.

### Step 4: Assess DSP and API blast radius

Specify, without implementing, how `RealtimeAudioProcessor` must accept N labeled
inputs, how every virtual speaker maps to HRIR renderers, how LFE/headroom/clipping
are handled, how output remains stereo, and which tests replace the current
two-renderer assumption. Estimate latency/memory/CPU diagnostically.

**Verify**: document names exact production types/files affected and includes a
testable proposed input/output interface.

### Step 5: Render a go/no-go verdict

Choose one:

- GO: evidence meets success criteria; write a new self-contained implementation
  plan, still preserving all 2.0 safety invariants.
- NO-GO: platform does not expose reliable discrete channels without violating
  constraints; document the evidence and stop.
- INVESTIGATE: one bounded missing experiment remains; state owner, hardware, and
  exact result needed. Do not call this support.

**Verify**: verdict is explicit and traceable to matrix evidence.

## Test plan

- Discrete labeled tone per channel for 5.1/7.1 where available.
- Layout/sample-rate transition and stale callback safety.
- Crash/force-termination native passthrough.
- Default-output and device-volume before/after checks.
- Baseline stereo regression suite after removing the spike.

## Done criteria

- [ ] No multichannel behavior ships in the 2.0 runtime.
- [ ] Evidence covers at least two relevant configurations or verdict is NO-GO.
- [ ] Safety invariants hold in every experiment.
- [ ] DSP blast radius and proposed interface are explicit.
- [ ] Verdict is GO, NO-GO, or bounded INVESTIGATE.

## STOP conditions

- Testing requires changing the system default, device volume, or installing a
  virtual driver.
- Muted-when-tapped fails to restore native audio in any layout.
- The experiment requires bypassing protected-content or platform restrictions.
- Spike changes leak into the production stereo path before a GO plan is approved.

## Maintenance notes

Do not treat channel count alone as a layout. Future implementation must use
verified labels/order and preserve the same fail-open behavior as stereo 2.0.

