import AppKit
import Foundation

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
        return AudioRuntimeController(
            state: .shared,
            platform: platform,
            pipelineFactory: { AudioPipeline(platform: platform, processor: HRIRManager.shared) },
            scheduler: DispatchRuntimeScheduler()
        )
    }()

    private let state: AudioRuntimeState
    private let platform: AudioPlatformClient
    private let pipelineFactory: PipelineFactory
    private let scheduler: AudioRuntimeScheduling
    private let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    private var pipeline: AudioPipelineControlling?
    private var retryToken: AudioRuntimeCancellation?
    private var stabilityToken: AudioRuntimeCancellation?
    private var retryAttempt = 0
    private var generation = 0
    private var presetReady = false
    private var permissionGranted = false
    private var launched = false
    private var sleeping = false
    private var terminated = false

    init(
        state: AudioRuntimeState,
        platform: AudioPlatformClient,
        pipelineFactory: @escaping PipelineFactory,
        scheduler: AudioRuntimeScheduling
    ) {
        self.state = state
        self.platform = platform
        self.pipelineFactory = pipelineFactory
        self.scheduler = scheduler
    }

    func launch(presetReady: Bool, permissionGranted: Bool = true) {
        guard !launched else {
            updateReadiness(presetReady: presetReady, permissionGranted: permissionGranted)
            return
        }
        launched = true
        self.presetReady = presetReady
        self.permissionGranted = permissionGranted
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
        let changed = self.presetReady != presetReady || self.permissionGranted != permissionGranted
        self.presetReady = presetReady
        self.permissionGranted = permissionGranted
        guard changed else { return }
        guard stopForInvalidation() else { return }
        reconcile()
    }

    func presetDidChange(isReady: Bool) {
        presetReady = isReady
        guard stopForInvalidation() else { return }
        reconcile()
    }

    func presetActivationFailed(_ message: String) {
        presetReady = false
        guard stopForInvalidation() else { return }
        state.publish(.nativePassthrough(reason: message))
    }

    func retryNow() {
        retryAttempt = 0
        cancelRetry()
        // Explicit user action is permission's resume condition. Probe once; another
        // denial returns to needsPermission without scheduling an automatic loop.
        permissionGranted = true
        reconcile()
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
        guard stopForInvalidation() else { return }
        guard let output else {
            handleFailure(AudioRuntimeError.noOutputDevice, output: nil)
            return
        }
        start(on: output)
    }

    private func reconcile() {
        guard launched, !sleeping, !terminated else { return }
        guard presetReady else {
            state.publish(.needsSetup)
            return
        }
        guard permissionGranted else {
            state.publish(.needsPermission)
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
            pipeline = candidate
            state.publish(.processing, output: output)
            scheduleStabilityReset(for: currentGeneration)
        } catch {
            do { try candidate.stop() } catch {
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
        guard stopForInvalidation() else { return }
        if case AudioRuntimeError.permissionDenied = error {
            permissionGranted = false
            state.publish(.needsPermission, output: output)
            return
        }
        if case AudioRuntimeError.unsupportedOutput = error {
            state.publish(.nativePassthrough(reason: "Unsupported output. Change output in macOS Settings."), output: output)
            return
        }
        scheduleRetry(reason: failureMessage(error), output: output)
    }

    private func scheduleRetry(reason: String, output: OutputDeviceDescriptor?) {
        guard retryToken == nil, presetReady, permissionGranted, !sleeping, !terminated else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let scheduledGeneration = generation
        state.publish(.recovering(reason: "\(reason) Retrying in \(Int(delay))s."), output: output)
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

    private func failureMessage(_ error: Error) -> String {
        switch error {
        case AudioRuntimeError.noOutputDevice, AudioRuntimeError.deviceLost:
            "No usable output is currently available."
        default:
            "Audio processing stopped safely."
        }
    }
}
