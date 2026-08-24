import Accelerate
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
    )
    var isReady: Bool { get }
}

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
    static let maximumCallbackFrames = ParametricEqualizerProcessor.maximumCallbackFrames

    private let spatial: any AudioSpatialEffect
    private let equalizer: any AudioEqualizerEffect
    private let spatialLeftScratch: UnsafeMutablePointer<Float>
    private let spatialRightScratch: UnsafeMutablePointer<Float>
    private let maxFramesPerCallback: Int
    /// Resolved per-output speaker identity of every captured channel; used to
    /// fold down before the first prepare resolves a device layout.
    private var inputSpeakers: [VirtualSpeaker] = [.FL, .FR]
    private let equalizerActiveLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var audioThreadEqualizerActive = false

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
            equalizerActiveLock.withLock { active in
                active = equalizerDefinition != nil
            }
            if equalizerDefinition != nil {
                runnableEffects.insert(.equalizer)
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: nil
            )
        } catch let error as EqualizerAudioEffectError {
            equalizerActiveLock.withLock { active in
                active = false
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(
                    filterLine: error.filterLine,
                    reason: error.errorDescription ?? "Equalizer preparation failed."
                )
            )
        } catch {
            equalizerActiveLock.withLock { active in
                active = false
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
        var runnableEffects = Set<AudioEffectKind>()
        if spatial.isReady {
            runnableEffects.insert(.spatial)
        }
        do {
            try equalizer.setTarget(definition: definition)
            // Keep the processor in the callback path for the unity ramp when EQ is
            // removed. A later prepare(nil) bypasses it for a newly-created pipeline.
            equalizerActiveLock.withLock { active in
                active = true
            }
            if definition != nil {
                runnableEffects.insert(.equalizer)
            }
            return AudioEffectPreparationResult(runnableEffects: runnableEffects, equalizerWarning: nil)
        } catch let error as EqualizerAudioEffectError {
            equalizerActiveLock.withLock { active in
                active = true
            }
            return AudioEffectPreparationResult(
                runnableEffects: runnableEffects,
                equalizerWarning: AudioEffectWarning(
                    filterLine: error.filterLine,
                    reason: error.errorDescription ?? "Equalizer update failed."
                )
            )
        } catch {
            equalizerActiveLock.withLock { active in
                active = true
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
            equalizerActive = published
            audioThreadEqualizerActive = published
        }
        let spatialReady = spatial.isReady

        if spatialReady {
            if equalizerActive {
                spatial.process(
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    outputLeft: spatialLeftScratch,
                    outputRight: spatialRightScratch,
                    frameCount: frameCount
                )
                equalizer.process(
                    inputLeft: spatialLeftScratch,
                    inputRight: spatialRightScratch,
                    outputLeft: outputLeft,
                    outputRight: outputRight,
                    frameCount: frameCount
                )
            } else {
                spatial.process(
                    inputChannels: inputChannels,
                    inputChannelCount: inputChannelCount,
                    outputLeft: outputLeft,
                    outputRight: outputRight,
                    frameCount: frameCount
                )
            }
            return
        }

        // Spatial inactive: fold every captured channel into the stereo pair.
        // Plain stereo devices keep the historical byte-exact passthrough.
        if !(inputChannelCount == 2 && inputSpeakers.count == 2) {
            foldDownToStereo(
                inputChannels: inputChannels,
                inputChannelCount: inputChannelCount,
                outputLeft: outputLeft,
                outputRight: outputRight,
                frameCount: frameCount
            )
        } else {
            copyStereoPassthrough(
                inputChannels: inputChannels,
                frameCount: frameCount,
                outputLeft: outputLeft,
                outputRight: outputRight
            )
        }

        if equalizerActive {
            equalizer.process(
                inputLeft: outputLeft,
                inputRight: outputRight,
                outputLeft: outputLeft,
                outputRight: outputRight,
                frameCount: frameCount
            )
        }
    }
    // END REALTIME CALLBACK

    @inline(__always)
    private func foldDownToStereo(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        memset(outputLeft, 0, frameCount * MemoryLayout<Float>.size)
        memset(outputRight, 0, frameCount * MemoryLayout<Float>.size)
        for channel in 0..<min(inputChannelCount, inputSpeakers.count) {
            guard let source = inputChannels[channel] else { continue }
            let gains = StereoDownmixGains.gains(for: inputSpeakers[channel])
            var leftGain = gains.left
            var rightGain = gains.right
            if leftGain != 0 {
                vDSP_vsma(source, 1, &leftGain, outputLeft, 1, outputLeft, 1, vDSP_Length(frameCount))
            }
            if rightGain != 0 {
                vDSP_vsma(source, 1, &rightGain, outputRight, 1, outputRight, 1, vDSP_Length(frameCount))
            }
        }
    }

    @inline(__always)
    private func copyStereoPassthrough(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        frameCount: Int,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>
    ) {
        if let left = inputChannels[0] {
            memcpy(outputLeft, left, frameCount * MemoryLayout<Float>.size)
        } else {
            memset(outputLeft, 0, frameCount * MemoryLayout<Float>.size)
        }
        if let right = inputChannels[1] {
            memcpy(outputRight, right, frameCount * MemoryLayout<Float>.size)
        } else if let left = inputChannels[0] {
            // Mono capture duplicates into both ears (CATap mono contract).
            memcpy(outputRight, left, frameCount * MemoryLayout<Float>.size)
        } else {
            memset(outputRight, 0, frameCount * MemoryLayout<Float>.size)
        }
    }
}

extension HRIRManager: AudioSpatialEffect {
    nonisolated var isReady: Bool { hasPublishedRendererForAudioCallback() }
}
