import XCTest
@testable import Airwave

@MainActor
final class AudioRuntimeControllerTests: XCTestCase {
    func testLaunchWithEffectStartsOnlyUnmutedPassiveVerification() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: false)])
        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted])
        XCTAssertEqual(h.state.captureAccess, .unverified)
        XCTAssertEqual(h.player.playCount, 0)
        XCTAssertEqual(h.scheduler.scheduledCount, 0)
    }

    func testExplicitTestUsesAllProcessProbeAndOnePlayer() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.controller.requestSystemAudioAccess()

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: true)])
        XCTAssertEqual(h.pipelines.liveCount, 1)
        XCTAssertEqual(h.state.captureAccess, .checking)
        h.scheduler.runNext()
        XCTAssertEqual(h.player.playCount, 1)
    }

    func testResigningBeforeStimulusAllowsActivationReplay() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()

        h.controller.applicationWillResignActive()
        h.controller.refreshSystemAudioAccess()
        h.scheduler.runNext() // canceled pre-deactivation stimulus
        h.scheduler.runNext() // replay after activation

        XCTAssertEqual(h.player.playCount, 1)
        XCTAssertEqual(h.state.captureAccess, .checking)
    }

    func testResigningAfterReplayCancelsOldTimeoutAndAllowsSecondReplay() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.scheduler.runNext() // first stimulus

        h.controller.applicationWillResignActive()
        h.controller.refreshSystemAudioAccess()
        h.scheduler.runNext() // canceled first timeout
        h.scheduler.runNext() // second stimulus

        XCTAssertEqual(h.player.playCount, 2)
        XCTAssertEqual(h.state.captureAccess, .checking)

        h.scheduler.runNext() // second timeout
        guard case .failed = h.state.captureAccess else {
            return XCTFail("expected second test timeout")
        }
    }

    func testCaptureVerificationTimeoutMatchesProbeBudget() {
        XCTAssertEqual(AudioRuntimeController.captureVerificationTimeout, 2.5)
    }

    func testSignalPromotesToProcessingOnlyAfterVerification() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted])
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.pipelines.purposes, [.verification(includeOwnProcess: false), .processing])
        XCTAssertEqual(h.pipelines.muteBehaviors, [.unmuted, .mutedWhenTapped])
        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testReprepareAfterVerifiedCaptureRestartsProcessingWithoutProbe() {
        let h = Harness(effect: true)
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        h.pipelines.emit(.signalDetected)

        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)

        h.controller.reprepareCurrentOutput()

        XCTAssertEqual(h.pipelines.purposes, [
            .verification(includeOwnProcess: false),
            .processing,
            .processing
        ])
        XCTAssertEqual(h.state.captureAccess, .verified)
        XCTAssertEqual(h.state.status, .processing)
    }

    func testSilentExplicitTestTimesOutWithoutVerification() {
        let h = Harness()
        h.controller.launch(presetReady: false)
        h.controller.requestSystemAudioAccess()
        h.scheduler.runNext()
        h.scheduler.runNext()

        guard case .failed(let reason) = h.state.captureAccess else { return XCTFail("expected failed capture state") }
        XCTAssertTrue(reason.contains("timed out"))
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertGreaterThanOrEqual(h.player.stopCount, 1)
    }

    func testPermissionFailureDoesNotClaimGenericFailure() {
        let h = Harness()
        h.pipelines.startError = .permissionDenied
        h.controller.launch(presetReady: true)

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
    }

    func testOpeningSystemSettingsPreservesKnownPermissionFailure() {
        let h = Harness()
        h.pipelines.startError = .permissionDenied
        h.controller.launch(presetReady: true)

        h.controller.openSystemAudioRecordingSettings()

        XCTAssertEqual(h.state.captureAccess, .permissionRequired)
        XCTAssertEqual(h.state.status, .needsPermission)
    }

    func testGenericFailureIsFailedAndStaleSignalCannotVerify() {
        let h = Harness()
        h.pipelines.automaticEvent = nil
        h.controller.launch(presetReady: true)
        let old = h.pipelines.handlers[0]
        h.platform.emit(nil)
        old(.signalDetected)

        guard case .failed = h.state.captureAccess else { return XCTFail("expected failed capture state") }
        XCTAssertNotEqual(h.state.captureAccess, .verified)
    }

    func testOutputChangeSleepAndTerminationReleaseResources() {
        let h = Harness(effect: true)
        h.controller.launch(presetReady: true)
        XCTAssertEqual(h.pipelines.liveCount, 1)

        h.platform.emit(output(id: 2, name: "USB"))
        XCTAssertEqual(h.pipelines.liveCount, 1)
        h.controller.willSleep()
        XCTAssertEqual(h.pipelines.liveCount, 0)
        h.controller.didWake()
        XCTAssertEqual(h.pipelines.liveCount, 1)
        h.controller.terminate()
        XCTAssertEqual(h.pipelines.liveCount, 0)
        XCTAssertGreaterThanOrEqual(h.player.stopCount, 1)
    }
}

@MainActor
private final class Harness {
    let state = AudioRuntimeState()
    let platform = PlatformFake()
    let pipelines = PipelineFactoryFake()
    let scheduler = SchedulerFake()
    let player = PlayerFake()
    private(set) lazy var controller: AudioRuntimeController = AudioRuntimeController(
        state: state,
        platform: platform,
        pipelineFactory: { [weak self] in self?.pipelines.make() ?? PipelineFake(owner: PipelineFactoryFake()) },
        scheduler: scheduler,
        stimulusPlayer: player
    )

    init(effect: Bool = false) {
        pipelines.automaticEvent = effect ? .signalDetected : nil
    }
}

private final class PipelineFactoryFake {
    var automaticEvent: AudioCaptureVerificationEvent?
    var startError: AudioRuntimeError?
    var purposes: [AudioPipelinePurpose] = []
    var muteBehaviors: [AudioTapMuteBehavior] = []
    var handlers: [AudioCaptureVerificationHandler] = []
    var liveCount = 0

    func make() -> PipelineFake {
        PipelineFake(owner: self)
    }

    func emit(_ event: AudioCaptureVerificationEvent) { handlers.last?(event) }
}

private final class PipelineFake: AudioPipelineControlling {
    private weak var owner: PipelineFactoryFake?

    init(owner: PipelineFactoryFake) { self.owner = owner }

    func start(on output: OutputDeviceDescriptor, muteBehavior: AudioTapMuteBehavior, verificationHandler: @escaping AudioCaptureVerificationHandler) throws {
        try start(on: output, purpose: muteBehavior == .unmuted ? .verification(includeOwnProcess: true) : .processing, verificationHandler: verificationHandler)
    }

    func start(on output: OutputDeviceDescriptor, purpose: AudioPipelinePurpose, verificationHandler: @escaping AudioCaptureVerificationHandler) throws {
        guard let owner else { return }
        if let error = owner.startError { owner.startError = nil; throw error }
        owner.purposes.append(purpose)
        owner.muteBehaviors.append(purpose == .processing ? .mutedWhenTapped : .unmuted)
        owner.handlers.append(verificationHandler)
        owner.liveCount += 1
        if let event = owner.automaticEvent { verificationHandler(event) }
    }

    func stop() throws { if let owner, owner.liveCount > 0 { owner.liveCount -= 1 } }
}

private final class PlatformFake: AudioPlatformClient {
    private var outputHandler: DefaultOutputChangeHandler?
    var current = output()

    func defaultOutputDevice() throws -> OutputDeviceDescriptor { current }
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws { outputHandler = handler }
    func stopObservingDefaultOutput() { outputHandler = nil }
    func resolveOwnProcess() throws -> AudioProcessHandle { .init(value: 1) }
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle { .init(value: 1) }
    func destroyTap(_ tap: AudioTapHandle) throws {}
    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle { .init(value: 1) }
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {}
    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat { .stereo(sampleRate: 48_000) }
    func createIO(aggregate: PrivateAggregateHandle, callback: @escaping AudioIOCallback, verificationHandler: @escaping AudioCaptureVerificationHandler) throws -> AudioIOHandle { .init(value: 1) }
    func startIO(_ io: AudioIOHandle) throws {}
    func stopIO(_ io: AudioIOHandle) throws {}
    func destroyIO(_ io: AudioIOHandle) throws {}
    func openAudioCapturePermissionSettings() {}

    func emit(_ output: OutputDeviceDescriptor?) { current = output ?? current; outputHandler?(output) }
}

@MainActor
private final class SchedulerFake: AudioRuntimeScheduling {
    final class Task: AudioRuntimeCancellation {
        let action: () -> Void
        var cancelled = false
        init(_ action: @escaping () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        func run() { if !cancelled { action() } }
    }

    private(set) var tasks: [Task] = []
    var scheduledCount: Int { tasks.count }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        let task = Task { action() }
        tasks.append(task)
        return task
    }
    func runNext() { guard !tasks.isEmpty else { return }; let task = tasks.removeFirst(); task.run() }
}

@MainActor
private final class PlayerFake: AudioProbeStimulusPlaying {
    var playCount = 0
    var stopCount = 0
    func play() throws { playCount += 1 }
    func stop() { stopCount += 1 }
}

private func output(id: UInt64 = 1, name: String = "Built-in") -> OutputDeviceDescriptor {
    OutputDeviceDescriptor(id: .init(id), uid: "output-\(id)", name: name, transport: "built-in", outputChannelCount: 2, nominalSampleRate: 48_000, isVirtual: false, isAggregate: false)
}
