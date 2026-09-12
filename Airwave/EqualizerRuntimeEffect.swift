import Foundation
import os

/// Control-thread adapter that publishes sample-rate-specific EQ processors to the graph.
nonisolated final class EqualizerRuntimeEffect: AudioEqualizerEffect {
    private let processorLock = OSAllocatedUnfairLock<ParametricEqualizerProcessor?>(initialState: nil)
    private let retiredProcessorLock = OSAllocatedUnfairLock<ParametricEqualizerProcessor?>(initialState: nil)
    private var controlProcessor: ParametricEqualizerProcessor?
    private var audioThreadProcessor: ParametricEqualizerProcessor?

    var isBypassed: Bool { audioThreadProcessor?.isBypassed ?? true }

    func cleanupAfterIOStopped() {
        audioThreadProcessor?.cleanupAfterIOStopped()
        audioThreadProcessor = nil
        retiredProcessorLock.withLock { $0 = nil }
    }

    func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws {
        retiredProcessorLock.withLock { $0 = nil }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw EqualizerAudioEffectError.invalidSampleRate
        }

        let processor: ParametricEqualizerProcessor
        if let controlProcessor, controlProcessor.sampleRate == sampleRate {
            processor = controlProcessor
        } else {
            processor = try ParametricEqualizerProcessor(sampleRate: sampleRate)
            controlProcessor = processor
            processorLock.withLock { published in
                published = processor
            }
        }

        do {
            try processor.setTarget(definition: definition)
            processor.drainRetiredStates()
        } catch let error as ParametricEqualizerPreparationError {
            processor.drainRetiredStates()
            throw map(error, definition: definition)
        }
    }

    func setTarget(definition: EqualizerDefinition?) throws {
        guard let processor = controlProcessor else {
            throw EqualizerAudioEffectError.unavailable("Equalizer has not been prepared for an output.")
        }
        do {
            try processor.setTarget(definition: definition)
            processor.drainRetiredStates()
        } catch let error as ParametricEqualizerPreparationError {
            processor.drainRetiredStates()
            throw map(error, definition: definition)
        }
    }

    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        var processor = audioThreadProcessor
        if let published = processorLock.withLockIfAvailable({ $0 }) {
            if published !== audioThreadProcessor {
                if let old = audioThreadProcessor,
                   retiredProcessorLock.withLockIfAvailable({ retired in
                       guard retired == nil else { return false }
                       retired = old
                       return true
                   }) != true {
                    // Keep the old processor until the control thread drains it.
                } else {
                    processor = published
                    audioThreadProcessor = published
                }
            }
        }
        guard let processor else {
            memcpy(outputLeft, inputLeft, frameCount * MemoryLayout<Float>.size)
            if let inputRight {
                memcpy(outputRight, inputRight, frameCount * MemoryLayout<Float>.size)
            } else {
                memcpy(outputRight, inputLeft, frameCount * MemoryLayout<Float>.size)
            }
            return
        }
        processor.process(
            inputLeft: inputLeft,
            inputRight: inputRight,
            leftOutput: outputLeft,
            rightOutput: outputRight,
            frameCount: frameCount
        )
    }

    private func map(
        _ error: ParametricEqualizerPreparationError,
        definition: EqualizerDefinition?
    ) -> EqualizerAudioEffectError {
        switch error {
        case .invalidFilter(let index, let coefficientError):
            return .invalidFilter(
                line: definition?.filters.filter(\.isEnabled)[safe: index]?.sourceLine,
                reason: coefficientError.localizedDescription
            )
        case .invalidSampleRate:
            return .invalidSampleRate
        case .nonFinitePreamp:
            return .invalidFilter(line: nil, reason: "Preamp produces a non-finite gain.")
        case .nonFiniteCoefficients:
            return .invalidFilter(line: nil, reason: "Equalizer coefficients are non-finite.")
        case .tooManyFilters(let count):
            return .invalidFilter(
                line: nil,
                reason: "Equalizer supports at most \(ParametricEqualizerState.maximumFilterCount) filters; received \(count)."
            )
        }
    }
}

private extension Collection {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
