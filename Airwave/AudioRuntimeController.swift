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

    private var pipeline: AudioPipelineControlling?
    private var retryToken: AudioRuntimeCancellation?
    private var stabilityToken: AudioRuntimeCancellation?
    private var retryAttempt = 0
    private var generation = 0
    private var effectReadiness = AudioRuntimeEffectReadiness(
        spatialReady: false,
        equalizerDefinition: nil
    )
    private var permissionGranted = false
    private var permissionProbeRequested = false
    private var explicitPermissionRequest = false
    private var soleEffectStopToken: AudioRuntimeCancellation?
    private var launched = false
    private var sleeping = false
    private var terminated = false

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

    func launch(presetReady: Bool, permissionGranted: Bool = true) {
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
        permissionGranted: Bool = true
    ) {
        guard !launched else {
            self.effectReadiness = effectReadiness
            updateReadiness(
                effectReadiness,
                invalidation: .spatial,
                permissionGranted: permissionGranted
            )
            return
        }
        launched = true
        self.effectReadiness = effectReadiness
        self.permissionGranted = permissionGranted
        // With no preset there would otherwise be no pipeline creation to
        // establish the current TCC state. Use the same short-lived safe probe
        // as onboarding so permission is never inferred from saved setup data.
        permissionProbeRequested = !effectReadiness.hasSelectedEffect && permissionGranted
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

    func updateReadiness(presetReady: Bool, permissionGranted: Bool) {
        updateReadiness(
            AudioRuntimeEffectReadiness(spatialReady: presetReady, equalizerDefinition: nil),
            invalidation: .spatial,
            permissionGranted: permissionGranted
        )
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
        explicitPermissionRequest = true
        permissionProbeRequested = true
        permissionGranted = true
        state.setPermissionStatus(.requesting)
        retryNow()
    }

    func openSystemAudioRecordingSettings() {
        platform.openAudioCapturePermissionSettings()
    }

    func willSleep() {
        sleeping = true
        guard stopForInvalidation() else { return }
        state.publish(.nativePassthrough(reason: "Sleeping; native audio remains active."))
    }

    func didWake() {
        guard !terminated else { return }
        sleeping = false
        reconcile()
    }

    func terminate() {
        terminated = true
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
        guard stopForInvalidation() else { return }
        guard let output else {
            handleFailure(AudioRuntimeError.noOutputDevice, output: nil)
            return
        }
        start(on: output)
    }

    private func reconcile() {
        guard launched, !sleeping, !terminated else { return }
        guard permissionGranted else {
            state.publish(.needsPermission, permission: .denied)
            return
        }
        guard effectReadiness.hasSelectedEffect || permissionProbeRequested else {
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
            start(on: output)
        } catch {
            handleFailure(error, output: nil)
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
        state.publish(.starting, output: output)
        let candidate = pipelineFactory()
        do {
            try candidate.start(on: output)
            guard currentGeneration == generation, !sleeping, !terminated else {
                do { try candidate.stop() } catch {
                    pipeline = candidate
                    scheduleCleanupRetry(error)
                }
                return
            }
            let completedPermissionProbe = permissionProbeRequested
            permissionProbeRequested = false
            explicitPermissionRequest = false
            if completedPermissionProbe && !effectReadiness.hasSelectedEffect {
                do {
                    try candidate.stop()
                    state.publish(.inactive, output: output, permission: .granted)
                } catch {
                    pipeline = candidate
                    scheduleCleanupRetry(error)
                }
                return
            }
            pipeline = candidate
            state.publish(
                .processing,
                output: output,
                warning: preparation?.equalizerWarning?.errorDescription ?? effectReadiness.spatialError,
                permission: .granted
            )
            scheduleStabilityReset(for: currentGeneration)
        } catch {
            do { try candidate.stop() } catch {
                completeExplicitPermissionRequest(after: error)
                pipeline = candidate
                scheduleCleanupRetry(error)
                return
            }
            guard currentGeneration == generation else { return }
            handleFailure(error, output: output)
        }
    }

    private func validate(_ output: OutputDeviceDescriptor) -> Bool {
        let reason: String?
        if output.isVirtual || output.isAggregate {
            reason = "Unsupported virtual or aggregate output. Change output in macOS Settings."
        } else if output.outputChannelCount != 2 {
            reason = "Airwave requires a stereo output. Change output in macOS Settings."
        } else {
            reason = nil
        }
        if let reason {
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
        guard stopForInvalidation() else { return }
        if case AudioRuntimeError.permissionDenied = error {
            permissionGranted = false
            state.publish(.needsPermission, output: output, permission: .denied)
            return
        }
        if case AudioRuntimeError.unsupportedOutput = error {
            state.publish(.nativePassthrough(reason: "Unsupported output. Change output in macOS Settings."), output: output)
            return
        }
        scheduleRetry(reason: failureMessage(error), output: output)
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
