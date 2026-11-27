import AudioToolbox
import AVFoundation
import Foundation
import os
import Synchronization

nonisolated final class AirwaveSpatialAudioUnit: AUAudioUnit {
    static let presetDidChange = Notification.Name("AirwaveSpatialPresetDidChange")

    enum PresetSelection: Equatable {
        case neutral
        case imported(name: String)
    }

    private enum Preset {
        case neutral
        case imported(name: String, wav: Data)

        func prepare(sampleRate: Double) throws -> SpatialProcessor {
            let url: URL
            let temporaryURL: URL?
            switch self {
            case .neutral:
                guard let resource = AirwaveSpatialAudioUnit.neutralURL else {
                    throw SpatialAudioUnitError.missingPreset
                }
                url = resource
                temporaryURL = nil
            case .imported(_, let wav):
                url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                temporaryURL = url
                try wav.write(to: url, options: .atomic)
            }
            defer {
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            }
            return try SpatialProcessor(url: url, sampleRate: sampleRate)
        }
    }

    private struct State {
        var preset: Preset = .neutral
        var resources: SpatialRenderResources?
        var sampleRate: Double = 48_000
    }

    private enum StateKey {
        static let presetName = "AirwaveSpatial.presetName"
        static let impulseResponse = "AirwaveSpatial.impulseResponse"
        static let bypass = "AirwaveSpatial.bypass"
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let renderAccess = SpatialRenderAccess()
    private let tail = Atomic<UInt64>(0)
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw SpatialAudioUnitError.unsupportedFormat
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        if let url = Self.neutralURL, let header = try? WAVLoader.headerInfo(from: url) {
            setTail(frames: max(0, header.frameCount - 1), sampleRate: header.sampleRate)
        }
    }

    deinit {
        renderAccess.resources.store(nil, ordering: .releasing)
    }

    private static var neutralURL: URL? {
        Bundle(for: AirwaveSpatialAudioUnit.self).url(forResource: "NeutralSH1.0", withExtension: "wav")
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? { [2, 2] }
    override var canProcessInPlace: Bool { true }
    override var latency: TimeInterval { 0 }
    override var tailTime: TimeInterval {
        Double(bitPattern: tail.load(ordering: .relaxed))
    }

    @objc dynamic override var shouldBypassEffect: Bool {
        get { renderAccess.bypass.load(ordering: .relaxed) }
        set { renderAccess.bypass.store(newValue, ordering: .relaxed) }
    }

    override var fullState: [String: Any]? {
        get {
            let preset = state.withLockUnchecked { $0.preset }
            var snapshot = super.fullState ?? [:]
            snapshot[StateKey.bypass] = shouldBypassEffect
            if case .imported(let name, let wav) = preset {
                snapshot[StateKey.presetName] = name
                snapshot[StateKey.impulseResponse] = wav
            }
            return snapshot
        }
        set {
            super.fullState = newValue
            shouldBypassEffect = newValue?[StateKey.bypass] as? Bool ?? false
            if let wav = newValue?[StateKey.impulseResponse] as? Data,
               let name = newValue?[StateKey.presetName] as? String,
               !wav.isEmpty, wav.count <= WAVLoader.maximumFileSize {
                do {
                    try selectPreset(.imported(name: name, wav: wav))
                    return
                } catch {
                    // Fall back to a playable preset when a host document contains invalid audio data.
                }
            }
            try? selectPreset(.neutral)
        }
    }

    var presetSelection: PresetSelection {
        state.withLockUnchecked { current in
            switch current.preset {
            case .neutral: .neutral
            case .imported(let name, _): .imported(name: name)
            }
        }
    }

    func useNeutralPreset() throws {
        try selectPreset(.neutral)
    }

    func importPreset(from url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let wav = try file.read(upToCount: WAVLoader.maximumFileSize + 1), !wav.isEmpty else {
            throw WAVError.emptyFile
        }
        guard wav.count <= WAVLoader.maximumFileSize else { throw WAVError.fileTooLarge }
        try selectPreset(.imported(name: url.deletingPathExtension().lastPathComponent, wav: wav))
    }

    private func selectPreset(_ preset: Preset) throws {
        try state.withLockUnchecked { current in
            let sampleRate = current.resources == nil ? outputBus.format.sampleRate : current.sampleRate
            let processor = try preset.prepare(sampleRate: sampleRate)
            if let resources = current.resources {
                resources.publish(processor)
            }
            current.preset = preset
            current.sampleRate = sampleRate
            setTail(frames: processor.tailFrames, sampleRate: sampleRate)
        }
        NotificationCenter.default.post(name: Self.presetDidChange, object: self)
    }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        Self.supports(format) && super.shouldChange(to: format, for: bus)
    }

    override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format
        guard Self.supports(input), Self.supports(output), input.sampleRate == output.sampleRate else {
            throw SpatialAudioUnitError.unsupportedFormat
        }

        let maxFrames = Int(maximumFramesToRender)
        guard (1...65_536).contains(maxFrames) else {
            throw SpatialAudioUnitError.unsupportedFrameCount
        }
        try super.allocateRenderResources()
        do {
            try state.withLockUnchecked { current in
                let processor = try current.preset.prepare(sampleRate: output.sampleRate)
                let resources = SpatialRenderResources(
                    processor: processor,
                    maxFrames: maxFrames,
                    inputInterleaved: input.isInterleaved,
                    outputInterleaved: output.isInterleaved
                )
                current.resources = resources
                current.sampleRate = output.sampleRate
                setTail(frames: processor.tailFrames, sampleRate: output.sampleRate)
                renderAccess.resources.store(Unmanaged.passUnretained(resources).toOpaque(), ordering: .releasing)
            }
        } catch {
            setRenderResourcesAllocated(false)
            throw error
        }
    }

    override func deallocateRenderResources() {
        state.withLockUnchecked { current in
            // The host stops rendering before deallocation.
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
            let resources = Unmanaged<SpatialRenderResources>.fromOpaque(address).takeUnretainedValue()
            if access.shouldReset.exchange(false, ordering: .acquiringAndReleasing) {
                resources.reset()
            }
            return resources.render(
                flags: flags, timestamp: timestamp, frameCount: frameCount, output: output,
                bypass: access.bypass.load(ordering: .relaxed), pullInput: pullInput
            )
        }
    }

    private static func supports(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && format.channelCount == 2
            && format.sampleRate.isFinite && format.sampleRate > 0
    }

    private func setTail(frames: Int, sampleRate: Double) {
        tail.store((Double(frames) / sampleRate).bitPattern, ordering: .relaxed)
    }
}

private nonisolated enum SpatialAudioUnitError: LocalizedError, CustomNSError {
    case unsupportedFormat
    case unsupportedFrameCount
    case missingPreset

    static let errorDomain = NSOSStatusErrorDomain

    var errorCode: Int {
        switch self {
        case .unsupportedFormat: Int(kAudioUnitErr_FormatNotSupported)
        case .unsupportedFrameCount: Int(kAudioUnitErr_TooManyFramesToProcess)
        case .missingPreset: Int(kAudioUnitErr_FailedInitialization)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Airwave Spatial requires stereo 32-bit floating-point audio."
        case .unsupportedFrameCount: "The host requested an unsupported render buffer size."
        case .missingPreset: "The bundled Neutral preset is missing."
        }
    }
}
