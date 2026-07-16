# Plan 012: Compose EQ with the fail-open audio runtime

> **Executor instructions**: Integrate the completed EQ processor with runtime
> policy without weakening process-tap lifecycle or route/volume invariants.
> Run every gate and update `plans/README.md` when complete.
>
> **Drift check (run first)**:
> `git diff --stat 28b0210..HEAD -- Airwave/AudioPipeline.swift Airwave/AudioRuntimeController.swift Airwave/AppDelegate.swift Airwave/HRIRManager.swift Airwave/AudioRuntimeState.swift AirwaveTests/AudioPipelineTests.swift AirwaveTests/AudioRuntimeControllerTests.swift`
> Plans 010 and 011 are expected to add EQ types and processor state. Confirm
> both are DONE before changing runtime policy.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/011-realtime-parametric-eq.md`
- **Category**: direction / migration
- **Planned at**: commit `28b0210`, 2026-07-16

## Why this matters

EQ must work alone or after HRIR while preserving Airwave's strongest promise:
native audio remains authoritative whenever processing is unavailable. This
phase changes readiness from “HRIR selected” to “at least one prepared effect”
and ensures ordinary EQ selection does not churn Core Audio resources.

## Current state

- `AudioRuntimeController.shared` constructs `AudioPipeline` with
  `HRIRManager.shared` as the sole `StereoAudioProcessing` implementation.
- `AudioRuntimeController` stores `presetReady`, starts only for a ready HRIR or
  permission probe, and stops/restarts on every `presetDidChange` call.
- `HRIRManager.processAudio` already copies input to output when no renderer is
  active. It must remain the authority for HRIR state and convolution.
- `AudioPipeline` owns only tap → private aggregate → I/O lifecycle. Do not add
  EQ selection or persistence to it.
- Existing controller tests use injected platform, pipeline factory, and
  scheduler fakes; extend these seams rather than adding singleton test hooks.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Runtime tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AirwaveTests/AudioEffectGraphTests -only-testing:AirwaveTests/AudioRuntimeControllerTests -only-testing:AirwaveTests/AudioPipelineTests test` | selected tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` | all tests pass |
| Analyze | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO analyze` | `ANALYZE SUCCEEDED` |
| Safety | `scripts/check-audio-safety-invariants.sh && scripts/test-audio-safety-invariants.sh` | passed messages |

## Scope

**In scope**: a focused `AudioEffectGraph`, preparation/readiness interfaces,
controller/AppDelegate wiring, runtime presentation for EQ configuration
failure, and focused graph/controller tests.

**Out of scope**: parser/library filesystem behavior, Settings UI, new HAL
capabilities, output selection, volume access, per-app capture, multichannel,
limiting, or changes to HRIR convolution math.

## Git workflow

- Branch: `codex/012-compose-eq-runtime`
- Suggested commit: `feat(audio): compose equalizer with runtime`
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add a composable effect graph

Create `AudioEffectGraph` implementing `StereoAudioProcessing`. Inject the
spatial processor/readiness source and EQ processor/readiness source through
protocols. For every callback:

1. If HRIR is ready, process input through it into output; otherwise copy stereo
   input to output exactly as `HRIRManager` currently does.
2. Apply EQ in place to the post-HRIR output when its prepared target is active.

The graph owns no files, defaults, Core Audio objects, or UI state. Provide a
control-thread `prepare(for output: OutputDeviceDescriptor)` method returning a
structured result: runnable effects, nonfatal EQ warning, and whether no effect
can run. Preparation passes the output sample rate to EQ before tap acquisition.

**Verify**: graph spy tests prove passthrough, HRIR-only, EQ-only, both in the
exact order HRIR → EQ, and neither.

### Step 2: Make readiness effect-based

Replace the controller's HRIR-specific `presetReady` concept with injected
effect readiness while retaining permission-probe semantics. The matrix is:

| HRIR | EQ selection | Runtime intent |
|---|---|---|
| none | None | inactive except short permission probe |
| active | None | processing HRIR |
| none | valid preset | processing EQ |
| active | valid preset | HRIR then EQ |

Expose one controller entry point that includes current readiness and an
invalidation kind. HRIR activation changes remain full processor invalidations
because renderer state/sample-rate setup follows existing behavior. EQ target
changes are live updates when a pipeline is already running; they must not stop
or recreate tap/aggregate/I/O resources.

Update `AppDelegate` subscriptions to combine HRIR activation/error and EQ
selection/preparation state. Preserve stale-generation suppression and do not
create a parallel runtime state machine inside either manager.

**Verify**: controller tests cover all four readiness rows, EQ changes with no
platform resource events, and HRIR changes retaining current cleanup behavior.

### Step 3: Handle sole-EQ activation and deactivation

When moving from neither effect to EQ-only, prepare the graph with unity as the
audible old EQ state and the selected curve as target, then start the existing
pipeline. Once the tap begins reading, the processor completes its 20 ms unity
→ curve transition.

When moving from EQ-only to neither, first publish unity as the EQ target. Use
the controller's injected scheduler and generation token to stop the pipeline
after 20 ms; cancel that stop if any effect becomes ready first. Do not dispatch
or signal from the render callback. With HRIR active, EQ transitions to/from
None without any pipeline stop.

**Verify**: fake-scheduler tests prove delayed sole-effect stop, cancellation,
no duplicate pipeline, and immediate safe cleanup on sleep/termination/error.

### Step 4: Handle sample-rate incompatibility without retry loops

At output preparation, require every enabled EQ frequency to be below Nyquist.
If invalid:

- With a ready HRIR, publish EQ's line/preset-specific error, prepare EQ unity,
  and continue HRIR processing.
- With no HRIR, do not retain or start a passthrough process tap. Publish native
  passthrough/inactive guidance explaining that the preset is incompatible with
  the output sample rate.

Classify this as a stable configuration failure, not a transient HAL failure;
do not enter bounded retry. A later compatible output or a newly selected valid
preset clears the error and reconciles normally. Import remains valid because
Nyquist depends on the current output, not the text format.

**Verify**: tests cover compatible/incompatible 44.1/48/96 kHz preparations,
HRIR continuation, EQ-only native fallback, no retry scheduled, and recovery.

### Step 5: Wire production construction without widening platform authority

Construct one shared effect graph from `HRIRManager.shared` and the EQ processor
owned by `EqualizerManager.shared`; pass that graph to the existing pipeline.
Keep `AudioPlatformClient` unchanged. Update safety invariant tests to assert
no default-device or volume setter and no generic property-write capability was
introduced through the integration.

**Verify**: Runtime tests, full tests, analyze, and both safety scripts pass.

## Test plan

- `AudioEffectGraphTests`: order, bypass, mono duplication behavior inherited
  from the stereo contract, preparation, and warnings.
- Extend `AudioRuntimeControllerTests`: readiness matrix, permission probes,
  EQ live update, sole-effect delayed stop/cancellation, sleep/wake, output
  changes, invalid configuration, retry classification, and termination.
- Keep every `AudioPipelineTests` lifecycle-order assertion unchanged unless a
  new control-thread preparation event is explicitly injected before resource
  acquisition.

## Done criteria

- [ ] EQ works with HRIR None and runs after HRIR when both are selected.
- [ ] EQ preset-to-preset changes never recreate Core Audio resources.
- [ ] Neither effect leaves no long-lived Airwave tap or private aggregate.
- [ ] Invalid EQ never blocks a valid HRIR and never creates a retry loop.
- [ ] Route/volume mutation API remains impossible and all gates pass.

## STOP conditions

- Implementing live EQ changes requires mutating a processor state concurrently
  with the render thread rather than publishing a completed target.
- Sole-effect shutdown cannot be cancelled through the existing generation and
  injected scheduler pattern.
- EQ integration requires a new default-output or volume-write capability.
- Existing HRIR-only or permission-probe behavior regresses.

## Maintenance notes

Future effects should join `AudioEffectGraph` through readiness/preparation and
processing interfaces, not by adding policy to `AudioPipeline` or HAL code.
Review readiness changes against the full none/one/multiple-effects matrix.

