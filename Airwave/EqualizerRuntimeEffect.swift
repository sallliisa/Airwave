import Foundation
import os

/// Control-thread adapter that publishes sample-rate-specific EQ processors to the graph.
nonisolated final class EqualizerRuntimeEffect: AudioEqualizerEffect {
    private let processorLock = OSAllocatedUnfairLock<ParametricEqualizerProcessor?>(initialState: nil)
    private var controlProcessor: ParametricEqualizerProcessor?
    private var audioThreadProcessor: ParametricEqualizerProcessor?

    func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws {
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
            try? processor.setTarget(definition: nil)
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
            try? processor.setTarget(definition: nil)
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
            processor = published
            audioThreadProcessor = published
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
        case .tooManyFilters(let count):
            return .invalidFilter(
                line: nil,
                reason: "Equalizer supports at most \(ParametricEqualizerState.maximumFilterCount) filters; received \(count)."
            )
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
