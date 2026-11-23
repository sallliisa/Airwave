import Foundation
import os

/// Control-thread adapter that publishes sample-rate-specific EQ processors to the graph.
nonisolated final class EqualizerRuntimeEffect: AudioEqualizerEffect {
    private let processorLock = OSAllocatedUnfairLock<ParametricEqualizerProcessor?>(initialState: nil)
    private let retiredProcessorLock = OSAllocatedUnfairLock<ParametricEqualizerProcessor?>(initialState: nil)
    private var controlProcessor: ParametricEqualizerProcessor?
    private var controlContext: EqualizerConfigContext?
    private var audioThreadProcessor: ParametricEqualizerProcessor?
    private(set) var hasConfiguredEffect = false
    #if DEBUG
    // No owned probe array. Each ParametricEqualizerProcessor carries its
    // own DEBUG probe (see destructionProbe). Never touch probes here.
    #endif

    var isBypassed: Bool { audioThreadProcessor?.isBypassed ?? true }

    func cleanupAfterIOStopped() {
        audioThreadProcessor?.cleanupAfterIOStopped()
        audioThreadProcessor = nil
        retiredProcessorLock.withLock { $0 = nil }
    }

    func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws {
        try prepare(definition: definition, context: EqualizerConfigContext(
            sampleRate: sampleRate, inputChannelCount: 2, deviceName: "", deviceUID: ""
        ))
    }

    func prepare(definition: EqualizerDefinition?, routing: ResolvedOutputRouting) throws {
        try prepare(definition: definition, context: EqualizerConfigContext(
            sampleRate: routing.sampleRate, inputChannelCount: routing.inputLayout.channels.count,
            deviceName: routing.device.name, deviceUID: routing.device.uid
        ))
    }

    private func prepare(definition: EqualizerDefinition?, context: EqualizerConfigContext) throws {
        let sampleRate = context.sampleRate
        retiredProcessorLock.withLock { $0 = nil }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw EqualizerAudioEffectError.invalidSampleRate
        }
        controlContext = context

        let processor: ParametricEqualizerProcessor
        if let controlProcessor, controlProcessor.sampleRate == sampleRate {
            processor = controlProcessor
        } else {
            processor = try ParametricEqualizerProcessor(sampleRate: sampleRate)
            #if DEBUG
            processor.destructionProbe = ParametricEqualizerProcessor.DestructionProbe(
                id: ObjectIdentifier(processor as AnyObject).hashValue,
                kind: "processor",
                recorder: ParametricEqualizerProcessor.destructionRecorder,
                audioKey: ParametricEqualizerProcessor.destructionAudioKey
            )
            #endif
            controlProcessor = processor
            processorLock.withLock { published in
                published = processor
            }
        }

        try publish(definition: definition, to: processor, context: context)
    }

    func setTarget(definition: EqualizerDefinition?) throws {
        guard let processor = controlProcessor, let context = controlContext else {
            throw EqualizerAudioEffectError.unavailable("Equalizer has not been prepared for an output.")
        }
        try publish(definition: definition, to: processor, context: context)
    }

    private func publish(
        definition: EqualizerDefinition?, to processor: ParametricEqualizerProcessor, context: EqualizerConfigContext
    ) throws {
        defer { processor.drainRetiredStates() }
        let resolved: EqualizerDefinition?
        do {
            if let definition, let program = definition.program {
                let result = try program.resolve(context: context)
                resolved = EqualizerDefinition(directives: result.directives, sourceLocations: definition.sourceLocations)
            } else {
                resolved = definition
            }
        } catch let error as EqualizerParseError {
            let issue = error.issues.first
            throw sourceError(line: issue?.lineNumber, reason: issue?.reason ?? error.localizedDescription, definition: definition)
        }
        do {
            hasConfiguredEffect = try processor.setTarget(definition: resolved)
        } catch let error as ParametricEqualizerPreparationError {
            throw map(error, definition: resolved)
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
                if let old = audioThreadProcessor {
                    let retired: Bool? = retiredProcessorLock.withLockIfAvailable { retired in
                        guard retired == nil else { return false }
                        retired = old
                        return true
                    }
                    if retired != true {
                        // Slot full: hold the old processor on audio and keep the
                        // newest published processor for retry on a later
                        // callback. Never release the last reference here.
                    } else {
                        processor = published
                        audioThreadProcessor = published
                    }
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

    #if DEBUG
    /// DEBUG-only control helper. Tag a fresh processor with its identity
    /// probe. Call only from test or control code, never from the callback.
    /// Production `prepare` tags its own processors; tests use this for
    /// processors built directly.
    func tagProcessorForDestructionTest(_ processor: ParametricEqualizerProcessor) {
        processor.destructionProbe = ParametricEqualizerProcessor.DestructionProbe(
            id: ObjectIdentifier(processor as AnyObject).hashValue,
            kind: "processor",
            recorder: ParametricEqualizerProcessor.destructionRecorder,
            audioKey: ParametricEqualizerProcessor.destructionAudioKey
        )
    }
    #endif

    private func map(
        _ error: ParametricEqualizerPreparationError,
        definition: EqualizerDefinition?
    ) -> EqualizerAudioEffectError {
        switch error {
        case .invalidFilter(let index, let coefficientError):
            return sourceError(
                line: definition?.filters.filter(\.isEnabled)[safe: index]?.sourceLine,
                reason: coefficientError.localizedDescription,
                definition: definition
            )
        case .invalidGraphicCurve(let line):
            return sourceError(line: line, reason: error.localizedDescription, definition: definition)
        case .invalidStereoOperation(let line, let reason):
            return sourceError(line: line, reason: reason, definition: definition)
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

    private func sourceError(line: Int?, reason: String, definition: EqualizerDefinition?) -> EqualizerAudioEffectError {
        if let line, let location = definition?.sourceLocations[safe: line - 1] {
            return .invalidFilter(line: location.lineNumber, reason: "\(location.filename): \(reason)")
        }
        return .invalidFilter(line: line, reason: reason)
    }
}

private extension Collection {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
