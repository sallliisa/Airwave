import XCTest
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

        harness.controller.retryNow()

        XCTAssertEqual(harness.state.status, .processing)
        XCTAssertEqual(harness.pipelines.liveCount, 1)
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
        XCTAssertEqual(harness.scheduler.pendingDelays, [30])
    }

    func testPermissionDeniedThenExplicitRetryDeniedAgainDoesNotSpin() {
        let harness = Harness()
        harness.pipelines.defaultError = .permissionDenied
        harness.controller.launch(presetReady: true)

        harness.controller.retryNow()

        XCTAssertEqual(harness.state.status, .needsPermission)
        XCTAssertEqual(harness.pipelines.liveCount, 0)
        XCTAssertEqual(harness.scheduler.pendingDelays, [])
        XCTAssertEqual(harness.pipelines.startedOutputs.count, 2)
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
}

@MainActor
private final class Harness {
    let state = AudioRuntimeState()
    let platform: RuntimePlatformFake
    let pipelines = PipelineRecorder()
    let scheduler = ManualRuntimeScheduler()
    let controller: AudioRuntimeController

    init(output: OutputDeviceDescriptor = device(id: 1, name: "Built-in Output")) {
        platform = RuntimePlatformFake(output: output)
        controller = AudioRuntimeController(
            state: state,
            platform: platform,
            pipelineFactory: { [pipelines] in pipelines.make() },
            scheduler: scheduler
        )
    }
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
