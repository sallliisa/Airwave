import AudioToolbox
import AVFoundation
import Foundation
import os
import Synchronization

nonisolated final class AirwaveSpatialAudioUnit: AUAudioUnit {
    static let presetDidChange = Notification.Name("AirwaveSpatialPresetDidChange")

    enum BundledPreset: String, CaseIterable {
        case neutral, room, stage

        var title: String { rawValue.capitalized }
        var libraryName: String { title + "SH1.0" }

        var url: URL? {
            Bundle(for: AirwaveSpatialAudioUnit.self).url(forResource: libraryName, withExtension: "wav")
        }

        func waveform() throws -> Data {
            guard let url else { throw SpatialAudioUnitError.missingPreset(libraryName) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    enum PresetSelection: Equatable {
        case none
        case bundled(BundledPreset)
        case imported(name: String)
    }

    private enum Preset {
        case none
        case bundled(BundledPreset)
        case imported(name: String, wav: Data)

        init?(document: [String: Any]) {
            if document[StateKey.noPreset] as? Bool == true {
                self = .none
            } else if let wav = document[StateKey.impulseResponse] as? Data,
                      let name = document[StateKey.presetName] as? String,
                      !wav.isEmpty, wav.count <= WAVLoader.maximumFileSize {
                self = .imported(name: name, wav: wav)
            } else if let name = document[StateKey.bundledPreset] as? String,
                      let preset = BundledPreset(rawValue: name) {
                self = .bundled(preset)
            } else {
                return nil
            }
        }

        var document: [String: Any] {
            switch self {
            case .none: [StateKey.noPreset: true]
            case .bundled(let preset): [StateKey.bundledPreset: preset.rawValue]
            case .imported(let name, let wav): [StateKey.presetName: name, StateKey.impulseResponse: wav]
            }
        }

        func waveform() throws -> Data {
            switch self {
            case .none: throw SpatialAudioUnitError.invalidPreset
            case .bundled(let bundled): return try bundled.waveform()
            case .imported(_, let wav): return wav
            }
        }

        func prepare(sampleRate: Double, layout: SpatialInputLayout) throws -> SpatialProcessor? {
            let url: URL
            let temporaryURL: URL?
            switch self {
            case .none:
                return nil
            case .bundled(let preset):
                guard let resource = preset.url else {
                    throw SpatialAudioUnitError.missingPreset(preset.title)
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
            return try SpatialProcessor(url: url, sampleRate: sampleRate, layout: layout)
        }
    }

    private struct State {
        var preset: Preset = .bundled(.neutral)
        var userPreset: AUAudioUnitPreset?
        var resources: SpatialRenderResources?
    }

    private enum StateKey {
        static let bundledPreset = "AirwaveSpatial.bundledPreset"
        static let presetName = "AirwaveSpatial.presetName"
        static let impulseResponse = "AirwaveSpatial.impulseResponse"
        static let bypass = "AirwaveSpatial.bypass"
        static let noPreset = "AirwaveSpatial.noPreset"
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let presetStore: NativeUserPresetStore
    private let renderAccess = SpatialRenderAccess()
    private let tail = Atomic<UInt64>(0)
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override convenience init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try self.init(componentDescription: componentDescription, options: options,
                      presetStore: NativeUserPresetStore(effect: "Spatial"))
    }

    init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = [],
         presetStore: NativeUserPresetStore) throws {
        self.presetStore = presetStore
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw SpatialAudioUnitError.unsupportedFormat
        }
        inputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = AUAudioChannelCount(SpatialInputLayout.maximumChannelCount)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.supportedChannelCounts = [2]
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        if let url = BundledPreset.neutral.url, let header = try? WAVLoader.headerInfo(from: url) {
            setTail(frames: max(0, header.frameCount - 1), sampleRate: header.sampleRate)
        }
    }

    deinit {
        renderAccess.resources.store(nil, ordering: .releasing)
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? {
        (1...SpatialInputLayout.maximumChannelCount).flatMap { [NSNumber(value: $0), 2] }
    }
    override var canProcessInPlace: Bool { inputBus.format.channelCount == outputBus.format.channelCount }
    override var latency: TimeInterval { 0 }
    override var tailTime: TimeInterval {
        Double(bitPattern: tail.load(ordering: .relaxed))
    }

    override var supportsUserPresets: Bool { true }
    @objc dynamic override var userPresets: [AUAudioUnitPreset] {
        try? presetStore.seedDefaults({
            try BundledPreset.allCases.map { bundled in
                let preset = Preset.imported(name: bundled.libraryName, wav: try bundled.waveform())
                return (bundled.libraryName, preset.document)
            }
        }, matches: { expected, saved in
            guard let expectedWAV = expected[StateKey.impulseResponse] as? Data,
                  let preset = Preset(document: saved) else { return false }
            return (try? preset.waveform()) == expectedWAV
        })
        return presetStore.presets
    }

    override func saveUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        let preset = state.withLockUnchecked { $0.preset }
        if case .none = preset { throw SpatialAudioUnitError.invalidPreset }
        willChangeValue(forKey: "userPresets")
        defer { didChangeValue(forKey: "userPresets") }
        try presetStore.save(userPreset, state: preset.document)
    }

    override func deleteUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        willChangeValue(forKey: "userPresets")
        defer { didChangeValue(forKey: "userPresets") }
        try presetStore.delete(userPreset)
        state.withLockUnchecked { current in
            if current.userPreset?.name == userPreset.name { current.userPreset = nil }
        }
        NotificationCenter.default.post(name: Self.presetDidChange, object: self)
    }

    override func presetState(for userPreset: AUAudioUnitPreset) throws -> [String: Any] {
        try presetStore.state(for: userPreset)
    }

    func renameUserPreset(_ preset: AUAudioUnitPreset, to name: String) throws {
        let selected = selectedUserPreset(in: [preset]) != nil
        let wav = selected ? try state.withLockUnchecked { try $0.preset.waveform() } : nil
        willChangeValue(forKey: "userPresets")
        defer { didChangeValue(forKey: "userPresets") }
        try presetStore.rename(preset, to: name)
        if let wav {
            state.withLockUnchecked { current in
                current.preset = .imported(name: preset.name, wav: wav)
                current.userPreset = preset
            }
        }
        NotificationCenter.default.post(name: Self.presetDidChange, object: self)
    }

    override var currentPreset: AUAudioUnitPreset? {
        get { selectedUserPreset(in: userPresets) }
        set {
            guard let preset = newValue else { return }
            if preset.number < 0 {
                try? useUserPreset(preset)
            } else if BundledPreset.allCases.indices.contains(preset.number) {
                try? useBundledPreset(BundledPreset.allCases[preset.number])
            }
        }
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
            snapshot[StateKey.bundledPreset] = nil
            snapshot[StateKey.presetName] = nil
            snapshot[StateKey.impulseResponse] = nil
            snapshot[StateKey.noPreset] = nil
            snapshot.merge(preset.document) { _, presetValue in presetValue }
            return snapshot
        }
        set {
            super.fullState = newValue
            shouldBypassEffect = newValue?[StateKey.bypass] as? Bool ?? false
            let preset = newValue.flatMap(Preset.init(document:)) ?? .bundled(.neutral)
            do { try selectPreset(preset) }
            catch { try? selectPreset(.bundled(.neutral)) }
        }
    }

    var presetSelection: PresetSelection {
        state.withLockUnchecked { current in
            switch current.preset {
            case .none: .none
            case .bundled(let preset): .bundled(preset)
            case .imported(let name, _): .imported(name: name)
            }
        }
    }

    func useBundledPreset(_ preset: BundledPreset) throws {
        try selectPreset(.bundled(preset))
    }

    func useUserPreset(_ preset: AUAudioUnitPreset) throws {
        let document = try presetState(for: preset)
        guard let saved = Preset(document: document) else { throw SpatialAudioUnitError.invalidPreset }
        let selection = Preset.imported(name: preset.name, wav: try saved.waveform())
        try selectPreset(selection, userPreset: preset)
    }

    func selectedUserPreset(in saved: [AUAudioUnitPreset]) -> AUAudioUnitPreset? {
        let (selected, reference) = state.withLockUnchecked { ($0.preset, $0.userPreset) }
        if let reference, let preset = saved.first(where: { $0.number == reference.number && $0.name == reference.name }) {
            return preset
        }
        guard !saved.isEmpty, let wav = try? selected.waveform() else { return nil }
        func matches(_ preset: AUAudioUnitPreset) -> Bool {
            guard let document = try? presetState(for: preset), let stored = Preset(document: document) else { return false }
            return (try? stored.waveform()) == wav
        }
        switch selected {
        case .none: return nil
        case .bundled(let bundled):
            return saved.first(where: { $0.name == bundled.libraryName && matches($0) }) ?? saved.first(where: matches)
        case .imported(let name, _):
            return saved.first(where: { $0.name == name && matches($0) })
        }
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
        let baseName = url.deletingPathExtension().lastPathComponent
        let saved = userPresets
        let names = Set(saved.map { $0.name.lowercased() })
        var name = baseName
        var suffix = 2
        while names.contains(name.lowercased()) {
            name = "\(baseName) (\(suffix))"
            suffix += 1
        }
        let reference = AUAudioUnitPreset()
        reference.name = name
        let numbers = Set(saved.map(\.number))
        reference.number = -1
        while numbers.contains(reference.number) { reference.number -= 1 }

        let previous = state.withLockUnchecked { ($0.preset, $0.userPreset) }
        try selectPreset(.imported(name: name, wav: wav), userPreset: reference)
        do {
            try saveUserPreset(reference)
        } catch {
            try? selectPreset(previous.0, userPreset: previous.1)
            throw error
        }
    }

    private func selectPreset(_ preset: Preset, userPreset: AUAudioUnitPreset? = nil) throws {
        try state.withLockUnchecked { current in
            guard let layout = current.resources?.layout ?? SpatialInputLayout(format: inputBus.format) else {
                throw SpatialAudioUnitError.unsupportedFormat
            }
            let sampleRate = current.resources?.sampleRate ?? outputBus.format.sampleRate
            let processor = try preset.prepare(sampleRate: sampleRate, layout: layout)
            if let resources = current.resources {
                resources.publish(processor)
            }
            current.preset = preset
            current.userPreset = userPreset
            setTail(frames: processor?.tailFrames ?? 0, sampleRate: sampleRate)
        }
        NotificationCenter.default.post(name: Self.presetDidChange, object: self)
    }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        Self.supportsPCM(format)
            && (bus === inputBus ? SpatialInputLayout(format: format) != nil : format.channelCount == 2)
            && super.shouldChange(to: format, for: bus)
    }

    override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format
        guard Self.supportsPCM(input), Self.supportsPCM(output), output.channelCount == 2,
              input.sampleRate == output.sampleRate, let layout = SpatialInputLayout(format: input) else {
            throw SpatialAudioUnitError.unsupportedFormat
        }

        let maxFrames = Int(maximumFramesToRender)
        guard (1...65_536).contains(maxFrames) else {
            throw SpatialAudioUnitError.unsupportedFrameCount
        }
        try super.allocateRenderResources()
        do {
            try state.withLockUnchecked { current in
                let processor = try current.preset.prepare(sampleRate: output.sampleRate, layout: layout)
                let resources = SpatialRenderResources(
                    processor: processor,
                    layout: layout,
                    sampleRate: output.sampleRate,
                    maxFrames: maxFrames,
                    inputInterleaved: input.isInterleaved,
                    outputInterleaved: output.isInterleaved
                )
                current.resources = resources
                setTail(frames: processor?.tailFrames ?? 0, sampleRate: output.sampleRate)
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

    private static func supportsPCM(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && format.sampleRate.isFinite && format.sampleRate > 0
    }

    private func setTail(frames: Int, sampleRate: Double) {
        tail.store((Double(frames) / sampleRate).bitPattern, ordering: .relaxed)
    }
}

private nonisolated enum SpatialAudioUnitError: LocalizedError, CustomNSError {
    case unsupportedFormat
    case unsupportedFrameCount
    case missingPreset(String)
    case invalidPreset

    static let errorDomain = NSOSStatusErrorDomain

    var errorCode: Int {
        switch self {
        case .unsupportedFormat: Int(kAudioUnitErr_FormatNotSupported)
        case .unsupportedFrameCount: Int(kAudioUnitErr_TooManyFramesToProcess)
        case .missingPreset: Int(kAudioUnitErr_FailedInitialization)
        case .invalidPreset: Int(kAudioUnitErr_InvalidPropertyValue)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Airwave Spatial requires 32-bit floating-point input and stereo output at the same sample rate."
        case .unsupportedFrameCount: "The host requested an unsupported render buffer size."
        case .missingPreset(let name): "The bundled \(name) preset is missing."
        case .invalidPreset: "This preset does not contain a Spatial impulse response."
        }
    }
}
