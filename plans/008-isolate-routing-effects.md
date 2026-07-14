# Plan 008: Isolate routing effects and virtual-output rules

Status: DONE

Add `RuntimeEnvironment.isTestHost` and skip CoreAudio listeners, diagnostics
refresh, crash recovery, permissions, and service startup in hosted XCTest
processes. Add `DeviceOutputEligibility` as the shared filter for output
fallbacks, diagnostics, Settings, and menu rendering. Exclude BlackHole,
Loopback, Soundflower, Existential Audio, and mono outputs.

Verification:

- Full build succeeds.
- Full suite executes 26 tests with zero failures.
- Hosted tests terminate without the prior coordinator/CoreAudio hang.
