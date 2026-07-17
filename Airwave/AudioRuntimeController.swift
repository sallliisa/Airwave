import AppKit
import Foundation

nonisolated struct AudioRuntimeEffectReadiness: Equatable, Sendable {
    let spatialReady: Bool
    let equalizerDefinition: EqualizerDefinition?
    let spatialError: String?

    init(spatialReady: Bool, equalizerDefinition: EqualizerDefinition?, spatialError: String? = nil) {
        self.spatialReady = spatialReady
        self.equalizerDefinition = equalizerDefinition
        self.spatialError = spatialError
    }

    var hasSelectedEffect: Bool { spatialReady || equalizerDefinition != nil }
}

nonisolated enum AudioRuntimeInvalidation { case spatial, equalizerTarget, output }

@MainActor
protocol OutputEffectProfilePreparing: AnyObject {
    func prepare(output: OutputDeviceDescriptor, completion: @escaping (AudioRuntimeEffectReadiness) -> Void)
    func cancelPreparation()
    func outputBecameUnsupportedOrUnavailable()
}

@MainActor
protocol AudioRuntimeScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation
}

protocol AudioRuntimeCancellation: AnyObject { func cancel() }

@MainActor
private final class DispatchRuntimeScheduler: AudioRuntimeScheduling {
    private final class Token: AudioRuntimeCancellation {
        var workItem: DispatchWorkItem?
        func cancel() { workItem?.cancel(); workItem = nil }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation {
        let token = Token()
        let item = DispatchWorkItem {
            guard token.workItem != nil else { return }
            Task { @MainActor in action() }
        }
        token.workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }
}

@MainActor
final class AudioRuntimeController {
    typealias PipelineFactory = () -> AudioPipelineControlling
    static let captureVerificationTimeout: TimeInterval = 2.5

    static let shared: AudioRuntimeController = {
        let platform = CoreAudioPlatformClient()
        let graph = AudioEffectGraph(spatial: HRIRManager.shared, equalizer: EqualizerManager.shared.runtimeEffect)
        return AudioRuntimeController(
            state: .shared,
            platform: platform,
            pipelineFactory: { AudioPipeline(platform: platform, processor: graph) },
            scheduler: DispatchRuntimeScheduler(),
            effectGraph: graph,
            stimulusPlayer: AVAudioProbeStimulusPlayer()
        )
    }()

    private let state: AudioRuntimeState
    private let platform: AudioPlatformClient
    private let pipelineFactory: PipelineFactory
    private let scheduler: AudioRuntimeScheduling
    private let effectGraph: AudioEffectGraphControlling?
    private let stimulusPlayer: AudioProbeStimulusPlaying
    private let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    private var pipeline: AudioPipelineControlling?
    private var retryToken: AudioRuntimeCancellation?
    private var stabilityToken: AudioRuntimeCancellation?
    private var stimulusToken: AudioRuntimeCancellation?
    private var verificationTimeoutToken: AudioRuntimeCancellation?
    private var retryAttempt = 0
    private var generation = 0
    private var effectReadiness = AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
    private var captureVerified = false
    private var captureProbeRequested = false
    private var explicitCaptureTest = false
    private var replayedAfterActivation = false
    private var appIsActive = true
    private var launched = false
    private var sleeping = false
    private var terminated = false
    private weak var profilePreparer: (any OutputEffectProfilePreparing)?
    private var desiredOutput: OutputDeviceDescriptor?
    private var hasPreparedDesiredOutput = false

    init(
        state: AudioRuntimeState,
        platform: AudioPlatformClient,
        pipelineFactory: @escaping PipelineFactory,
        scheduler: AudioRuntimeScheduling,
        effectGraph: AudioEffectGraphControlling? = nil,
        stimulusPlayer: AudioProbeStimulusPlaying? = nil
    ) {
        self.state = state
        self.platform = platform
        self.pipelineFactory = pipelineFactory
        self.scheduler = scheduler
        self.effectGraph = effectGraph
        self.stimulusPlayer = stimulusPlayer ?? AVAudioProbeStimulusPlayer()
    }

    func setProfilePreparer(_ preparer: (any OutputEffectProfilePreparing)?) { profilePreparer = preparer }

    func launch(presetReady: Bool, captureVerified: Bool? = nil) {
        launch(
            effectReadiness: AudioRuntimeEffectReadiness(spatialReady: presetReady, equalizerDefinition: nil),
            captureVerified: captureVerified
        )
    }

    func launch(effectReadiness: AudioRuntimeEffectReadiness, captureVerified: Bool? = nil) {
        guard !launched else {
            self.effectReadiness = effectReadiness
            if let captureVerified { self.captureVerified = captureVerified }
            reconcile()
            return
        }
        launched = true
        self.effectReadiness = effectReadiness
        self.captureVerified = captureVerified == true
        state.setCaptureAccess(self.captureVerified ? .verified : .unverified)
        do {
            try platform.observeDefaultOutput { [weak self] output in
                MainActor.assumeIsolated { self?.defaultOutputChanged(output) }
            }
        } catch {
            handleFailure(error, output: nil)
            return
        }
        if effectReadiness.hasSelectedEffect && !self.captureVerified { captureProbeRequested = true }
        reconcile()
    }

    func updateReadiness(_ effectReadiness: AudioRuntimeEffectReadiness, invalidation: AudioRuntimeInvalidation) {
        let changed = self.effectReadiness != effectReadiness
        self.effectReadiness = effectReadiness
        guard changed else { return }
        if invalidation == .equalizerTarget, let effectGraph, pipeline != nil, captureVerified {
            let result = effectGraph.updateEqualizer(definition: effectReadiness.equalizerDefinition)
            handleLiveEffectUpdate(result)
            return
        }
        guard stopForInvalidation() else { return }
        captureProbeRequested = effectReadiness.hasSelectedEffect
        reconcile()
    }

    func updateCurrentEqualizer(_ definition: EqualizerDefinition?) {
        updateReadiness(
            AudioRuntimeEffectReadiness(
                spatialReady: effectReadiness.spatialReady,
                equalizerDefinition: definition,
                spatialError: effectReadiness.spatialError
            ),
            invalidation: .equalizerTarget
        )
    }

    func reprepareCurrentOutput() {
        guard launched, !sleeping, !terminated, stopForInvalidation() else { return }
        hasPreparedDesiredOutput = false
        // Rebuilding the effect graph does not revoke capture capability. Keep
        // verified state so HRIR swaps restart processing directly instead of
        // waiting for another unrelated passive signal.
        captureProbeRequested = explicitCaptureTest || (effectReadiness.hasSelectedEffect && !captureVerified)
        reconcile()
    }

    func presetDidChange(isReady: Bool) {
        updateReadiness(
            AudioRuntimeEffectReadiness(
                spatialReady: isReady,
                equalizerDefinition: effectReadiness.equalizerDefinition
            ),
            invalidation: .spatial
        )
    }

    func presetActivationFailed(_ message: String) {
        effectReadiness = AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil, spatialError: message)
        guard stopForInvalidation() else { return }
        state.publish(.nativePassthrough(reason: message), output: state.currentOutput)
    }

    func retryNow() {
        retryAttempt = 0
        retryToken?.cancel()
        retryToken = nil
        captureProbeRequested = explicitCaptureTest || effectReadiness.hasSelectedEffect
        state.setCaptureAccess(.checking)
        reconcile()
    }

    func requestSystemAudioAccess() {
        guard launched, !sleeping, !terminated, !explicitCaptureTest else { return }
        guard stopForInvalidation() else { return }
        explicitCaptureTest = true
        captureProbeRequested = true
        captureVerified = false
        replayedAfterActivation = false
        state.setCaptureAccess(.checking)
        reconcile()
    }

    /// Activation only retries pending public behavioral verification. No status API is queried.
    func refreshSystemAudioAccess() {
        appIsActive = true
        guard explicitCaptureTest, pipeline != nil, !replayedAfterActivation else { return }
        replayedAfterActivation = true
        scheduleStimulus(for: generation)
    }

    func applicationWillResignActive() {
        appIsActive = false
        replayedAfterActivation = false
        stimulusToken?.cancel()
        stimulusToken = nil
        verificationTimeoutToken?.cancel()
        verificationTimeoutToken = nil
        stimulusPlayer.stop()
    }

    func openSystemAudioRecordingSettings() {
        platform.openAudioCapturePermissionSettings()
    }

    func willSleep() {
        sleeping = true
        guard stopForInvalidation() else { return }
        explicitCaptureTest = false
        captureProbeRequested = false
        state.publish(.nativePassthrough(reason: "Sleeping; native audio remains active."), captureAccess: .unverified)
    }

    func didWake() {
        guard !terminated else { return }
        sleeping = false
        captureVerified = false
        captureProbeRequested = effectReadiness.hasSelectedEffect
        state.setCaptureAccess(.unverified)
        reconcile()
    }

    func terminate() {
        terminated = true
        stimulusPlayer.stop()
        platform.stopObservingDefaultOutput()
        _ = stopForInvalidation()
        state.publish(.unavailable("Airwave stopped"), captureAccess: .unverified)
    }

    private func defaultOutputChanged(_ output: OutputDeviceDescriptor?) {
        guard launched, !sleeping, !terminated else { return }
        if let output, output == state.currentOutput, pipeline != nil, state.status == .processing { return }
        desiredOutput = output
        hasPreparedDesiredOutput = false
        guard stopForInvalidation() else { return }
        captureVerified = false
        captureProbeRequested = explicitCaptureTest || effectReadiness.hasSelectedEffect
        state.setCaptureAccess(.unverified)
        guard let output else {
            profilePreparer?.outputBecameUnsupportedOrUnavailable()
            handleFailure(AudioRuntimeError.noOutputDevice, output: nil)
            return
        }
        transition(to: output)
    }

    private func reconcile() {
        guard launched, !sleeping, !terminated else { return }
        if let desiredOutput, hasPreparedDesiredOutput {
            guard effectReadiness.hasSelectedEffect || captureProbeRequested else {
                publishInactive(output: desiredOutput)
                return
            }
            start(on: desiredOutput)
            return
        }
        guard profilePreparer != nil || effectReadiness.hasSelectedEffect || captureProbeRequested else {
            if let output = state.currentOutput { publishInactive(output: output) }
            else { state.publish(.inactive) }
            return
        }
        do { transition(to: try platform.defaultOutputDevice()) }
        catch { handleFailure(error, output: nil) }
    }

    private func transition(to output: OutputDeviceDescriptor) {
        guard validate(output) else { return }
        desiredOutput = output
        hasPreparedDesiredOutput = false
        guard let profilePreparer else {
            hasPreparedDesiredOutput = true
            start(on: output)
            return
        }
        let preparationGeneration = generation
        state.publish(.starting, output: output)
        profilePreparer.prepare(output: output) { [weak self] readiness in
            guard let self, preparationGeneration == self.generation,
                  self.desiredOutput?.uid == output.uid, !self.sleeping, !self.terminated else { return }
            self.effectReadiness = readiness
            self.hasPreparedDesiredOutput = true
            if readiness.hasSelectedEffect { self.captureProbeRequested = !self.captureVerified }
            guard readiness.hasSelectedEffect || self.captureProbeRequested else {
                self.publishInactive(output: output)
                return
            }
            self.start(on: output)
        }
    }

    private func publishInactive(output: OutputDeviceDescriptor) {
        if let error = effectReadiness.spatialError { state.publish(.nativePassthrough(reason: error), output: output) }
        else { state.publish(.inactive, output: output) }
    }

    private func start(on output: OutputDeviceDescriptor) {
        guard validate(output) else { return }
        let purpose: AudioPipelinePurpose = captureProbeRequested && !captureVerified
            ? .verification(includeOwnProcess: explicitCaptureTest)
            : .processing
        let preparation: AudioEffectPreparationResult?
        if let effectGraph {
            let result = effectGraph.prepare(for: output, equalizerDefinition: effectReadiness.equalizerDefinition)
            guard purpose != .processing || !result.noEffectCanRun else {
                state.publish(.nativePassthrough(reason: result.equalizerWarning?.errorDescription ?? "No compatible audio effect is available for this output."), output: output)
                return
            }
            preparation = result
        } else { preparation = nil }

        let currentGeneration = generation
        try? pipeline?.stop()
        let candidate = pipelineFactory()
        pipeline = candidate
        let captureAccess: AudioRuntimeState.CaptureAccess?
        switch purpose {
        case .verification:
            captureAccess = explicitCaptureTest ? .checking : .unverified
        case .processing:
            captureAccess = nil
        }
        state.publish(.starting, output: output, warning: preparation?.equalizerWarning?.errorDescription, captureAccess: captureAccess)
        do {
            try candidate.start(on: output, purpose: purpose) { [weak self] event in
                guard let self else { return }
                let work = { @MainActor in self.handleCaptureVerification(event, generation: currentGeneration, output: output, warning: preparation?.equalizerWarning?.errorDescription) }
                if Thread.isMainThread { MainActor.assumeIsolated { work() } }
                else { DispatchQueue.main.async(execute: work) }
            }
            guard currentGeneration == generation, !sleeping, !terminated else { try? candidate.stop(); return }
            if case .verification = purpose {
                guard !captureVerified else { return }
                state.setCaptureAccess(explicitCaptureTest ? .checking : .unverified)
                if explicitCaptureTest { scheduleStimulus(for: currentGeneration) }
            } else {
                state.publish(.processing, output: output, warning: preparation?.equalizerWarning?.errorDescription, captureAccess: .verified)
                scheduleStabilityReset(for: currentGeneration)
            }
        } catch {
            pipeline = nil
            try? candidate.stop()
            handleFailure(error, output: output)
        }
    }

    private func scheduleStimulus(for currentGeneration: Int) {
        stimulusToken?.cancel()
        stimulusToken = scheduler.schedule(after: 0.1) { [weak self] in
            guard let self, currentGeneration == self.generation, self.explicitCaptureTest, !self.sleeping, self.appIsActive else { return }
            self.stimulusToken = nil
            do { try self.stimulusPlayer.play() }
            catch { self.handleFailure(error, output: self.state.currentOutput) }
            self.scheduleVerificationTimeout(for: currentGeneration)
        }
    }

    private func scheduleVerificationTimeout(for currentGeneration: Int) {
        verificationTimeoutToken?.cancel()
        verificationTimeoutToken = scheduler.schedule(after: Self.captureVerificationTimeout) { [weak self] in
            guard let self, currentGeneration == self.generation, !self.captureVerified else { return }
            guard self.appIsActive else { return }
            self.stimulusPlayer.stop()
            self.captureProbeRequested = false
            self.explicitCaptureTest = false
            _ = self.stopForInvalidation()
            self.state.publish(.nativePassthrough(reason: "Capture test timed out. Retry the test sound."), output: self.state.currentOutput, captureAccess: .failed(reason: "Capture test timed out. Retry the test sound."))
        }
    }

    private func handleCaptureVerification(_ event: AudioCaptureVerificationEvent, generation eventGeneration: Int, output: OutputDeviceDescriptor, warning: String?) {
        guard eventGeneration == generation, pipeline != nil, !captureVerified else { return }
        switch event {
        case .signalDetected:
            captureVerified = true
            captureProbeRequested = false
            explicitCaptureTest = false
            stimulusToken?.cancel(); stimulusToken = nil
            verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
            stimulusPlayer.stop()
            guard (try? pipeline?.stop()) != nil else { handleFailure(AudioRuntimeError.cleanupFailed("Stop verification pipeline"), output: output); return }
            pipeline = nil
            state.setCaptureAccess(.verified)
            if effectReadiness.hasSelectedEffect { start(on: output) }
            else { state.publish(.inactive, output: output, captureAccess: .verified) }
        case .permissionDenied:
            handleFailure(AudioRuntimeError.permissionDenied, output: output)
        case .renderFailed(let status):
            handleFailure(AudioRuntimeError.ioStartFailed("Render system audio failed (OSStatus (status))"), output: output)
        }
    }

    private func handleFailure(_ error: Error, output: OutputDeviceDescriptor?) {
        stimulusPlayer.stop()
        verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
        stimulusToken?.cancel(); stimulusToken = nil
        _ = stopForInvalidation()
        if case AudioRuntimeError.permissionDenied = error {
            captureVerified = false
            captureProbeRequested = false
            explicitCaptureTest = false
            state.publish(.needsPermission, output: output, captureAccess: .permissionRequired)
            return
        }
        if case AudioRuntimeError.unsupportedOutput = error {
            state.publish(.nativePassthrough(reason: "Unsupported output. Change output in macOS Settings."), output: output, captureAccess: .failed(reason: "Unsupported output."))
            return
        }
        let reason = failureMessage(error)
        captureVerified = false
        captureProbeRequested = false
        explicitCaptureTest = false
        state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .failed(reason: reason))
    }

    private func validate(_ output: OutputDeviceDescriptor) -> Bool {
        guard let reason = output.unsupportedProfileReason else { return true }
        state.publish(.nativePassthrough(reason: reason), output: output, captureAccess: .failed(reason: reason))
        return false
    }

    private func stopForInvalidation() -> Bool {
        generation += 1
        verificationTimeoutToken?.cancel(); verificationTimeoutToken = nil
        stimulusToken?.cancel(); stimulusToken = nil
        stimulusPlayer.stop()
        profilePreparer?.cancelPreparation()
        retryToken?.cancel(); retryToken = nil
        stabilityToken?.cancel(); stabilityToken = nil
        guard let pipeline else { return true }
        do { try pipeline.stop(); self.pipeline = nil; return true }
        catch { scheduleCleanupRetry(error); return false }
    }

    private func scheduleRetry(reason: String, output: OutputDeviceDescriptor?) {
        guard retryToken == nil, effectReadiness.hasSelectedEffect, !sleeping, !terminated else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let retryGeneration = generation
        state.publish(.recovering(reason: "(reason) Retrying in (Int(delay))s."), output: output)
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == retryGeneration else { return }
            self.retryToken = nil; self.captureProbeRequested = true; self.reconcile()
        }
    }

    private func scheduleCleanupRetry(_ error: Error) {
        guard retryToken == nil else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let retryGeneration = generation
        state.publish(.recovering(reason: "Releasing audio resources. Retrying in (Int(delay))s."))
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == retryGeneration else { return }
            self.retryToken = nil; guard self.stopForInvalidation() else { return }; self.reconcile()
        }
    }

    private func scheduleStabilityReset(for currentGeneration: Int) {
        stabilityToken?.cancel()
        stabilityToken = scheduler.schedule(after: 30) { [weak self] in
            guard let self, self.generation == currentGeneration, self.state.status.isProcessing else { return }
            self.retryAttempt = 0; self.stabilityToken = nil
        }
    }

    private func handleLiveEffectUpdate(_ result: AudioEffectPreparationResult) {
        if result.noEffectCanRun, !effectReadiness.spatialReady {
            state.publish(.nativePassthrough(reason: result.equalizerWarning?.errorDescription ?? "No compatible audio effect is available for this output."), output: state.currentOutput)
            return
        }
        state.publish(.processing, output: state.currentOutput, warning: result.equalizerWarning?.errorDescription, captureAccess: .verified)
        scheduleStabilityReset(for: generation)
    }

    private func failureMessage(_ error: Error) -> String {
        switch error {
        case AudioRuntimeError.noOutputDevice, AudioRuntimeError.deviceLost:
            return "No usable output is currently available."
        case let error as AudioRuntimeError:
            switch error {
            case .tapCreationFailed(let reason), .aggregateCreationFailed(let reason), .ioCreationFailed(let reason), .ioStartFailed(let reason):
                return reason
            case .formatMismatch(let expected, let actual):
                return "Capture format mismatch (expected (expected), actual (actual))."
            default: return "Audio capture test failed safely."
            }
        default: return "Audio capture test failed safely."
        }
    }
}

extension AudioRuntimeController: AudioRuntimeUserActions {}
