import XCTest
import Combine
@testable import Airwave

@MainActor
final class AudioRuntimeControllerTests: XCTestCase {
    func testLaunchUsesShortSafePermissionProbeWithoutPreset() {
        let harness = Harness()
        harness.controller.launch(presetReady: false)

        XCTAssertEqual(harness.pipelines.startedOutputs.count, 1)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.state.status, .inactive)
    }

    func testTransientPermissionProbeFailureRecoversAndReleasesProbeResources() {
        let harness = Harness()
        harness.pipelines.startErrors = [.deviceLost, nil]
        harness.controller.launch(presetReady: false)

        guard case .recovering = harness.state.status else {
            return XCTFail("Expected recovering permission probe")
        }
        XCTAssertEqual(harness.scheduler.pendingDelays, [1])
        harness.scheduler.runNext()
        XCTAssertEqual(harness.state.status, .inactive)
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
    }

    func testRepeatedPermissionProbeFailuresUseCappedBackoff() {
        let harness = Harness()
        harness.pipelines.defaultError = .deviceLost
        harness.controller.launch(presetReady: false)

        var observed: [TimeInterval] = []
        for _ in 0..<7 {
            observed.append(harness.scheduler.pendingDelays.last!)
            harness.scheduler.runNext()
        }

        XCTAssertEqual(observed, [1, 2, 4, 8, 15, 15, 15])
        XCTAssertEqual(harness.scheduler.activeTaskCount, 1)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
    }

    func testReadyLaunchStartsExactlyOnceAndPublishesOutput() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)

        XCTAssertEqual(harness.pipelines.startedOutputs, [harness.platform.output])
        XCTAssertEqual(harness.state.status, .processing)
        XCTAssertEqual(harness.state.currentOutput, harness.platform.output)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testInactivePresetProbesAndKnownPermissionDenialDoesNotAcquireResources() {
        let missing = Harness()
        missing.controller.launch(presetReady: false)
        XCTAssertEqual(missing.state.status, .inactive)
        XCTAssertEqual(missing.pipelines.liveCount, 0)
        XCTAssertEqual(missing.pipelines.startedOutputs.count, 1)

        let denied = Harness()
        denied.controller.launch(presetReady: false, permissionGranted: false)
        XCTAssertEqual(denied.state.status, .needsPermission)
        XCTAssertEqual(denied.pipelines.liveCount, 0)
    }

    func testSelectingNoneStopsProcessingAndBecomesHealthyInactive() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)
        XCTAssertEqual(harness.state.status, .processing)

        harness.controller.presetDidChange(isReady: false)

        XCTAssertEqual(harness.state.status, .inactive)
        XCTAssertEqual(harness.state.currentOutput, harness.platform.output)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
    }

    func testPermissionErrorStopsCandidateAndDoesNotSpin() {
        let harness = Harness()
        harness.pipelines.startErrors = [.permissionDenied]
        harness.controller.launch(presetReady: true)

        XCTAssertEqual(harness.state.status, .needsPermission)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.scheduler.pendingDelays, [])
    }

    func testPermissionDeniedThenExplicitRetryCanStartSuccessfully() {
        let harness = Harness()
        harness.pipelines.startErrors = [.permissionDenied, nil]
        harness.controller.launch(presetReady: true)
        XCTAssertEqual(harness.state.status, .needsPermission)

        harness.controller.requestSystemAudioAccess()

        XCTAssertEqual(harness.state.status, .processing)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
    }

    func testPermissionDeniedThenExplicitRetryDeniedAgainDoesNotSpin() {
        let harness = Harness()
        harness.pipelines.defaultError = .permissionDenied
        harness.controller.launch(presetReady: true)

        harness.controller.requestSystemAudioAccess()

        XCTAssertEqual(harness.state.status, .needsPermission)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.scheduler.pendingDelays, [])
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
    }

    func testRetryNowDoesNotPublishRequestingPermissionState() {
        let harness = Harness()
        harness.pipelines.startErrors = [.permissionDenied, nil]
        harness.controller.launch(presetReady: true)
        XCTAssertEqual(harness.state.permissionStatus, .denied)
        var history: [AudioRuntimeState.PermissionStatus] = []
        let cancellable = harness.state.$permissionStatus.dropFirst().sink { history.append($0) }
        defer { cancellable.cancel() }

        harness.controller.retryNow()

        XCTAssertFalse(history.contains(.requesting))
        XCTAssertEqual(harness.state.permissionStatus, .denied)
    }

    func testExplicitPermissionRequestEndsUnknownAfterGenericFailure() {
        let harness = Harness()
        harness.controller.launch(presetReady: false, permissionGranted: false)
        harness.pipelines.startErrors = [.deviceLost]
        var history: [AudioRuntimeState.PermissionStatus] = []
        let cancellable = harness.state.$permissionStatus.dropFirst().sink { history.append($0) }
        defer { cancellable.cancel() }

        harness.controller.requestSystemAudioAccess()

        XCTAssertTrue(history.contains(.requesting))
        XCTAssertEqual(history.last, .unknown)
        XCTAssertEqual(harness.state.permissionStatus, .unknown)
        XCTAssertNotEqual(harness.state.permissionStatus, .requesting)
    }

    func testExplicitPermissionRequestEndsDeniedAfterPermissionFailure() {
        let harness = Harness()
        harness.controller.launch(presetReady: false, permissionGranted: false)
        harness.pipelines.startErrors = [.permissionDenied]
        var history: [AudioRuntimeState.PermissionStatus] = []
        let cancellable = harness.state.$permissionStatus.dropFirst().sink { history.append($0) }
        defer { cancellable.cancel() }

        harness.controller.requestSystemAudioAccess()

        XCTAssertTrue(history.contains(.requesting))
        XCTAssertEqual(history.last, .denied)
        XCTAssertEqual(harness.state.permissionStatus, .denied)
        XCTAssertNotEqual(harness.state.permissionStatus, .requesting)
    }

    func testPresetReplacementStopsOldBeforeStartingNew() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)

        harness.controller.presetDidChange(isReady: true)

        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.events.suffix(3), ["stop:1", "make:2", "start:2:Built-in Output"])
    }

    func testPresetFailureReturnsToNativePassthroughWithNoResources() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)

        harness.controller.presetActivationFailed("Bad HRIR")

        XCTAssertEqual(harness.state.status, .nativePassthrough(reason: "Bad HRIR"))
        XCTAssertEqual(harness.pipelines.liveCount, 0)
    }

    func testOutputAtoBStopsOldBeforeStartingB() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)
        let b = device(id: 2, name: "USB DAC")

        harness.platform.emit(b)

        XCTAssertEqual(harness.state.currentOutput, b)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.events.suffix(3), ["stop:1", "make:2", "start:2:USB DAC"])
        XCTAssertEqual(harness.state.permissionStatus, .granted)
    }

    func testProfilePreparationWaitsForPairBeforeStarting() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)

        harness.controller.launch(presetReady: false)

        XCTAssertEqual(preparer.preparedOutputs, [harness.platform.output])
        XCTAssertEqual(harness.pipelines.startedOutputs, [])
        XCTAssertEqual(harness.state.status, .starting)

        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))

        XCTAssertEqual(harness.pipelines.startedOutputs, [harness.platform.output])
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.state.status, .processing)
    }

    func testStaleProfilePreparationCannotStartOldOutput() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)
        harness.controller.launch(presetReady: false)
        let b = device(id: 2, name: "B")
        let c = device(id: 3, name: "C")

        harness.platform.emit(b)
        harness.platform.emit(c)
        preparer.complete(outputUID: b.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))

        XCTAssertEqual(harness.pipelines.startedOutputs, [])

        preparer.complete(outputUID: c.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))

        XCTAssertEqual(harness.pipelines.startedOutputs, [c])
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testEmptyProfilePreparationUsesProbeWithoutLeavingPipelineLive() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)
        harness.controller.launch(presetReady: false)

        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: false, equalizerDefinition: nil))

        XCTAssertEqual(harness.pipelines.startedOutputs, [harness.platform.output])
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.state.status, .inactive)
    }

    func testOutputLossDuringProfilePreparationCancelsWithoutStarting() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)
        harness.controller.launch(presetReady: false)

        harness.platform.emit(nil)
        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))

        XCTAssertGreaterThanOrEqual(preparer.cancelCount, 1)
        XCTAssertEqual(preparer.unavailableCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs, [])
    }

    func testSleepCancelsPreparationAndWakeStartsOnlyLatestPair() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)
        harness.controller.launch(presetReady: false)

        harness.controller.willSleep()
        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))
        XCTAssertEqual(harness.pipelines.startedOutputs, [])

        harness.controller.didWake()
        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))

        XCTAssertEqual(preparer.cancelCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs, [harness.platform.output])
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testCleanupFailureDefersNewProfilePreparationUntilRetry() {
        let harness = Harness()
        let preparer = RuntimeProfilePreparerFake()
        harness.controller.setProfilePreparer(preparer)
        harness.controller.launch(presetReady: false)
        preparer.complete(outputUID: harness.platform.output.uid, readiness: .init(spatialReady: true, equalizerDefinition: nil))
        harness.pipelines.stopFailuresRemaining = 1
        let a = harness.platform.output
        let b = device(id: 2, name: "B")

        harness.platform.emit(b)

        XCTAssertEqual(preparer.preparedOutputs, [a])
        XCTAssertEqual(harness.scheduler.pendingDelays, [1])

        harness.scheduler.runNext()

        XCTAssertEqual(preparer.preparedOutputs, [a, b])
    }

    func testSameOutputCallbackDoesNotRecreateLivePipeline() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)
        let events = harness.pipelines.events

        harness.platform.emit(harness.platform.output)

        XCTAssertEqual(harness.pipelines.events, events)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testTeardownFailureDoesNotStartNewPipelineUntilCleanupRetrySucceeds() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)
        harness.pipelines.stopFailuresRemaining = 1
        let b = device(id: 2, name: "B")

        harness.platform.emit(b)

        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 1)
        XCTAssertEqual(harness.scheduler.pendingDelays, [1])

        harness.scheduler.runNext()

        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.last, b)
        XCTAssertEqual(harness.pipelines.events.suffix(3), ["stop:1", "make:2", "start:2:B"])
    }

    func testRapidAtoBtoCLeavesOnlyC() {
        let harness = Harness()
        let a = harness.platform.output
        harness.controller.launch(presetReady: true)
        let b = device(id: 2, name: "B")
        let c = device(id: 3, name: "C")

        harness.platform.emit(b)
        harness.platform.emit(c)

        XCTAssertEqual(harness.state.currentOutput, c)
        XCTAssertEqual(harness.pipelines.startedOutputs, [a, b, c])
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testDisconnectThenReconnectWithNewIDCancelsStaleRetry() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)
        harness.platform.emit(nil)
        let staleRetry = harness.scheduler.lastTask
        let replacement = device(id: 9, name: "Replacement")

        harness.platform.emit(replacement)
        staleRetry?.runEvenIfCancelled()

        XCTAssertEqual(harness.state.currentOutput, replacement)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.last, replacement)
    }

    func testVirtualAggregateAndMonoBlockWithoutRetryOrTap() {
        for output in [
            device(id: 2, name: "BlackHole", virtual: true),
            device(id: 3, name: "Aggregate", aggregate: true),
            device(id: 4, name: "Mono", channels: 1)
        ] {
            let harness = Harness(output: output)
            harness.controller.launch(presetReady: true)
            guard case .nativePassthrough(let reason) = harness.state.status else {
                return XCTFail("Expected native passthrough")
            }
            XCTAssertTrue(reason.contains("macOS Settings"))
            XCTAssertEqual(harness.pipelines.startedOutputs, [])
            XCTAssertEqual(harness.scheduler.pendingDelays, [])
        }
    }

    func testRetryBackoffCapsAtFifteenSecondsWithoutStorm() {
        let harness = Harness()
        harness.pipelines.defaultError = .deviceLost
        harness.controller.launch(presetReady: true)

        var observed: [TimeInterval] = []
        for _ in 0..<7 {
            observed.append(harness.scheduler.pendingDelays.last!)
            harness.scheduler.runNext()
        }

        XCTAssertEqual(observed, [1, 2, 4, 8, 15, 15, 15])
        XCTAssertEqual(harness.scheduler.activeTaskCount, 1)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
    }

    func testStableProcessingResetsBackoffAfterThirtySeconds() {
        let harness = Harness()
        harness.pipelines.startErrors = [.deviceLost, nil]
        harness.controller.launch(presetReady: true)
        XCTAssertEqual(harness.scheduler.pendingDelays, [1])
        harness.scheduler.runNext()
        XCTAssertEqual(harness.state.status, .processing)

        harness.scheduler.run(delay: 30)
        harness.platform.emit(nil)

        XCTAssertEqual(harness.scheduler.pendingDelays.last, 1)
    }

    func testSleepTerminateReleaseEverythingAndWakeStartsOnce() {
        let harness = Harness()
        harness.controller.launch(presetReady: true)

        harness.controller.willSleep()
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertFalse(harness.state.status.isProcessing)

        harness.controller.didWake()
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)

        harness.controller.terminate()
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.platform.stopObservationCount, 1)
    }

    func testEffectReadinessMatrixStartsOnlyRunnableEffects() {
        let none = Harness(effectGraph: RuntimeEffectGraphFake(spatialReady: false))
        none.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: nil))
        XCTAssertEqual(none.pipelines.startedOutputs.count, 1)
        XCTAssertEqual(none.pipelines.liveCount, 0)
        XCTAssertEqual(none.state.status, .inactive)

        let spatial = Harness(effectGraph: RuntimeEffectGraphFake(spatialReady: true))
        spatial.controller.launch(effectReadiness: .init(spatialReady: true, equalizerDefinition: nil))
        XCTAssertEqual(spatial.pipelines.liveCount, 1)

        let equalizer = Harness(effectGraph: RuntimeEffectGraphFake(spatialReady: false))
        equalizer.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: runtimeDefinition()))
        XCTAssertEqual(equalizer.pipelines.liveCount, 1)

        let both = Harness(effectGraph: RuntimeEffectGraphFake(spatialReady: true))
        both.controller.launch(effectReadiness: .init(spatialReady: true, equalizerDefinition: runtimeDefinition()))
        XCTAssertEqual(both.pipelines.liveCount, 1)
    }

    func testEqualizerTargetChangeDoesNotRecreatePipelineResources() {
        let graph = RuntimeEffectGraphFake(spatialReady: false)
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: runtimeDefinition(gain: 3)))
        let events = harness.pipelines.events

        harness.controller.updateReadiness(
            .init(spatialReady: false, equalizerDefinition: runtimeDefinition(gain: -3)),
            invalidation: .equalizerTarget
        )

        XCTAssertEqual(harness.pipelines.events, events)
        XCTAssertEqual(graph.updatedDefinitions.count, 1)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
    }

    func testRemovingEqualizerWhileSpatialRemainsKeepsPipelineLive() {
        let graph = RuntimeEffectGraphFake(spatialReady: true)
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(
            spatialReady: true,
            equalizerDefinition: runtimeDefinition()
        ))
        let events = harness.pipelines.events

        harness.controller.updateReadiness(
            .init(spatialReady: true, equalizerDefinition: nil),
            invalidation: .equalizerTarget
        )

        XCTAssertEqual(harness.pipelines.events, events)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.state.status, .processing)
    }

    func testSoleEqualizerStopIsDelayedAndCancelledBySelection() {
        let graph = RuntimeEffectGraphFake(spatialReady: false)
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: runtimeDefinition()))

        harness.controller.updateReadiness(
            .init(spatialReady: false, equalizerDefinition: nil),
            invalidation: .equalizerTarget
        )
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.scheduler.pendingDelays, [0.020])

        harness.controller.updateReadiness(
            .init(spatialReady: false, equalizerDefinition: runtimeDefinition(gain: -3)),
            invalidation: .equalizerTarget
        )
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
        XCTAssertEqual(harness.pipelines.liveCount, 1)

        harness.controller.updateReadiness(
            .init(spatialReady: false, equalizerDefinition: nil),
            invalidation: .equalizerTarget
        )
        harness.scheduler.runNext()
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.state.status, .inactive)
    }

    func testInvalidEqualizerContinuesSpatialAndDoesNotScheduleRetry() {
        let graph = RuntimeEffectGraphFake(spatialReady: true)
        graph.warning = AudioEffectWarning(filterLine: 9, reason: "above Nyquist")
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: true, equalizerDefinition: runtimeDefinition()))

        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
        XCTAssertEqual(harness.state.warningMessage, "Equalizer line 9: above Nyquist")
    }

    func testInvalidEqualizerWithoutSpatialFallsBackNativelyWithoutRetry() {
        let graph = RuntimeEffectGraphFake(spatialReady: false)
        graph.warning = AudioEffectWarning(filterLine: 9, reason: "above Nyquist")
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: runtimeDefinition()))

        XCTAssertEqual(harness.pipelines.startedOutputs, [])
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.scheduler.pendingDelays, [])
        guard case .nativePassthrough(let reason) = harness.state.status else {
            return XCTFail("Expected native passthrough")
        }
        XCTAssertTrue(reason.contains("Nyquist"))
    }

    func testInvalidEqualizerOnlyRecoversOnValidSelectionWithoutRetry() {
        let graph = RuntimeEffectGraphFake(spatialReady: false)
        graph.warning = AudioEffectWarning(filterLine: 9, reason: "above Nyquist")
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: false, equalizerDefinition: runtimeDefinition()))
        XCTAssertEqual(harness.pipelines.startedOutputs, [])

        graph.warning = nil
        harness.controller.updateReadiness(
            .init(spatialReady: false, equalizerDefinition: runtimeDefinition(gain: -3)),
            invalidation: .equalizerTarget
        )

        XCTAssertEqual(harness.pipelines.startedOutputs.count, 1)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
        XCTAssertNil(harness.state.warningMessage)
    }

    func testSpatialContinuesThroughInvalidEqualizerAndRecoversOnCompatibleOutput() {
        let graph = RuntimeEffectGraphFake(spatialReady: true)
        graph.warning = AudioEffectWarning(filterLine: 9, reason: "above Nyquist")
        let harness = Harness(effectGraph: graph)
        harness.controller.launch(effectReadiness: .init(spatialReady: true, equalizerDefinition: runtimeDefinition()))
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertNotNil(harness.state.warningMessage)

        graph.warning = nil
        harness.platform.emit(device(id: 2, name: "Compatible DAC"))

        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertNil(harness.state.warningMessage)
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
    }

    func testAppDelegateLaunchesTheDeviceProfileCoordinator() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Airwave/AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DeviceProfileRuntimeCoordinator.shared.launch()"))
        XCTAssertFalse(source.contains("hrir.$activePreset"))
        XCTAssertFalse(source.contains("eq.$selectedDefinition"))
    }
}

@MainActor
private final class Harness {
    let state = AudioRuntimeState()
    let platform: RuntimePlatformFake
    let pipelines = PipelineRecorder()
    let scheduler = ManualRuntimeScheduler()
    let controller: AudioRuntimeController

    init(
        output: OutputDeviceDescriptor = device(id: 1, name: "Built-in Output"),
        effectGraph: AudioEffectGraphControlling? = nil
    ) {
        platform = RuntimePlatformFake(output: output)
        controller = AudioRuntimeController(
            state: state,
            platform: platform,
            pipelineFactory: { [pipelines] in pipelines.make() },
            scheduler: scheduler,
            effectGraph: effectGraph
        )
    }
}

private final class RuntimeEffectGraphFake: AudioEffectGraphControlling {
    let spatialReady: Bool
    var warning: AudioEffectWarning?
    private(set) var updatedDefinitions: [EqualizerDefinition?] = []

    init(spatialReady: Bool) {
        self.spatialReady = spatialReady
    }

    func prepare(for output: OutputDeviceDescriptor, equalizerDefinition: EqualizerDefinition?) -> AudioEffectPreparationResult {
        var effects = Set<AudioEffectKind>()
        if spatialReady { effects.insert(.spatial) }
        if equalizerDefinition != nil, warning == nil { effects.insert(.equalizer) }
        return AudioEffectPreparationResult(runnableEffects: effects, equalizerWarning: warning)
    }

    func updateEqualizer(definition: EqualizerDefinition?) -> AudioEffectPreparationResult {
        updatedDefinitions.append(definition)
        var effects = Set<AudioEffectKind>()
        if spatialReady { effects.insert(.spatial) }
        if definition != nil, warning == nil { effects.insert(.equalizer) }
        return AudioEffectPreparationResult(runnableEffects: effects, equalizerWarning: warning)
    }
}

private func runtimeDefinition(gain: Double = 6) -> EqualizerDefinition {
    EqualizerDefinition(preampDB: gain, filters: [])
}

@MainActor
private final class PipelineRecorder {
    var events: [String] = []
    var startedOutputs: [OutputDeviceDescriptor] = []
    var startErrors: [AudioRuntimeError?] = []
    var defaultError: AudioRuntimeError?
    var stopFailuresRemaining = 0
    var liveCount = 0
    private var nextID = 0

    func make() -> AudioPipelineControlling {
        nextID += 1
        events.append("make:\(nextID)")
        return PipelineFake(id: nextID, recorder: self)
    }

    func nextError() -> AudioRuntimeError? {
        if !startErrors.isEmpty { return startErrors.removeFirst() }
        return defaultError
    }
}

@MainActor
private final class PipelineFake: AudioPipelineControlling {
    let id: Int
    unowned let recorder: PipelineRecorder
    var live = false

    init(id: Int, recorder: PipelineRecorder) { self.id = id; self.recorder = recorder }

    nonisolated func start(on output: OutputDeviceDescriptor) throws {
        try MainActor.assumeIsolated {
            recorder.events.append("start:\(id):\(output.name)")
            recorder.startedOutputs.append(output)
            if let error = recorder.nextError() { throw error }
            live = true
            recorder.liveCount += 1
        }
    }

    nonisolated func stop() throws {
        try MainActor.assumeIsolated {
            guard live else { return }
            recorder.events.append("stop:\(id)")
            if recorder.stopFailuresRemaining > 0 {
                recorder.stopFailuresRemaining -= 1
                throw AudioRuntimeError.cleanupFailed("test")
            }
            live = false
            recorder.liveCount -= 1
        }
    }
}

private final class RuntimePlatformFake: AudioPlatformClient {
    var output: OutputDeviceDescriptor
    var observer: DefaultOutputChangeHandler?
    var stopObservationCount = 0

    init(output: OutputDeviceDescriptor) { self.output = output }
    func defaultOutputDevice() throws -> OutputDeviceDescriptor { output }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws { observer = handler }
    func stopObservingDefaultOutput() { stopObservationCount += 1; observer = nil }
    func emit(_ output: OutputDeviceDescriptor?) { if let output { self.output = output }; observer?(output) }
    func resolveOwnProcess() throws -> AudioProcessHandle { fatalError() }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle { fatalError() }
    func destroyTap(_ tap: AudioTapHandle) throws { fatalError() }
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle { fatalError() }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws { fatalError() }
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat { fatalError() }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat { fatalError() }
    func createIO(aggregate: PrivateAggregateHandle, callback: @escaping AudioIOCallback) throws -> AudioIOHandle { fatalError() }
    func startIO(_ io: AudioIOHandle) throws { fatalError() }
    func stopIO(_ io: AudioIOHandle) throws { fatalError() }
    func destroyIO(_ io: AudioIOHandle) throws { fatalError() }
    func openAudioCapturePermissionSettings() {}
}

@MainActor
private final class RuntimeProfilePreparerFake: OutputEffectProfilePreparing {
    private var completions: [String: (AudioRuntimeEffectReadiness) -> Void] = [:]
    private(set) var preparedOutputs: [OutputDeviceDescriptor] = []
    private(set) var cancelCount = 0
    private(set) var unavailableCount = 0

    func prepare(
        output: OutputDeviceDescriptor,
        completion: @escaping (AudioRuntimeEffectReadiness) -> Void
    ) {
        preparedOutputs.append(output)
        completions[output.uid] = completion
    }

    func complete(outputUID: String, readiness: AudioRuntimeEffectReadiness) {
        let completion = completions.removeValue(forKey: outputUID)
        completion?(readiness)
    }

    func cancelPreparation() {
        cancelCount += 1
        completions.removeAll()
    }

    func outputBecameUnsupportedOrUnavailable() {
        unavailableCount += 1
    }
}

@MainActor
private final class ManualRuntimeScheduler: AudioRuntimeScheduling {
    final class TaskToken: AudioRuntimeCancellation {
        let delay: TimeInterval
        var action: (@MainActor () -> Void)?
        var cancelled = false
        init(delay: TimeInterval, action: @escaping @MainActor () -> Void) { self.delay = delay; self.action = action }
        func cancel() { cancelled = true }
        @MainActor func runEvenIfCancelled() { let action = action; self.action = nil; action?() }
    }

    var tasks: [TaskToken] = []
    var pendingDelays: [TimeInterval] { tasks.filter { !$0.cancelled && $0.action != nil }.map(\.delay) }
    var activeTaskCount: Int { pendingDelays.count }
    var lastTask: TaskToken? { tasks.last }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        let task = TaskToken(delay: delay, action: action)
        tasks.append(task)
        return task
    }

    func runNext() {
        guard let task = tasks.first(where: { !$0.cancelled && $0.action != nil }) else { return }
        task.runEvenIfCancelled()
    }

    func run(delay: TimeInterval) {
        tasks.first(where: { !$0.cancelled && $0.action != nil && $0.delay == delay })?.runEvenIfCancelled()
    }
}

private func device(
    id: UInt64, name: String, channels: Int = 2,
    virtual: Bool = false, aggregate: Bool = false
) -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(
        id: .init(id), uid: "uid-\(id)", name: name, transport: virtual ? "virt" : "built",
        outputChannelCount: channels, nominalSampleRate: 48_000,
        isVirtual: virtual, isAggregate: aggregate
    )
}
