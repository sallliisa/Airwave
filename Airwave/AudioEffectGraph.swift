import Foundation
import os

nonisolated enum AudioEffectKind: Hashable, Sendable {
    case spatial
    case equalizer
}

nonisolated struct AudioEffectWarning: Equatable, LocalizedError, Sendable {
    let filterLine: Int?
    let reason: String

    var errorDescription: String? {
        if let filterLine {
            return "Equalizer line \(filterLine): \(reason)"
        }
        return "Equalizer configuration: \(reason)"
    }
}

nonisolated struct AudioEffectPreparationResult: Equatable, Sendable {
    let runnableEffects: Set<AudioEffectKind>
    let equalizerWarning: AudioEffectWarning?

    var noEffectCanRun: Bool { runnableEffects.isEmpty }
}

nonisolated enum EqualizerAudioEffectError: Error, Equatable, LocalizedError, Sendable {
    case invalidFilter(line: Int?, reason: String)
    case invalidSampleRate
    case unavailable(String)

    var filterLine: Int? {
        if case .invalidFilter(let line, _) = self { return line }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidFilter(_, let reason): reason
        case .invalidSampleRate: "Output sample rate is invalid."
        case .unavailable(let reason): reason
        }
    }
}

nonisolated protocol AudioSpatialEffect: AnyObject {
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool
    var isReady: Bool { get }
    func cleanupAfterIOStopped()
}

extension AudioSpatialEffect { nonisolated func cleanupAfterIOStopped() {} }

nonisolated protocol AudioEqualizerEffect: AnyObject {
    /// Operates on the stereo binaural signal downstream of the spatial stage.
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    )
    func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws
    func setTarget(definition: EqualizerDefinition?) throws
    var isBypassed: Bool { get }
    func cleanupAfterIOStopped()
}

extension AudioEqualizerEffect {
    nonisolated var isBypassed: Bool { false }
    nonisolated func cleanupAfterIOStopped() {}
}

nonisolated protocol AudioEffectGraphControlling: AnyObject {
    func prepare(
        for output: OutputDeviceDescriptor,
        equalizerDefinition: EqualizerDefinition?
    ) -> AudioEffectPreparationResult
    func updateEqualizer(definition: EqualizerDefinition?) -> AudioEffectPreparationResult
}

/// Composes spatial processing and EQ while keeping resource ownership in AudioPipeline.
nonisolated final class AudioEffectGraph: StereoAudioProcessing, AudioEffectGraphControlling {
    private struct EqualizerActivation {
        var active = false
        var generation: UInt64 = 0
    }
    static let maximumCallbackFrames = ParametricEqualizerProcessor.maximumCallbackFrames

    private let spatial: any AudioSpatialEffect
    private let equalizer: any AudioEqualizerEffect
    private let spatialLeftScratch: UnsafeMutablePointer<Float>
    private let spatialRightScratch: UnsafeMutablePointer<Float>
    private let maxFramesPerCallback: Int
    private var outputHeadroom = ProcessedOutputHeadroom()
    /// Resolved per-output speaker identity of every captured channel; used to
    /// fold down before the first prepare resolves a device layout.
    private var inputSpeakers: [VirtualSpeaker] = [.FL, .FR]
    private let equalizerActiveLock = OSAllocatedUnfairLock<EqualizerActivation>(initialState: .init())
    private var audioThreadEqualizerActive = false
    private var audioThreadEqualizerGeneration: UInt64 = 0

    init(
        spatial: any AudioSpatialEffect,
        equalizer: any AudioEqualizerEffect,
        maxFramesPerCallback: Int = AudioEffectGraph.maximumCallbackFrames
    ) {
        precondition(maxFramesPerCallback > 0 && maxFramesPerCallback <= Self.maximumCallbackFrames)
        self.spatial = spatial
        self.equalizer = equalizer
        self.maxFramesPerCallback = maxFramesPerCallback
        self.spatialLeftScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.spatialRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
    }

    deinit {
        spatialLeftScratch.deallocate()
        spatialRightScratch.deallocate()
    }

    func prepare(
        for output: OutputDeviceDescriptor,
        equalizerDefinition: EqualizerDefinition?
    ) -> AudioEffectPreparationResult {
        outputHeadroom.prepare(sampleRate: output.nominalSampleRate)
        inputSpeakers = InputLayoutResolver.layout(
            channelLabels: output.channelLabels,
            channelCount: output.outputChannelCount
        ).channels
        var runnableEffects = Set<AudioEffectKind>()
        if spatial.isReady {
            runnableEffects.insert(.spatial)
        }

        do {
            try equalizer.prepare(definition: equalizerDefinition, sampleRate: output.nominalSampleRate)
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = equalizerDefinition != nil
            }
            if equalizerDefinition != nil {
                runnableEffects.insert(.equalizer)
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: nil
            )
        } catch let error as EqualizerAudioEffectError {
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = false
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(
                    filterLine: error.filterLine,
                    reason: error.errorDescription ?? "Equalizer preparation failed."
                )
            )
        } catch {
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = false
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(
                    filterLine: nil,
                    reason: error.localizedDescription
                )
            )
        }
    }

    func updateEqualizer(definition: EqualizerDefinition?) -> AudioEffectPreparationResult {
        do {
            try equalizer.setTarget(definition: definition)
            // Keep the processor in the callback path for the unity ramp when EQ is
            // removed. A later prepare(nil) bypasses it for a newly-created pipeline.
            var runnableEffects = Set<AudioEffectKind>()
            if spatial.isReady {
                runnableEffects.insert(.spatial)
            }
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = true
            }
            if definition != nil {
                runnableEffects.insert(.equalizer)
            }
            return AudioEffectPreparationResult(runnableEffects: runnableEffects, equalizerWarning: nil)
        } catch let error as EqualizerAudioEffectError {
            // The processor keeps its last working target, so the callback
            // still runs EQ. Report that target, not an empty set: an empty
            // set stops an EQ-only pipeline that still has audible output.
            var runnableEffects = Set<AudioEffectKind>([.equalizer])
            if spatial.isReady {
                runnableEffects.insert(.spatial)
            }
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = true
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(
                    filterLine: error.filterLine,
                    reason: error.errorDescription ?? "Equalizer update failed."
                )
            )
        } catch {
            var runnableEffects = Set<AudioEffectKind>([.equalizer])
            if spatial.isReady {
                runnableEffects.insert(.spatial)
            }
            equalizerActiveLock.withLock { state in
                state.generation &+= 1
                state.active = true
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(filterLine: nil, reason: error.localizedDescription)
            )
        }
    }

    // BEGIN REALTIME CALLBACK
    func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)
        var equalizerActive = audioThreadEqualizerActive
        if let published = equalizerActiveLock.withLockIfAvailable({ $0 }) {
            equalizerActive = published.active
            audioThreadEqualizerActive = published.active
            audioThreadEqualizerGeneration = published.generation
        }
        if equalizerActive {
            let spatialWroteOutput = spatial.process(
                inputChannels: inputChannels,
                inputChannelCount: inputChannelCount,
                outputLeft: spatialLeftScratch,
                outputRight: spatialRightScratch,
                frameCount: frameCount
            )
            if !spatialWroteOutput {
                StereoDownmixGains.downmix(
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    inputOffset: 0,
                    inputSpeakers: inputSpeakers,
                    outputLeft: outputLeft,
                    outputRight: outputRight,
                    frameCount: frameCount
                )
            }
            equalizer.process(
                inputLeft: spatialWroteOutput ? spatialLeftScratch : outputLeft,
                inputRight: spatialWroteOutput ? spatialRightScratch : outputRight,
                outputLeft: outputLeft,
                outputRight: outputRight,
                frameCount: frameCount
            )
            outputHeadroom.apply(
                left: outputLeft,
                right: outputRight,
                frameCount: frameCount
            )
            if equalizer.isBypassed {
                let observedGeneration = audioThreadEqualizerGeneration
                equalizerActiveLock.withLockIfAvailable { state in
                    if state.generation == observedGeneration { state.active = false }
                }
            }
            return
        }

        if spatial.process(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            outputLeft: outputLeft,
            outputRight: outputRight,
            frameCount: frameCount
        ) {
            outputHeadroom.apply(
                left: outputLeft,
                right: outputRight,
                frameCount: frameCount
            )
            return
        }

        // No effect wrote the final stream, so preserve the existing exact
        // passthrough/fold-down contract and discard any stale attenuation.
        outputHeadroom.reset()
        StereoDownmixGains.downmix(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            inputOffset: 0,
            inputSpeakers: inputSpeakers,
            outputLeft: outputLeft,
            outputRight: outputRight,
            frameCount: frameCount
        )
    }
    // END REALTIME CALLBACK

    func cleanupAfterIOStopped() {
        spatial.cleanupAfterIOStopped()
        equalizer.cleanupAfterIOStopped()
        equalizerActiveLock.withLock { state in
            state.generation &+= 1
            state.active = false
        }
        audioThreadEqualizerActive = false
        outputHeadroom.reset()
    }

}

/// Stereo-linked gain protection for processed output. Overload reduction is
/// immediate; recovery is a frame-bounded linear ramp that avoids callback-edge
/// gain steps while preserving the stereo image and waveform peaks.
nonisolated private struct ProcessedOutputHeadroom {
    private static let ceiling: Float = 0.98
    private static let recoverySeconds = 0.1

    private var currentGain: Float = 1
    private var recoveryGainPerFrame: Float = 1 / (48_000 * Float(recoverySeconds))

    mutating func prepare(sampleRate: Double) {
        currentGain = 1
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        recoveryGainPerFrame = Float(1 / (rate * Double(Self.recoverySeconds)))
    }

    mutating func reset() {
        currentGain = 1
    }

    mutating func apply(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var peak: Float = 0
        for index in 0..<frameCount {
            let leftMagnitude = abs(left[index])
            if leftMagnitude.isFinite && leftMagnitude > peak {
                peak = leftMagnitude
            }
            let rightMagnitude = abs(right[index])
            if rightMagnitude.isFinite && rightMagnitude > peak {
                peak = rightMagnitude
            }
        }

        // Keep a small numerical margin below the advertised ceiling so Float
        // division and multiplication cannot round a protected peak above it.
        let targetPeak = Self.ceiling.nextDown
        let safeGain = peak > Self.ceiling ? targetPeak / peak : 1
        let startGain: Float
        let targetGain: Float
        if safeGain < currentGain {
            // Reduce the whole callback immediately to keep every sample safe.
            startGain = safeGain
            targetGain = safeGain
        } else {
            let maximumRecovery = recoveryGainPerFrame * Float(frameCount)
            startGain = currentGain
            targetGain = min(safeGain, currentGain + maximumRecovery)
        }
        currentGain = targetGain

        guard startGain != 1 || targetGain != 1 else { return }
        let gainStep = (targetGain - startGain) / Float(frameCount)
        for index in 0..<frameCount {
            let sampleGain = min(targetGain, startGain + gainStep * Float(index))
            left[index] *= sampleGain
            right[index] *= sampleGain
        }
    }
}

extension HRIRManager: AudioSpatialEffect {
    nonisolated var isReady: Bool { hasPublishedRendererForControl() }

    nonisolated func process(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        processAudio(
            inputChannels: inputChannels,
            inputChannelCount: inputChannelCount,
            leftOutput: outputLeft,
            rightOutput: outputRight,
            frameCount: frameCount
        )
    }
}
