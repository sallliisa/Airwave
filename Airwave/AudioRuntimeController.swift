import AppKit
import Foundation

nonisolated struct AudioRuntimeEffectReadiness: Equatable, Sendable {
    let spatialReady: Bool
    let equalizerDefinition: EqualizerDefinition?
    let spatialError: String?

    init(
        spatialReady: Bool,
        equalizerDefinition: EqualizerDefinition?,
        spatialError: String? = nil
    ) {
        self.spatialReady = spatialReady
        self.equalizerDefinition = equalizerDefinition
        self.spatialError = spatialError
    }

    var hasSelectedEffect: Bool {
        spatialReady || equalizerDefinition != nil
    }
}

nonisolated enum AudioRuntimeInvalidation {
    case spatial
    case equalizerTarget
    case output
}

@MainActor
protocol OutputEffectProfilePreparing: AnyObject {
    func prepare(
        output: OutputDeviceDescriptor,
        completion: @escaping (AudioRuntimeEffectReadiness) -> Void
    )
    func cancelPreparation()
    func outputBecameUnsupportedOrUnavailable()
}

@MainActor
protocol AudioRuntimeScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AudioRuntimeCancellation
}

protocol AudioRuntimeCancellation: AnyObject {
    func cancel()
}

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

/// Owns runtime policy and is the sole publisher of audio runtime state.
@MainActor
final class AudioRuntimeController {
    typealias PipelineFactory = () -> AudioPipelineControlling

    static let shared: AudioRuntimeController = {
        let platform = CoreAudioPlatformClient()
        let effectGraph = AudioEffectGraph(
            spatial: HRIRManager.shared,
            equalizer: EqualizerManager.shared.runtimeEffect
        )
        return AudioRuntimeController(
            state: .shared,
            platform: platform,
            pipelineFactory: { AudioPipeline(platform: platform, processor: effectGraph) },
            scheduler: DispatchRuntimeScheduler(),
            effectGraph: effectGraph
        )
    }()

    private let state: AudioRuntimeState
    private let platform: AudioPlatformClient
    private let pipelineFactory: PipelineFactory
    private let scheduler: AudioRuntimeScheduling
    private let effectGraph: AudioEffectGraphControlling?
    private let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]
    private let permissionVerificationTimeout: TimeInterval = 5

    private var pipeline: AudioPipelineControlling?
    private var retryToken: AudioRuntimeCancellation?
    private var stabilityToken: AudioRuntimeCancellation?
    private var permissionVerificationToken: AudioRuntimeCancellation?
    private var retryAttempt = 0
    private var generation = 0
    private var effectReadiness = AudioRuntimeEffectReadiness(
        spatialReady: false,
        equalizerDefinition: nil
    )
    private var permissionGranted = false
    private var permissionProbeRequested = false
    private var explicitPermissionRequest = false
    private var permissionRequestGeneration = 0
    private var captureVerified = false
    private var soleEffectStopToken: AudioRuntimeCancellation?
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
        effectGraph: AudioEffectGraphControlling? = nil
    ) {
        self.state = state
        self.platform = platform
        self.pipelineFactory = pipelineFactory
        self.scheduler = scheduler
        self.effectGraph = effectGraph
    }

    func setProfilePreparer(_ preparer: (any OutputEffectProfilePreparing)?) {
        profilePreparer = preparer
    }

    func reprepareCurrentOutput() {
        guard launched, !sleeping, !terminated else { return }
        guard stopForInvalidation() else { return }
        hasPreparedDesiredOutput = false
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

    func launch(presetReady: Bool, permissionGranted: Bool? = nil) {
        launch(
            effectReadiness: AudioRuntimeEffectReadiness(
                spatialReady: presetReady,
                equalizerDefinition: nil
            ),
            permissionGranted: permissionGranted
        )
    }

    func launch(
        effectReadiness: AudioRuntimeEffectReadiness,
        permissionGranted: Bool? = nil
    ) {
        guard !launched else {
            self.effectReadiness = effectReadiness
            updateReadiness(
                effectReadiness,
                invalidation: .spatial,
                permissionGranted: permissionGranted ?? self.permissionGranted
            )
            return
        }
        launched = true
        self.effectReadiness = effectReadiness
        let initialPermission = permissionGranted.map {
            $0 ? SystemAudioPermissionStatus.granted : .denied
        } ?? platform.systemAudioPermissionStatus()
        self.permissionGranted = initialPermission == .granted
        state.setPermissionStatus(permissionState(for: initialPermission))
        permissionProbeRequested = self.permissionGranted && !effectReadiness.hasSelectedEffect
        do {
            try platform.observeDefaultOutput { [weak self] output in
                // AudioPlatformClient installs this observer on the main queue.
                MainActor.assumeIsolated { self?.defaultOutputChanged(output) }
            }
        } catch {
            handleFailure(error, output: nil)
            return
        }
        reconcile()
    }

    func updateReadiness(
        _ effectReadiness: AudioRuntimeEffectReadiness,
        invalidation: AudioRuntimeInvalidation
    ) {
        updateReadiness(effectReadiness, invalidation: invalidation, permissionGranted: permissionGranted)
    }

    private func updateReadiness(
        _ effectReadiness: AudioRuntimeEffectReadiness,
        invalidation: AudioRuntimeInvalidation,
        permissionGranted: Bool
    ) {
        let changed = self.effectReadiness != effectReadiness || self.permissionGranted != permissionGranted
        self.effectReadiness = effectReadiness
        self.permissionGranted = permissionGranted
        guard changed else { return }

        cancelSoleEffectStop()
        if invalidation == .equalizerTarget,
           launched,
           !sleeping,
           !terminated,
           let effectGraph,
           pipeline != nil {
            stabilityToken?.cancel()
            stabilityToken = nil
            let result = effectGraph.updateEqualizer(definition: effectReadiness.equalizerDefinition)
            handleLiveEffectUpdate(result)
            return
        }
        guard stopForInvalidation() else { return }
        reconcile()
    }

    func presetDidChange(isReady: Bool) {
        effectReadiness = AudioRuntimeEffectReadiness(
            spatialReady: isReady,
            equalizerDefinition: effectReadiness.equalizerDefinition
        )
        guard launched else { return }
        guard stopForInvalidation() else { return }
        reconcile()
    }

    func presetActivationFailed(_ message: String) {
        if effectGraph == nil {
            effectReadiness = AudioRuntimeEffectReadiness(spatialReady: false, equalizerDefinition: nil)
            guard stopForInvalidation() else { return }
            state.publish(.nativePassthrough(reason: message))
            return
        }
        updateReadiness(
            AudioRuntimeEffectReadiness(
                spatialReady: false,
                equalizerDefinition: effectReadiness.equalizerDefinition,
                spatialError: message
            ),
            invalidation: .spatial
        )
    }

    func retryNow() {
        retryAttempt = 0
        cancelRetry()
        reconcile()
    }

    /// Performs the same safe tap setup used for processing, but permits a
    /// short native-passthrough probe before an HRIR preset has been selected.
    func requestSystemAudioAccess() {
        guard !explicitPermissionRequest else { return }
        guard launched, !sleeping, !terminated else { return }
        guard stopForInvalidation() else { return }
        explicitPermissionRequest = true
        permissionProbeRequested = false
        permissionGranted = false
        permissionRequestGeneration += 1
        let requestGeneration = permissionRequestGeneration
        state.setPermissionStatus(.checking)
        state.setTapHealth(.idle)
        retryAttempt = 0
        platform.requestSystemAudioPermission { [weak self] result in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.permissionRequestCompleted(result, generation: requestGeneration)
                }
            } else {
                DispatchQueue.main.async {
                    self?.permissionRequestCompleted(result, generation: requestGeneration)
                }
            }
        }
    }

    func refreshSystemAudioAccess() {
        guard launched, !sleeping, !terminated, !explicitPermissionRequest else { return }
        let result = platform.systemAudioPermissionStatus()
        let nextPermission = permissionState(for: result)
        guard nextPermission != state.permissionStatus else { return }
        guard stopForInvalidation() else { return }
        permissionGranted = result == .granted
        state.setPermissionStatus(nextPermission)
        if permissionGranted {
            permissionProbeRequested = !effectReadiness.hasSelectedEffect
            state.setTapHealth(.checking)
            reconcile()
        } else {
            permissionProbeRequested = false
            state.publish(
                .needsPermission,
                output: state.currentOutput,
                permission: nextPermission,
                tapHealth: result == .unknown
                    ? .failed(reason: "Airwave could not verify System Audio Capture permission.")
                    : .idle
            )
        }
    }

    private func permissionRequestCompleted(
        _ result: SystemAudioPermissionStatus,
        generation requestGeneration: Int
    ) {
        guard explicitPermissionRequest,
              requestGeneration == permissionRequestGeneration,
              !sleeping,
              !terminated else { return }
        explicitPermissionRequest = false
        permissionGranted = result == .granted
        let permission = permissionState(for: result)
        state.setPermissionStatus(permission)
        guard permissionGranted else {
            permissionProbeRequested = false
            state.publish(
                .needsPermission,
                output: state.currentOutput,
                permission: permission,
                tapHealth: result == .unknown
                    ? .failed(reason: "Airwave could not verify System Audio Capture permission.")
                    : .idle
            )
            return
        }
        permissionProbeRequested = !effectReadiness.hasSelectedEffect
        state.setTapHealth(.checking)
        reconcile()
    }

    private func permissionState(
        for status: SystemAudioPermissionStatus
    ) -> AudioRuntimeState.PermissionStatus {
        switch status {
        case .unknown: .unknown
        case .denied: .denied
        case .granted: .granted
        }
    }

    private func cancelPendingPermissionRequest() {
        guard explicitPermissionRequest else { return }
        permissionRequestGeneration += 1
        explicitPermissionRequest = false
        permissionProbeRequested = false
        permissionGranted = false
        state.setPermissionStatus(.unknown)
        state.setTapHealth(.idle)
    }

    func openSystemAudioRecordingSettings() {
        platform.openAudioCapturePermissionSettings()
    }

    func willSleep() {
        sleeping = true
        cancelPendingPermissionRequest()
        guard stopForInvalidation() else { return }
        state.publish(.nativePassthrough(reason: "Sleeping; native audio remains active."))
    }

    func didWake() {
        guard !terminated else { return }
        sleeping = false
        let permission = platform.systemAudioPermissionStatus()
        permissionGranted = permission == .granted
        state.setPermissionStatus(permissionState(for: permission))
        permissionProbeRequested = permissionGranted && !effectReadiness.hasSelectedEffect
        reconcile()
    }

    func terminate() {
        terminated = true
        cancelPendingPermissionRequest()
        platform.stopObservingDefaultOutput()
        _ = stopForInvalidation()
        state.publish(.unavailable("Airwave stopped"))
    }

    private func defaultOutputChanged(_ output: OutputDeviceDescriptor?) {
        guard launched, !sleeping, !terminated else { return }
        if let output,
           output == state.currentOutput,
           pipeline != nil,
           state.status == .processing {
            return
        }
        if let output {
            desiredOutput = output
            hasPreparedDesiredOutput = false
            permissionProbeRequested = state.permissionStatus == .granted
                && !effectReadiness.hasSelectedEffect
        }
        guard stopForInvalidation() else { return }
        guard let output else {
            desiredOutput = nil
            hasPreparedDesiredOutput = false
            profilePreparer?.outputBecameUnsupportedOrUnavailable()
            handleFailure(AudioRuntimeError.noOutputDevice, output: nil)
            return
        }
        transition(to: output)
    }

    private func reconcile() {
        guard launched, !sleeping, !terminated else { return }
        guard permissionGranted, state.permissionStatus == .granted else {
            state.publish(.needsPermission, permission: state.permissionStatus)
            return
        }
        if let desiredOutput, hasPreparedDesiredOutput {
            guard effectReadiness.hasSelectedEffect || permissionProbeRequested else {
                publishInactive(output: desiredOutput)
                return
            }
            start(on: desiredOutput)
            return
        }
        guard profilePreparer != nil || effectReadiness.hasSelectedEffect || permissionProbeRequested else {
            // Selecting None intentionally stops processing, but it does not
            // invalidate the permission result or the supported output that
            // the running pipeline just proved. Keep that live runtime context
            // so product surfaces do not fall back to an unverified state.
            if let spatialError = effectReadiness.spatialError {
                state.publish(.nativePassthrough(reason: spatialError), output: state.currentOutput)
            } else {
                state.publish(.inactive, output: state.currentOutput)
            }
            return
        }
        do {
            let output = try platform.defaultOutputDevice()
            transition(to: output)
        } catch {
            handleFailure(error, output: nil)
        }
    }

    private func transition(to output: OutputDeviceDescriptor) {
        guard validate(output) else {
            desiredOutput = nil
            hasPreparedDesiredOutput = false
            profilePreparer?.outputBecameUnsupportedOrUnavailable()
            return
        }
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
            guard let self,
                  preparationGeneration == self.generation,
                  self.desiredOutput?.uid == output.uid,
                  !self.sleeping,
                  !self.terminated else { return }
            self.effectReadiness = readiness
            self.hasPreparedDesiredOutput = true
            if readiness.hasSelectedEffect {
                self.permissionProbeRequested = false
            }
            guard readiness.hasSelectedEffect || self.permissionProbeRequested else {
                self.publishInactive(output: output)
                return
            }
            self.start(on: output)
        }
    }

    private func publishInactive(output: OutputDeviceDescriptor) {
        if let spatialError = effectReadiness.spatialError {
            state.publish(.nativePassthrough(reason: spatialError), output: output)
        } else {
            state.publish(.inactive, output: output)
        }
    }

    private func start(on output: OutputDeviceDescriptor) {
        guard validate(output) else { return }
        let preparation: AudioEffectPreparationResult?
        if let effectGraph {
            let result = effectGraph.prepare(
                for: output,
                equalizerDefinition: effectReadiness.equalizerDefinition
            )
            guard !result.noEffectCanRun || permissionProbeRequested else {
                let reason = result.equalizerWarning?.errorDescription
                    ?? effectReadiness.spatialError
                    ?? "No compatible audio effect is available for this output."
                state.publish(.nativePassthrough(reason: reason), output: output)
                return
            }
            preparation = result
        } else {
            preparation = nil
        }
        let currentGeneration = generation
        let startWarning = preparation?.equalizerWarning?.errorDescription ?? effectReadiness.spatialError
        state.publish(.starting, output: output, tapHealth: .checking)
        let candidate = pipelineFactory()
        pipeline = candidate
        do {
            try candidate.start(
                on: output,
                muteBehavior: permissionProbeRequested ? .unmuted : .mutedWhenTapped
            ) { [weak self] event in
                guard let self else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.handleCaptureVerification(
                            event,
                            generation: currentGeneration,
                            output: output,
                            warning: startWarning
                        )
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.handleCaptureVerification(
                            event,
                            generation: currentGeneration,
                            output: output,
                            warning: startWarning
                        )
                    }
                }
            }
            guard currentGeneration == generation, !sleeping, !terminated else {
                do { try candidate.stop() } catch {
                    pipeline = candidate
                    scheduleCleanupRetry(error)
                }
                return
            }
            guard !captureVerified else { return }
            state.publish(
                .starting,
                output: output,
                warning: startWarning,
                permission: nil,
                tapHealth: .checking
            )
            schedulePermissionVerificationTimeout(generation: currentGeneration, output: output)
        } catch {
            do { try candidate.stop() } catch {
                completeExplicitPermissionRequest(after: error)
                pipeline = candidate
                scheduleCleanupRetry(error)
                return
            }
            pipeline = nil
            guard currentGeneration == generation else { return }
            handleFailure(error, output: output)
        }
    }

    private func handleCaptureVerification(
        _ event: AudioCaptureVerificationEvent,
        generation eventGeneration: Int,
        output: OutputDeviceDescriptor,
        warning: String?
    ) {
        guard eventGeneration == generation, pipeline != nil, !captureVerified else { return }
        switch event {
        case .tapReady:
            captureVerified = true
            permissionVerificationToken?.cancel()
            permissionVerificationToken = nil
            let completedProbe = permissionProbeRequested && !effectReadiness.hasSelectedEffect
            permissionProbeRequested = false
            explicitPermissionRequest = false
            if completedProbe {
                do {
                    try pipeline?.stop()
                    pipeline = nil
                    state.publish(.inactive, output: output, permission: .granted, tapHealth: .ready)
                } catch {
                    scheduleCleanupRetry(error)
                }
            } else {
                state.publish(.processing, output: output, warning: warning, permission: .granted, tapHealth: .ready)
                scheduleStabilityReset(for: eventGeneration)
            }
        case .permissionDenied:
            handleFailure(AudioRuntimeError.permissionDenied, output: output)
        case .renderFailed(let status):
            handleFailure(
                AudioRuntimeError.ioStartFailed("Render system audio failed (OSStatus \(status))"),
                output: output
            )
        }
    }

    private func schedulePermissionVerificationTimeout(
        generation timeoutGeneration: Int,
        output: OutputDeviceDescriptor
    ) {
        permissionVerificationToken?.cancel()
        permissionVerificationToken = scheduler.schedule(after: permissionVerificationTimeout) { [weak self] in
            guard let self,
                  timeoutGeneration == self.generation,
                  !self.captureVerified else { return }
            self.permissionVerificationToken = nil
            self.permissionProbeRequested = false
            self.explicitPermissionRequest = false
            do {
                try self.pipeline?.stop()
                self.pipeline = nil
                let guidance = "Audio tap did not start responding. Retry setup."
                if self.effectReadiness.hasSelectedEffect {
                    self.state.publish(
                        .nativePassthrough(reason: guidance),
                        output: output,
                        permission: nil,
                        tapHealth: .failed(reason: guidance)
                    )
                } else {
                    self.state.publish(
                        .inactive,
                        output: output,
                        warning: guidance,
                        permission: nil,
                        tapHealth: .failed(reason: guidance)
                    )
                }
            } catch {
                self.scheduleCleanupRetry(error)
            }
        }
    }

    private func validate(_ output: OutputDeviceDescriptor) -> Bool {
        if let reason = output.unsupportedProfileReason {
            state.publish(.nativePassthrough(reason: reason), output: output)
            return false
        }
        return true
    }

    private func handleFailure(_ error: Error, output: OutputDeviceDescriptor?) {
        let explicitRequest = explicitPermissionRequest
        Logger.log(
            "[AudioRuntime] failure=\(error) outputUID=\(output?.uid ?? state.currentOutput?.uid ?? "<none>") outputName=\(output?.name ?? state.currentOutput?.name ?? "<none>") explicitPermissionRequest=\(explicitRequest)"
        )
        completeExplicitPermissionRequest(after: error)
        permissionVerificationToken?.cancel()
        permissionVerificationToken = nil
        guard stopForInvalidation() else { return }
        if case AudioRuntimeError.permissionDenied = error {
            permissionGranted = false
            state.publish(
                .needsPermission,
                output: output,
                permission: .denied,
                tapHealth: .failed(reason: "System Audio Capture permission blocked audio tap verification.")
            )
            return
        }
        if case AudioRuntimeError.unsupportedOutput = error {
            state.publish(.nativePassthrough(reason: "Unsupported output. Change output in macOS Settings."), output: output)
            return
        }
        let message = failureMessage(error)
        if explicitRequest || permissionProbeRequested || !effectReadiness.hasSelectedEffect || isTapHealthFailure(error) {
            permissionProbeRequested = false
            state.publish(
                .nativePassthrough(reason: message),
                output: output,
                permission: state.permissionStatus == .granted ? nil : .unknown,
                tapHealth: .failed(reason: message)
            )
            return
        }
        state.setTapHealth(.checking)
        scheduleRetry(reason: message, output: output)
    }

    private func isTapHealthFailure(_ error: Error) -> Bool {
        guard let runtimeError = error as? AudioRuntimeError else { return false }
        switch runtimeError {
        case .tapCreationFailed, .aggregateCreationFailed, .formatMismatch,
             .ioCreationFailed, .ioStartFailed:
            return true
        case .permissionDenied, .noOutputDevice, .unsupportedOutput, .deviceLost, .cleanupFailed:
            return false
        }
    }

    private func completeExplicitPermissionRequest(after error: Error) {
        guard explicitPermissionRequest else { return }
        explicitPermissionRequest = false
        permissionProbeRequested = false
        if case AudioRuntimeError.permissionDenied = error {
            state.setPermissionStatus(.denied)
        } else {
            state.setPermissionStatus(.unknown)
        }
    }

    private func scheduleRetry(reason: String, output: OutputDeviceDescriptor?) {
        guard retryToken == nil,
              effectReadiness.hasSelectedEffect || permissionProbeRequested,
              permissionGranted, !sleeping, !terminated else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let scheduledGeneration = generation
        let permission: AudioRuntimeState.PermissionStatus? = state.permissionStatus == .granted
            ? nil
            : .unknown
        state.publish(
            .recovering(reason: "\(reason) Retrying in \(Int(delay))s."),
            output: output,
            permission: permission
        )
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, scheduledGeneration == self.generation else { return }
            self.retryToken = nil
            self.reconcile()
        }
    }

    private func scheduleStabilityReset(for generation: Int) {
        stabilityToken?.cancel()
        stabilityToken = scheduler.schedule(after: 30) { [weak self] in
            guard let self, generation == self.generation, self.state.status.isProcessing else { return }
            self.retryAttempt = 0
            self.stabilityToken = nil
        }
    }

    private func stopForInvalidation() -> Bool {
        generation += 1
        captureVerified = false
        permissionVerificationToken?.cancel()
        permissionVerificationToken = nil
        profilePreparer?.cancelPreparation()
        cancelRetry()
        cancelSoleEffectStop()
        stabilityToken?.cancel()
        stabilityToken = nil
        if let pipeline {
            do {
                try pipeline.stop()
                self.pipeline = nil
            } catch {
                scheduleCleanupRetry(error)
                return false
            }
        }
        return true
    }

    private func scheduleCleanupRetry(_ error: Error) {
        guard retryToken == nil else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let cleanupGeneration = generation
        state.publish(.recovering(reason: "Releasing audio resources. Retrying in \(Int(delay))s."))
        retryToken = scheduler.schedule(after: delay) { [weak self] in
            guard let self, cleanupGeneration == self.generation else { return }
            self.retryToken = nil
            guard self.stopForInvalidation() else { return }
            if !self.sleeping && !self.terminated { self.reconcile() }
        }
    }

    private func cancelRetry() {
        retryToken?.cancel()
        retryToken = nil
    }

    private func cancelSoleEffectStop() {
        soleEffectStopToken?.cancel()
        soleEffectStopToken = nil
    }

    private func handleLiveEffectUpdate(_ result: AudioEffectPreparationResult) {
        let output = state.currentOutput
        if result.noEffectCanRun {
            if !effectReadiness.spatialReady {
                state.publish(
                    .nativePassthrough(
                        reason: result.equalizerWarning?.errorDescription
                            ?? "No compatible audio effect is available for this output."
                    ),
                    output: output
                )
                scheduleSoleEffectStop()
            }
            return
        }

        state.publish(
            .processing,
            output: output,
            warning: result.equalizerWarning?.errorDescription ?? effectReadiness.spatialError
        )
        scheduleStabilityReset(for: generation)
    }

    private func scheduleSoleEffectStop() {
        cancelSoleEffectStop()
        let scheduledGeneration = generation
        soleEffectStopToken = scheduler.schedule(after: 0.020) { [weak self] in
            guard let self,
                  scheduledGeneration == self.generation,
                  !self.effectReadiness.hasSelectedEffect,
                  !self.sleeping,
                  !self.terminated else { return }
            self.soleEffectStopToken = nil
            guard self.stopForInvalidation() else { return }
            self.reconcile()
        }
    }

    private func failureMessage(_ error: Error) -> String {
        switch error {
        case AudioRuntimeError.noOutputDevice, AudioRuntimeError.deviceLost:
            "No usable output is currently available."
        default:
            "Audio processing stopped safely."
        }
    }
}

extension AudioRuntimeController: AudioRuntimeUserActions {}
