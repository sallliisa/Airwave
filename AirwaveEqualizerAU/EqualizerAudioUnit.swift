import AudioToolbox
import AVFoundation
import Foundation
import os
import Synchronization

nonisolated struct EqualizerPresetSummary: Equatable, Sendable {
    let name: String
    let preampDB: Double
    let filterCount: Int
}

nonisolated final class EqualizerAudioUnit: AUAudioUnit {
    static let presetDidChange = Notification.Name("EqualizerPresetDidChange")
    private static let logger = os.Logger(subsystem: AirwaveLog.subsystem, category: "Equalizer Audio Unit")

    private struct Selection {
        let preset: EqualizerAUState.Preset
        let definition: EqualizerDefinition

        init(preset: EqualizerAUState.Preset) throws {
            self.preset = preset
            if let legacy = preset.legacyText {
                let source = legacy.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map { $0.prefix(while: { $0 != "#" }) }.joined(separator: "\n")
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EqualizerAudioUnitError.preset("Enter an Equalizer APO preset.")
                }
                definition = try EqualizerAPOParser.parse(
                    data: Data(source.utf8), filename: preset.filename, allowDeferred: false
                )
            } else {
                definition = try EqualizerConfigFiles.parseManagedDefinition(data: preset.data, filename: preset.filename)
            }
        }

        init(preset: EqualizerAUState.Preset, definition: EqualizerDefinition) {
            self.preset = preset
            self.definition = definition
        }

        static func pasted(name: String, text: String) throws -> Selection {
            let preset = EqualizerAUState.Preset(name: name, filename: "Preset.txt", data: Data(text.utf8))
            do {
                return try Selection(preset: preset)
            } catch {
                if let priorFormat = try? Selection(preset: EqualizerAUState.Preset(name: preset.name, legacyText: text)) {
                    return priorFormat
                }
                throw error
            }
        }

        func resolve(sampleRate: Double, context: EqualizerAUState.OutputContext?) throws -> EqualizerDefinition {
            guard let program = definition.program else { return definition }
            let resolved = try program.resolve(context: EqualizerConfigContext(
                sampleRate: sampleRate,
                inputChannelCount: context?.inputChannelCount ?? 2,
                deviceName: context?.deviceName ?? "",
                deviceUID: context?.deviceUID ?? ""
            ))
            return EqualizerDefinition(directives: resolved.directives, sourceLocations: definition.sourceLocations)
        }
    }

    private struct State {
        var selection: Selection?
        var context: EqualizerAUState.OutputContext?
        var definition: EqualizerDefinition?
        var resources: EqualizerRenderResources?
        var sampleRate = 48_000.0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let renderAccess = EqualizerRenderAccess()
    private let tail = Atomic<UInt64>(0)
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw EqualizerAudioUnitError.unsupportedFormat
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    deinit { renderAccess.resources.store(nil, ordering: .releasing) }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? { [2, 2] }
    override var canProcessInPlace: Bool { true }
    override var tailTime: TimeInterval { Double(bitPattern: tail.load(ordering: .relaxed)) }

    @objc dynamic override var shouldBypassEffect: Bool {
        get { renderAccess.bypass.load(ordering: .relaxed) }
        set { renderAccess.bypass.store(newValue, ordering: .relaxed) }
    }

    override var fullState: [String: Any]? {
        get {
            let base = super.fullState ?? [:]
            return state.withLockUnchecked { current in
                EqualizerAUState.document(preset: current.selection?.preset, context: current.context,
                                          bypass: shouldBypassEffect, including: base)
            }
        }
        set {
            do {
                let document = try EqualizerAUState(newValue)
                let selection = try document.preset.map(Selection.init(preset:))
                try select(selection, source: .document(document.context))
                super.fullState = newValue
                shouldBypassEffect = document.bypass
                notifyPresetChange()
            } catch {
                Self.logger.error("Could not restore Equalizer state: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    override var fullStateForDocument: [String: Any]? {
        get { fullState }
        set { fullState = newValue }
    }

    var preset: EqualizerPresetSummary? {
        state.withLockUnchecked { current in
            guard let selection = current.selection else { return nil }
            let directives = (current.definition ?? selection.definition).directives
            let preamp = directives.reduce(0.0) { gain, directive in
                if case .preamp(let value) = directive { return gain + value }
                return gain
            }
            let count = directives.count { directive in
                switch directive {
                case .parametric(let filter): filter.isEnabled
                case .graphic, .convolution, .iir: true
                default: false
                }
            }
            return EqualizerPresetSummary(name: selection.preset.name, preampDB: preamp, filterCount: count)
        }
    }

    func applyPreset(name: String, text: String) throws {
        try select(Selection.pasted(name: name, text: text), source: .editor)
        notifyPresetChange()
    }

    func importPreset(from url: URL) throws {
        let selection: Selection
        if EqualizerConfigFiles.isArchive(url) {
            let data = try EqualizerConfigFiles.readFile(at: url, limit: EqualizerConfigFiles.maximumArchiveSize)
            let preset = EqualizerAUState.Preset(name: url.deletingPathExtension().lastPathComponent,
                                                 filename: url.lastPathComponent, data: data)
            selection = try Selection(preset: preset)
        } else {
            do {
                let prepared = try EqualizerConfigFiles.prepareImport(url)
                let preset = EqualizerAUState.Preset(name: (prepared.filename as NSString).deletingPathExtension,
                                                     filename: prepared.filename, data: prepared.data)
                selection = Selection(preset: preset, definition: prepared.definition)
            } catch {
                guard url.pathExtension.caseInsensitiveCompare("txt") == .orderedSame,
                      let data = try? EqualizerConfigFiles.readFile(at: url, limit: EqualizerAPOParser.maximumDataSize),
                      let text = String(data: data, encoding: .utf8),
                      let priorFormat = try? Selection.pasted(name: url.deletingPathExtension().lastPathComponent,
                                                              text: text),
                      priorFormat.preset.legacyText != nil else { throw error }
                selection = priorFormat
            }
        }
        try select(selection, source: .editor)
        notifyPresetChange()
    }

    func clearPreset() throws {
        try select(nil, source: .editor)
        notifyPresetChange()
    }

    func responseDB(frequencies: [Double]) throws -> [Double] {
        let snapshot = state.withLockUnchecked { ($0.selection, $0.context, $0.resources == nil ? outputBus.format.sampleRate : $0.sampleRate) }
        return try EqualizerResponse.make(
            definition: snapshot.0?.resolve(sampleRate: snapshot.2, context: snapshot.1),
            sampleRate: snapshot.2,
            frequencies: frequencies
        )
    }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        Self.supports(format) && super.shouldChange(to: format, for: bus)
    }

    override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format
        guard Self.supports(input), Self.supports(output), input.sampleRate == output.sampleRate else {
            throw EqualizerAudioUnitError.unsupportedFormat
        }
        let maxFrames = Int(maximumFramesToRender)
        guard (1...65_536).contains(maxFrames) else { throw EqualizerAudioUnitError.unsupportedFrameCount }

        try super.allocateRenderResources()
        do {
            try state.withLockUnchecked { current in
                let definition = try current.selection?.resolve(sampleRate: output.sampleRate, context: current.context)
                let processor = try Self.prepare(definition: definition, sampleRate: output.sampleRate)
                let resources = EqualizerRenderResources(
                    processor: processor, sampleRate: output.sampleRate, maxFrames: maxFrames,
                    inputInterleaved: input.isInterleaved, outputInterleaved: output.isInterleaved
                )
                current.definition = definition
                current.resources = resources
                current.sampleRate = output.sampleRate
                setTail(definition: definition, sampleRate: output.sampleRate)
                renderAccess.resources.store(Unmanaged.passUnretained(resources).toOpaque(), ordering: .releasing)
            }
        } catch {
            super.deallocateRenderResources()
            throw error
        }
        notifyPresetChange()
    }

    override func deallocateRenderResources() {
        state.withLockUnchecked { current in
            renderAccess.resources.store(nil, ordering: .releasing)
            current.resources = nil
        }
        super.deallocateRenderResources()
    }

    override func reset() {
        super.reset()
        renderAccess.shouldReset.store(true, ordering: .releasing)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let access = renderAccess
        return { flags, timestamp, frameCount, bus, output, _, pullInput in
            guard bus == 0 else { return kAudioUnitErr_InvalidElement }
            guard let address = access.resources.load(ordering: .acquiring) else {
                return kAudioUnitErr_Uninitialized
            }
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let resources = Unmanaged<EqualizerRenderResources>.fromOpaque(address).takeUnretainedValue()
            if access.shouldReset.exchange(false, ordering: .acquiringAndReleasing) { resources.reset() }
            return resources.render(
                flags: flags, timestamp: timestamp, frameCount: frameCount, output: output,
                bypass: access.bypass.load(ordering: .relaxed), pullInput: pullInput
            )
        }
    }

    private enum SelectionSource {
        case editor
        case document(EqualizerAUState.OutputContext?)
    }

    private func select(_ selection: Selection?, source: SelectionSource) throws {
        try state.withLockUnchecked { current in
            let context: EqualizerAUState.OutputContext?
            switch source {
            case .editor: context = current.context
            case .document(let restored): context = restored
            }
            let sampleRate = current.resources == nil ? outputBus.format.sampleRate : current.sampleRate
            let definition: EqualizerDefinition?
            if case .document = source, current.resources == nil {
                // Hosts can restore a document before negotiating a sample rate.
                definition = try? selection?.resolve(sampleRate: sampleRate, context: context)
            } else {
                definition = try selection?.resolve(sampleRate: sampleRate, context: context)
                let processor = try Self.prepare(definition: definition, sampleRate: sampleRate)
                current.resources?.publish(processor)
            }
            setTail(definition: definition, sampleRate: sampleRate)
            current.selection = selection
            current.context = context
            current.definition = definition
        }
    }

    private static func prepare(definition: EqualizerDefinition?, sampleRate: Double) throws -> ParametricEqualizerState? {
        guard let definition else { return nil }
        do {
            return try ParametricEqualizerProcessor.prepare(definition: definition, sampleRate: sampleRate)
        } catch let error as ParametricEqualizerPreparationError {
            let line: Int?
            switch error {
            case .invalidFilter(let index, _):
                let filters = definition.filters.filter(\.isEnabled)
                line = filters.indices.contains(index) ? filters[index].sourceLine : nil
            case .invalidGraphicCurve(let sourceLine), .invalidStereoOperation(let sourceLine, _):
                line = sourceLine
            default:
                line = nil
            }
            if let line, definition.sourceLocations.indices.contains(line - 1) {
                let source = definition.sourceLocations[line - 1]
                throw EqualizerAudioUnitError.preset("\(source.filename), line \(source.lineNumber): \(error.localizedDescription)")
            }
            if let line {
                throw EqualizerAudioUnitError.preset("Line \(line): \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func notifyPresetChange() {
        NotificationCenter.default.post(name: Self.presetDidChange, object: self)
    }

    private func setTail(definition: EqualizerDefinition?, sampleRate: Double) {
        let frames = EqualizerResponse.tailFrames(definition, sampleRate: sampleRate)
        tail.store((Double(frames) / sampleRate).bitPattern, ordering: .relaxed)
    }

    private static func supports(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && format.channelCount == 2
            && format.sampleRate.isFinite && format.sampleRate > 0
    }
}

private nonisolated enum EqualizerAudioUnitError: LocalizedError, CustomNSError {
    case unsupportedFormat
    case unsupportedFrameCount
    case preset(String)

    static let errorDomain = NSOSStatusErrorDomain

    var errorCode: Int {
        switch self {
        case .unsupportedFormat: Int(kAudioUnitErr_FormatNotSupported)
        case .unsupportedFrameCount: Int(kAudioUnitErr_TooManyFramesToProcess)
        case .preset: Int(kAudioUnitErr_InvalidPropertyValue)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Equalizer requires stereo 32-bit floating-point audio at a matching sample rate."
        case .unsupportedFrameCount: "The host requested an unsupported render buffer size."
        case .preset(let reason): reason
        }
    }
}

private nonisolated enum EqualizerResponse {
    static func tailFrames(_ definition: EqualizerDefinition?, sampleRate: Double) -> Int {
        definition?.directives.reduce(0) { frames, directive in
            switch directive {
            case .graphic(let curve):
                let flat = curve.points.dropFirst().allSatisfy { $0.gainDB == curve.points.first?.gainDB }
                return frames + (flat ? 0 : GraphicEqualizerImpulseResponse.tapCount - 1)
            case .convolution(let asset):
                return frames + max(0, (asset.channels.first?.count ?? 0) - 1)
            case .stereo(.delay(let delay), _):
                let samples: Double
                switch delay {
                case .milliseconds(let value): samples = sampleRate * value / 1_000
                case .samples(let value): samples = value
                }
                return frames + Int(min(Double(EqualizerStereoDelay.maximumSampleCount), samples.rounded()))
            default:
                return frames
            }
        } ?? 0
    }

    static func make(definition: EqualizerDefinition?, sampleRate: Double, frequencies: [Double]) throws -> [Double] {
        guard let definition else { return Array(repeating: 0, count: frequencies.count) }
        let tail = tailFrames(definition, sampleRate: sampleRate)
        // Long delays and cascaded convolution can exceed an interactive preview's time window.
        guard tail < 65_536 else { return [] }
        let processor = try ParametricEqualizerProcessor.prepare(definition: definition, sampleRate: sampleRate)
        let length = min(65_536, max(4_096, tail + 4_096))
        var input = [Float](repeating: 0, count: length)
        input[0] = 1
        var left = [Float](repeating: 0, count: length)
        var right = left
        // Copy can add a DC offset, so subtract the response to a silent input.
        let hasCopy = definition.directives.contains {
            if case .stereo(.copy, _) = $0 { return true }
            return false
        }
        var baselineLeft: [Float] = []
        var baselineRight: [Float] = []
        if hasCopy {
            let silent = [Float](repeating: 0, count: length)
            baselineLeft = silent
            baselineRight = silent
            render(processor, input: silent, left: &baselineLeft, right: &baselineRight)
            processor.reset()
        }
        render(processor, input: input, left: &left, right: &right)
        if hasCopy {
            for index in input.indices {
                left[index] -= baselineLeft[index]
                right[index] -= baselineRight[index]
            }
        }
        return frequencies.map { frequency in
            guard frequency.isFinite, (0...sampleRate / 2).contains(frequency) else { return .nan }
            let angle = -2 * Double.pi * frequency / sampleRate
            let real = cos(angle)
            let imaginary = sin(angle)
            func magnitude(_ samples: [Float]) -> Double {
                var sumReal = 0.0
                var sumImaginary = 0.0
                for tap in samples.reversed() {
                    let nextReal = sumReal * real - sumImaginary * imaginary + Double(tap)
                    sumImaginary = sumReal * imaginary + sumImaginary * real
                    sumReal = nextReal
                }
                return hypot(sumReal, sumImaginary)
            }
            let response = hypot(magnitude(left), magnitude(right)) / sqrt(2)
            return 20 * log10(max(response, 1e-12))
        }
    }

    private static func render(_ processor: ParametricEqualizerState, input: [Float],
                               left: inout [Float], right: inout [Float]) {
        input.withUnsafeBufferPointer { impulse in
            left.withUnsafeMutableBufferPointer { left in
                right.withUnsafeMutableBufferPointer { right in
                    processor.process(inputLeft: impulse.baseAddress!, inputRight: impulse.baseAddress!,
                                      leftOutput: left.baseAddress!, rightOutput: right.baseAddress!,
                                      frameCount: impulse.count)
                }
            }
        }
    }
}
