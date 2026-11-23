import Accelerate
import Foundation
import os

nonisolated final class ParametricEqualizerState {
    static let maximumFilterCount = 64
    let sampleRate: Double
    private let stages: [EqualizerStereoStage]
    var isUnity: Bool { stages.isEmpty }

    #if DEBUG
    var destructionProbe: ParametricEqualizerProcessor.DestructionProbe?
    #endif

    fileprivate init(sampleRate: Double, stages: [EqualizerStereoStage]) {
        self.sampleRate = sampleRate
        self.stages = stages
    }

    func reset() {
        for stage in stages {
            switch stage {
            case .linear(let filter): filter.reset()
            case .delay(let delay): delay.reset()
            case .convolution(let filter): filter.reset()
            case .iir(let filter): filter.reset()
            case .copy: break
            }
        }
    }

    // BEGIN REALTIME CALLBACK
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let firstProcessed: Int
        if case .linear(let head)? = stages.first {
            head.process(
                inputLeft: inputLeft, inputRight: inputRight,
                leftOutput: leftOutput, rightOutput: rightOutput, frameCount: frameCount
            )
            firstProcessed = 1
        } else {
            let right = inputRight ?? inputLeft
            if right != UnsafePointer(rightOutput) {
                memcpy(rightOutput, right, frameCount * MemoryLayout<Float>.size)
            }
            if inputLeft != UnsafePointer(leftOutput) {
                memcpy(leftOutput, inputLeft, frameCount * MemoryLayout<Float>.size)
            }
            firstProcessed = 0
        }

        for index in firstProcessed..<stages.count {
            switch stages[index] {
            case .linear(let filter):
                filter.process(
                    inputLeft: leftOutput, inputRight: rightOutput,
                    leftOutput: leftOutput, rightOutput: rightOutput, frameCount: frameCount
                )
            case .copy(let copy):
                copy.process(left: leftOutput, right: rightOutput, frameCount: frameCount)
            case .delay(let delay):
                delay.process(left: leftOutput, right: rightOutput, frameCount: frameCount)
            case .convolution(let filter):
                filter.process(left: leftOutput, right: rightOutput, frameCount: frameCount)
            case .iir(let filter):
                filter.process(left: leftOutput, right: rightOutput, frameCount: frameCount)
            }
        }
    }
    // END REALTIME CALLBACK
}

nonisolated private enum EqualizerStereoStage {
    case linear(EqualizerStereoFilterStage)
    case copy(EqualizerStereoCopy)
    case delay(EqualizerStereoDelay)
    case convolution(EqualizerStereoConvolver)
    case iir(EqualizerCustomIIRFilter)
}

nonisolated private final class EqualizerStereoFilterStage {
    /// nil when there are no filters; that state only applies the preamp.
    private let setup: vDSP_biquadm_Setup?
    private var leftGain: Float
    private var rightGain: Float
    private let channels: EqualizerStereoChannels
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let graphicFilters: [EqualizerStereoConvolver]

    init(
        channels: EqualizerStereoChannels,
        preampLinear: Double,
        coefficients: [BiquadCoefficients],
        graphicFilters: [EqualizerStereoConvolver] = []
    ) {
        self.channels = channels
        self.leftGain = channels.contains(.left) ? Float(preampLinear) : 1
        self.rightGain = channels.contains(.right) ? Float(preampLinear) : 1
        self.graphicFilters = graphicFilters
        self.inputPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        self.outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)

        guard !coefficients.isEmpty else {
            self.setup = nil
            return
        }

        // vDSP stores both channels of each section together. An unselected
        // channel gets an identity section. Fold preamp into the first section.
        var flattened = [Double]()
        flattened.reserveCapacity(2 * coefficients.count * 5)
        for (index, coefficient) in coefficients.enumerated() {
            let gain = index == 0 ? preampLinear : 1
            for channel: EqualizerStereoChannels in [.left, .right] {
                guard channels.contains(channel) else {
                    flattened.append(contentsOf: [1, 0, 0, 0, 0])
                    continue
                }
                flattened.append(coefficient.b0 * gain)
                flattened.append(coefficient.b1 * gain)
                flattened.append(coefficient.b2 * gain)
                flattened.append(coefficient.a1)
                flattened.append(coefficient.a2)
            }
        }
        self.setup = flattened.withUnsafeBufferPointer { pointer in
            vDSP_biquadm_CreateSetup(
                pointer.baseAddress!,
                vDSP_Length(coefficients.count),  // sections
                2                                 // channels
            )
        }
    }

    deinit {
        if let setup { vDSP_biquadm_DestroySetup(setup) }
        inputPointers.deallocate()
        outputPointers.deallocate()
    }

    func reset() {
        if let setup { vDSP_biquadm_ResetState(setup) }
        for filter in graphicFilters { filter.reset() }
    }

    // BEGIN REALTIME CALLBACK
    @inline(__always)
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        // Mono input feeds both channels. Copy it into the right output first so
        // each channel filters in place and channel 0 can never overwrite the
        // buffer channel 1 still has to read.
        let right: UnsafePointer<Float>
        if let inputRight {
            right = inputRight
        } else {
            memcpy(rightOutput, inputLeft, frameCount * MemoryLayout<Float>.size)
            right = UnsafePointer(rightOutput)
        }

        if let setup {
            inputPointers.initialize(to: inputLeft)
            inputPointers.advanced(by: 1).initialize(to: right)
            outputPointers.initialize(to: leftOutput)
            outputPointers.advanced(by: 1).initialize(to: rightOutput)
            vDSP_biquadm(
                setup,
                inputPointers, 1,
                outputPointers, 1,
                vDSP_Length(frameCount)
            )
        } else {
            vDSP_vsmul(inputLeft, 1, &leftGain, leftOutput, 1, vDSP_Length(frameCount))
            vDSP_vsmul(right, 1, &rightGain, rightOutput, 1, vDSP_Length(frameCount))
        }
        for filter in graphicFilters {
            filter.process(left: leftOutput, right: rightOutput, frameCount: frameCount, channels: channels)
        }
    }
    // END REALTIME CALLBACK
}

nonisolated enum ParametricEqualizerPreparationError: Error, Equatable, LocalizedError {
    case invalidSampleRate
    case nonFinitePreamp
    case nonFiniteCoefficients
    case tooManyFilters(Int)
    case invalidFilter(index: Int, error: BiquadCoefficientError)
    case invalidGraphicCurve(line: Int)
    case invalidStereoOperation(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "Sample rate must be finite and positive."
        case .nonFinitePreamp:
            return "Preamp must produce a finite linear gain."
        case .nonFiniteCoefficients:
            return "Equalizer coefficients must be finite."
        case .tooManyFilters(let count):
            return "Equalizer supports at most \(ParametricEqualizerState.maximumFilterCount) filters; received \(count)."
        case .invalidFilter(let index, let error):
            return "Filter \(index + 1) is invalid: \(error.localizedDescription)"
        case .invalidStereoOperation(_, let reason):
            return reason
        case .invalidGraphicCurve:
            return "GraphicEQ could not produce a finite impulse response."
        }
    }
}

/// Fixed-storage stereo equalizer with non-blocking target publication and bounded crossfades.
nonisolated final class ParametricEqualizerProcessor {
    static let crossfadeDurationSeconds = 0.020
    static let maximumCallbackFrames = 4_096

    let sampleRate: Double
    let maxFramesPerCallback: Int

    private let unityState: ParametricEqualizerState
    private let targetLock = OSAllocatedUnfairLock<ParametricEqualizerState?>(initialState: nil)
    private let retirementLock = OSAllocatedUnfairLock<ParametricEqualizerState?>(initialState: nil)
    private let resetLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let bypassLock = OSAllocatedUnfairLock<Bool>(initialState: true)
    #if DEBUG
    // DEBUG-only destruction sentinel. Assigned from control with the
    // processor identity on creation; frees on the thread that drops the
    // last processor owner, so its recorder sees audio-thread releases.
    // Never read or written inside the realtime callback.
    var destructionProbe: DestructionProbe?
    #endif
    private var audioThreadTarget: ParametricEqualizerState?
    private var activeState: ParametricEqualizerState
    private var transitionFrom: ParametricEqualizerState?
    private var transitionTo: ParametricEqualizerState?
    private var pendingTarget: ParametricEqualizerState?
    private var observedTarget: ParametricEqualizerState?
    #if DEBUG
    // No owned probe array. Each filter state carries its own DEBUG probe
    // (see ParametricEqualizerState.destructionProbe). Never touch probes here.
    #endif
    private var transitionFrame = 0
    private let transitionLength: Int
    private let oldScratch: UnsafeMutablePointer<Float>
    private let oldRightScratch: UnsafeMutablePointer<Float>
    private let newScratch: UnsafeMutablePointer<Float>
    private let newRightScratch: UnsafeMutablePointer<Float>
    // Render-thread-only hold used when the control-side retirement slot is full.
    // A pending transition waits until the control side drains the slot.
    private var pendingRetirement: ParametricEqualizerState?

    init(sampleRate: Double, maxFramesPerCallback: Int = 4_096) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }
        guard maxFramesPerCallback > 0, maxFramesPerCallback <= Self.maximumCallbackFrames else {
            throw ParametricEqualizerPreparationError.tooManyFilters(maxFramesPerCallback)
        }

        self.sampleRate = sampleRate
        self.maxFramesPerCallback = maxFramesPerCallback
        self.unityState = try Self.prepare(definition: nil, sampleRate: sampleRate)
        self.activeState = unityState
        self.transitionLength = max(1, Int((sampleRate * Self.crossfadeDurationSeconds).rounded()))
        self.oldScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.oldRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.newScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.newRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
    }

    deinit {
        oldScratch.deallocate()
        oldRightScratch.deallocate()
        newScratch.deallocate()
        newRightScratch.deallocate()
    }

    static func prepare(
        definition: EqualizerDefinition?,
        sampleRate: Double
    ) throws -> ParametricEqualizerState {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }


        let compiler = EqualizerStereoCompiler(sampleRate: sampleRate)
        return try compiler.prepare(definition?.directives ?? [])
    }

    func publish(_ state: ParametricEqualizerState) throws {
        guard state.sampleRate == sampleRate else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }
        targetLock.withLock { target in
            target = state
        }
        if state !== unityState { bypassLock.withLock { $0 = false } }
    }

    var isBypassed: Bool { bypassLock.withLockIfAvailable { $0 } ?? false }

    #if DEBUG
    func withPublicationLockForTesting(_ body: () -> Void) {
        targetLock.withLock { _ in
            body()
        }
    }
    /// Keep alive on the state, not on the processor. The probe records the
    /// thread that runs its destruction. The probe must not capture the
    /// object it observes.
    final class DestructionRecorder: @unchecked Sendable {
        struct Event: Sendable { let id: Int; let isAudioThread: Bool; let kind: String }
        private let lock = NSLock()
        private var events: [Event] = []
        func record(id: Int, isAudioThread: Bool, kind: String) {
            lock.lock(); defer { lock.unlock() }
            events.append(Event(id: id, isAudioThread: isAudioThread, kind: kind))
        }
        var snapshot: [Event] { lock.lock(); defer { lock.unlock() }; return events }
        var audioThreadDestructionCount: Int { snapshot.filter(\.isAudioThread).count }
    }
    nonisolated final class DestructionProbe: @unchecked Sendable {
        let id: Int
        let kind: String
        let recorder: DestructionRecorder?
        let audioKey: DispatchSpecificKey<Void>?
        init(id: Int, kind: String, recorder: DestructionRecorder?, audioKey: DispatchSpecificKey<Void>?) {
            self.id = id; self.kind = kind; self.recorder = recorder; self.audioKey = audioKey
        }
        deinit {
            if let recorder, let audioKey {
                recorder.record(id: id, isAudioThread: DispatchQueue.getSpecific(key: audioKey) != nil, kind: kind)
            }
        }
    }
    nonisolated static var destructionAudioKey: DispatchSpecificKey<Void>?
    nonisolated static var destructionRecorder: DestructionRecorder?
    nonisolated static func configureDestructionProbeForTesting(
        audioKey: DispatchSpecificKey<Void>?,
        recorder: DestructionRecorder?
    ) {
        destructionAudioKey = audioKey
        destructionRecorder = recorder
    }
    /// DEBUG-only control helper. Tag a fresh filter state with its identity
    /// probe before first publish. Call only from test or control code, never
    /// from the realtime callback.
    nonisolated static func makeProbedStateForTesting(
        definition: EqualizerDefinition?,
        sampleRate: Double
    ) throws -> ParametricEqualizerState {
        let state = try prepare(definition: definition, sampleRate: sampleRate)
        state.destructionProbe = DestructionProbe(
            id: ObjectIdentifier(state as AnyObject).hashValue,
            kind: "filter",
            recorder: destructionRecorder,
            audioKey: destructionAudioKey
        )
        return state
    }
    #endif

    @discardableResult
    func setTarget(definition: EqualizerDefinition?) throws -> Bool {
        guard let definition else {
            try publish(unityState)
            return false
        }
        let state = try Self.prepare(definition: definition, sampleRate: sampleRate)
        guard !state.isUnity else {
            try publish(unityState)
            return false
        }
        #if DEBUG
        // Tag the production state too: setTarget publishes fresh states on
        // every call, and the proof must observe their release thread.
        if state !== unityState {
            state.destructionProbe = DestructionProbe(
                id: ObjectIdentifier(state as AnyObject).hashValue,
                kind: "filter",
                recorder: Self.destructionRecorder,
                audioKey: Self.destructionAudioKey
            )
        }
        #endif
        try publish(state)
        return true
    }

    func reset() {
        resetLock.withLock { requested in
            requested = true
        }
    }

    /// Releases states retired by the render thread. Call from the control thread.
    func drainRetiredStates() {
        retirementLock.withLock { retired in
            retired = nil
        }
    }

    /// Call only after the I/O callback has stopped.
    func cleanupAfterIOStopped() {
        retirementLock.withLock { $0 = nil }
        pendingRetirement = nil
        audioThreadTarget = nil
        activeState = unityState
        transitionFrom = nil
        transitionTo = nil
        pendingTarget = nil
        observedTarget = nil
        transitionFrame = 0
        bypassLock.withLock { $0 = true }
    }

    // BEGIN REALTIME CALLBACK
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)
        observePublishedTarget()
        flushPendingRetirement()
        applyPendingReset()

        var offset = 0
        while offset < frameCount {
            guard let from = transitionFrom, let to = transitionTo else {
                activeState.process(
                    inputLeft: inputLeft.advanced(by: offset),
                    inputRight: inputRight?.advanced(by: offset),
                    leftOutput: leftOutput.advanced(by: offset),
                    rightOutput: rightOutput.advanced(by: offset),
                    frameCount: frameCount - offset
                )
                return
            }

            let remaining = transitionLength - transitionFrame
            let segment = min(remaining, frameCount - offset)
            from.process(
                inputLeft: inputLeft.advanced(by: offset),
                inputRight: inputRight?.advanced(by: offset),
                leftOutput: oldScratch,
                rightOutput: oldRightScratch,
                frameCount: segment
            )
            to.process(
                inputLeft: inputLeft.advanced(by: offset),
                inputRight: inputRight?.advanced(by: offset),
                leftOutput: newScratch,
                rightOutput: newRightScratch,
                frameCount: segment
            )

            for index in 0..<segment {
                let progress = Double(transitionFrame + index + 1) / Double(transitionLength)
                let inverse = 1 - progress
                leftOutput[offset + index] = Float(
                    Double(oldScratch[index]) * inverse + Double(newScratch[index]) * progress
                )
                rightOutput[offset + index] = Float(
                    Double(oldRightScratch[index]) * inverse + Double(newRightScratch[index]) * progress
                )
            }

            transitionFrame += segment
            offset += segment
            if transitionFrame == transitionLength {
                finishTransition()
            }
        }
    }
    // END REALTIME CALLBACK

    private func observePublishedTarget() {
        enum TargetRead {
            case value(ParametricEqualizerState?)
        }

        if let read = targetLock.withLockIfAvailable({ TargetRead.value($0) }),
           case .value(let published) = read,
           let published {
            // Keep the unobserved intermediate alive until the audio side has
            // a retirement path. The control publisher retains the newest
            // target for retry.
            if let old = audioThreadTarget, old !== observedTarget, old !== published,
               old !== activeState, old !== transitionTo {
                guard retire(old) else { return }
            }
            audioThreadTarget = published
        }

        guard let target = audioThreadTarget, target !== observedTarget else { return }
        if transitionTo != nil, let pendingTarget, pendingTarget !== target {
            guard retire(pendingTarget) else { return }
            self.pendingTarget = nil
        }
        observedTarget = target
        if transitionTo != nil {
            if target !== transitionTo {
                if let old = pendingTarget, old !== target, old !== activeState, old !== transitionTo {
                    guard retire(old) else { return }
                }
                pendingTarget = target
            }
        } else if pendingRetirement != nil {
            if let old = pendingTarget, old !== target {
                guard retire(old) else { return }
            }
            pendingTarget = target
        } else if target !== activeState {
            beginTransition(to: target)
        }
    }

    private func applyPendingReset() {
        guard let requested = resetLock.withLockIfAvailable({ requested in
            let value = requested
            requested = false
            return value
        }), requested else {
            return
        }
        activeState.reset()
        transitionFrom?.reset()
        transitionTo?.reset()
    }

    private func beginTransition(to target: ParametricEqualizerState) {
        guard target !== activeState else { return }
        transitionFrom = activeState
        transitionTo = target
        transitionFrame = 0
    }

    private func finishTransition() {
        guard let from = transitionFrom, let to = transitionTo else { return }
        activeState = to
        transitionFrom = nil
        transitionTo = nil
        transitionFrame = 0
        if to === unityState, pendingTarget == nil {
            targetLock.withLockIfAvailable { target in
                guard target === unityState else { return }
                bypassLock.withLockIfAvailable { $0 = true }
            }
        }
        // retire() never reports failure: it holds in pendingRetirement when
        // the shared slot is full, and flushPendingRetirement() moves that
        // hold to control on a later callback. The branch stays explicit so
        // a future bounded retire keeps this call site honest.
        guard retire(from) else {
            transitionFrom = from
            return
        }

        if let pending = pendingTarget {
            pendingTarget = nil
            if pending !== activeState {
                beginTransition(to: pending)
            }
        }
    }

    @discardableResult
    private func retire(_ state: ParametricEqualizerState) -> Bool {
        guard pendingRetirement == nil else { return false }
        if retirementLock.withLockIfAvailable({ retired in
            guard retired == nil else { return false }
            retired = state
            return true
        }) == true {
            return true
        }
        pendingRetirement = state
        return true
    }

    private func flushPendingRetirement() {
        guard let pendingRetirement else { return }
        guard retirementLock.withLockIfAvailable({ retired in
            guard retired == nil else { return false }
            retired = pendingRetirement
            return true
        }) == true else {
            return
        }
        self.pendingRetirement = nil
        if let pending = pendingTarget {
            pendingTarget = nil
            if pending !== activeState {
                beginTransition(to: pending)
            }
        }
    }
}


nonisolated private final class EqualizerStereoCompiler {
    private let sampleRate: Double
    private var stages: [EqualizerStereoStage] = []
    private var channels = EqualizerStereoChannels.both
    private var scopes: [EqualizerStereoChannels] = []
    private var preamp = 0.0
    private var coefficients: [BiquadCoefficients] = []
    private var graphicFilters: [EqualizerStereoConvolver] = []
    private var filterCount = 0
    private var delaySamples = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func prepare(_ directives: [EqualizerDirective]) throws -> ParametricEqualizerState {
        for directive in directives {
            switch directive {
            case .preamp(let gain):
                preamp += gain
            case .parametric(let filter):
                if filter.isEnabled { try add(filter) }
            case .graphic(let curve):
                guard let response = GraphicEqualizerImpulseResponse.make(points: curve.points, sampleRate: sampleRate),
                      let filter = EqualizerStereoConvolver(impulseResponse: response) else {
                    throw ParametricEqualizerPreparationError.invalidGraphicCurve(line: curve.sourceLine)
                }
                graphicFilters.append(filter)
            case .stereo(let command, let line):
                try add(command, line: line)
            case .convolution(let asset):
                try add(asset)
            case .iir(let coefficients):
                try flush()
                stages.append(.iir(EqualizerCustomIIRFilter(coefficients, channels: channels)))
            case .enterInclude:
                scopes.append(channels)
            case .leaveInclude:
                if let saved = scopes.popLast(), saved != channels {
                    try flush()
                    channels = saved
                }
            }
        }
        try flush()
        return ParametricEqualizerState(sampleRate: sampleRate, stages: stages)
    }

    private func add(_ filter: EqualizerFilter) throws {
        filterCount += 1
        guard filterCount <= ParametricEqualizerState.maximumFilterCount else {
            throw ParametricEqualizerPreparationError.tooManyFilters(filterCount)
        }
        do {
            coefficients.append(try BiquadCoefficientBuilder.make(
                type: filter.type, gainDB: filter.gainDB, frequencyHz: filter.frequencyHz,
                shape: filter.shape, sampleRate: sampleRate
            ))
        } catch let error as BiquadCoefficientError {
            throw ParametricEqualizerPreparationError.invalidFilter(index: filterCount - 1, error: error)
        }
    }

    private func add(_ command: EqualizerStereoCommand, line: Int) throws {
        if case .channel(let next) = command, next == channels { return }
        try flush()
        switch command {
        case .channel(let next):
            channels = next
        case .copy(let assignments):
            stages.append(.copy(EqualizerStereoCopy(assignments: assignments)))
        case .delay(let amount):
            do {
                let delay = try EqualizerStereoDelay(delay: amount, sampleRate: sampleRate, channels: channels)
                delaySamples += delay.sampleCount
                guard delaySamples <= 1_920_000 else {
                    throw ParametricEqualizerPreparationError.invalidStereoOperation(
                        line: line, reason: "Total delay exceeds the preset limit."
                    )
                }
                stages.append(.delay(delay))
            } catch let error as ParametricEqualizerPreparationError {
                throw error
            } catch {
                throw ParametricEqualizerPreparationError.invalidStereoOperation(line: line, reason: error.localizedDescription)
            }
        }
    }

    private func add(_ asset: EqualizerConvolutionAsset) throws {
        try flush()
        guard abs(asset.sampleRate - sampleRate) <= 1 else {
            throw ParametricEqualizerPreparationError.invalidStereoOperation(
                line: asset.sourceLine,
                reason: "\(asset.filename) sample rate (\(asset.sampleRate) Hz) must match the output rate (\(sampleRate) Hz)."
            )
        }
        let left = channels.contains(.left) ? asset.channels.first : nil
        let rightIndex = left != nil && asset.channels.count > 1 ? 1 : 0
        let right = channels.contains(.right) ? asset.channels.dropFirst(rightIndex).first : nil
        guard let filter = EqualizerStereoConvolver(leftResponse: left, rightResponse: right) else {
            throw ParametricEqualizerPreparationError.invalidStereoOperation(
                line: asset.sourceLine, reason: "Could not prepare impulse response \(asset.filename)."
            )
        }
        stages.append(.convolution(filter))
    }

    private func flush() throws {
        guard preamp != 0 || !coefficients.isEmpty || !graphicFilters.isEmpty else { return }
        let gain = pow(10, preamp / 20)
        guard gain.isFinite, Float(gain).isFinite else {
            throw ParametricEqualizerPreparationError.nonFinitePreamp
        }
        guard coefficients.allSatisfy({ coefficient in
            [coefficient.b0 * gain, coefficient.b1 * gain, coefficient.b2 * gain,
             coefficient.a1, coefficient.a2].allSatisfy(\.isFinite)
        }) else {
            throw ParametricEqualizerPreparationError.nonFiniteCoefficients
        }
        stages.append(.linear(EqualizerStereoFilterStage(
            channels: channels, preampLinear: gain, coefficients: coefficients, graphicFilters: graphicFilters
        )))
        preamp = 0
        coefficients.removeAll(keepingCapacity: true)
        graphicFilters.removeAll(keepingCapacity: true)
    }
}
