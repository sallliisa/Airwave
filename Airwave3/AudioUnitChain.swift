import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

enum EffectError: LocalizedError {
    case incompatibleBuses
    case invalidFormat
    case invalidState

    var errorDescription: String? {
        switch self {
        case .incompatibleBuses: "This Audio Unit needs a single stereo input and output."
        case .invalidFormat: "This output's audio format is unavailable."
        case .invalidState: "The saved Audio Unit settings could not be restored."
        }
    }
}

@MainActor
enum EffectCatalog {
    static func discover() -> [EffectComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        var effects: [ComponentID: EffectComponent] = [:]
        for type in types {
            let filter = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            for component in manager.components(matching: filter) {
                let id = ComponentID(component.audioComponentDescription)
                let prefix = component.manufacturerName + ": "
                let name = component.name.hasPrefix(prefix)
                    ? String(component.name.dropFirst(prefix.count))
                    : component.name
                effects[id] = EffectComponent(id: id, name: name, manufacturer: component.manufacturerName)
            }
        }
        return effects.values.sorted {
            let lhs = ($0.name + " " + $0.manufacturer)
            let rhs = ($1.name + " " + $1.manufacturer)
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

final class LiveEffect {
    let slotID: UUID
    let unit: AUAudioUnit
    let stage: EffectRenderStage

    @MainActor
    static func load(
        _ slot: EffectSlot, sampleRate: Double, maximumFrames: UInt32,
        spatialLayout: InputLayout? = nil, equalizerOutput: (uid: String, name: String, channelCount: Int?)? = nil
    ) async throws -> LiveEffect {
        let unit = try await AUAudioUnit.instantiate(with: slot.component.description, options: [])
        try Task.checkCancellation()
        guard unit.inputBusses.count == 1, unit.outputBusses.count == 1 else {
            throw EffectError.incompatibleBuses
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw EffectError.invalidFormat
        }
        var state: [String: Any]?
        if let data = slot.state {
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw EffectError.invalidState
            }
            state = dictionary
        }
        if slot.component == .airwaveEqualizer, let equalizerOutput {
            let previousContext = try EqualizerAUState(state).context
            let context = EqualizerAUState.OutputContext(
                deviceName: equalizerOutput.name, deviceUID: equalizerOutput.uid,
                inputChannelCount: equalizerOutput.channelCount ?? previousContext?.inputChannelCount ?? 2
            )
            state = EqualizerAUState.settingOutputContext(context, in: state)
        }
        if slot.component != .airwaveEqualizer, let state { unit.fullStateForDocument = state }
        let inputFormat: AVAudioFormat
        if slot.component == .airwaveSpatial, let spatialLayout {
            guard let multichannel = spatialLayout.audioFormat(sampleRate: sampleRate) else {
                throw EffectError.invalidFormat
            }
            inputFormat = multichannel
        } else {
            inputFormat = format
        }
        try unit.inputBusses[0].setFormat(inputFormat)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = maximumFrames
        unit.inputBusses[0].isEnabled = true
        if slot.component == .airwaveEqualizer, let state { unit.fullStateForDocument = state }
        try unit.allocateRenderResources()
        return LiveEffect(slotID: slot.id, unit: unit, maximumFrames: maximumFrames,
                          inputChannelCount: Int(inputFormat.channelCount))
    }

    private init(slotID: UUID, unit: AUAudioUnit, maximumFrames: UInt32, inputChannelCount: Int) {
        self.slotID = slotID
        self.unit = unit
        stage = EffectRenderStage(render: unit.renderBlock, maximumFrames: maximumFrames,
                                  inputChannelCount: inputChannelCount)
    }

    func saveState(previous: Data?) throws -> Data? {
        guard let state = unit.fullStateForDocument else { return previous }
        return try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    deinit {
        unit.deallocateRenderResources()
    }
}

final class EffectRenderStage {
    private struct Input {
        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var channels: UnsafePointer<UnsafePointer<Float>?>?
        var frames: UInt32 = 0
        var sampleTime: Float64?
    }

    private let renderBlock: AURenderBlock
    private let pullInput: AURenderPullInputBlock
    private let input: UnsafeMutablePointer<Input>
    private let output: UnsafeMutableAudioBufferListPointer
    private let storage: UnsafeMutablePointer<Float>
    private let pullStorage: UnsafeMutablePointer<Float>
    private let maximumFrames: UInt32
    let inputChannelCount: Int
    let failure = Atomic<OSStatus>(noErr)

    init(render: @escaping AURenderBlock, maximumFrames: UInt32, inputChannelCount: Int = 2) {
        renderBlock = render
        self.maximumFrames = maximumFrames
        self.inputChannelCount = inputChannelCount
        input = .allocate(capacity: 1)
        input.initialize(to: Input())
        output = AudioBufferList.allocate(maximumBuffers: 2)
        output.count = 2
        storage = .allocate(capacity: Int(maximumFrames) * 2)
        pullStorage = .allocate(capacity: Int(maximumFrames) * inputChannelCount)
        let pullStorage = self.pullStorage
        let input = self.input
        pullInput = { _, time, frames, bus, bufferList in
            let sourceBlock = input.pointee
            guard bus == 0, let left = sourceBlock.left, let right = sourceBlock.right else {
                return kAudioUnitErr_InvalidElement
            }
            var offset = 0
            if time.pointee.mFlags.contains(.sampleTimeValid), let start = sourceBlock.sampleTime {
                let delta = time.pointee.mSampleTime - start
                guard delta >= 0, delta <= Double(sourceBlock.frames), let amount = Int(exactly: delta) else {
                    return kAudioUnitErr_TooManyFramesToProcess
                }
                offset = amount
            }
            guard Int(frames) + offset <= Int(sourceBlock.frames) else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            let destination = UnsafeMutableAudioBufferListPointer(bufferList)
            guard destination.count == inputChannelCount else { return kAudioUnitErr_FormatNotSupported }
            let byteCount = Int(frames) * MemoryLayout<Float>.size
            for index in 0..<inputChannelCount {
                let channel = sourceBlock.channels.map { $0[index] } ?? (index == 0 ? left : right)
                guard let source = channel?.advanced(by: offset) else { return kAudioUnitErr_FormatNotSupported }
                if let data = destination[index].mData {
                    guard destination[index].mDataByteSize >= byteCount else {
                        return kAudioUnitErr_TooManyFramesToProcess
                    }
                    if data != UnsafeRawPointer(source) {
                        data.copyMemory(from: source, byteCount: byteCount)
                    }
                } else {
                    let scratch = pullStorage.advanced(by: index * Int(maximumFrames))
                    scratch.update(from: source, count: Int(frames))
                    destination[index].mData = UnsafeMutableRawPointer(scratch)
                }
                destination[index].mDataByteSize = UInt32(byteCount)
                destination[index].mNumberChannels = 1
            }
            return noErr
        }
    }

    func process(
        _ time: UnsafePointer<AudioTimeStamp>, left: UnsafePointer<Float>,
        right: UnsafePointer<Float>, frames: UInt32,
        captured: UnsafeBufferPointer<UnsafePointer<Float>?>? = nil
    ) -> (UnsafePointer<Float>, UnsafePointer<Float>)? {
        guard frames <= maximumFrames, failure.load(ordering: .relaxed) == noErr else { return nil }
        let channels: UnsafePointer<UnsafePointer<Float>?>?
        if inputChannelCount == 2 {
            channels = nil
        } else {
            guard let captured, captured.count == inputChannelCount, let base = captured.baseAddress else {
                failure.store(kAudioUnitErr_FormatNotSupported, ordering: .relaxed)
                return nil
            }
            channels = base
        }
        let sampleTime = time.pointee.mFlags.contains(.sampleTimeValid) ? time.pointee.mSampleTime : nil
        input.pointee = Input(left: left, right: right, channels: channels, frames: frames, sampleTime: sampleTime)
        let rightOutput = storage.advanced(by: Int(maximumFrames))
        let bytes = frames * UInt32(MemoryLayout<Float>.size)
        output.count = 2
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: storage)
        output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: rightOutput)
        var flags: AudioUnitRenderActionFlags = []
        let status = renderBlock(&flags, time, frames, 0, output.unsafeMutablePointer, pullInput)
        guard status == noErr else {
            failure.store(status, ordering: .relaxed)
            return nil
        }
        if flags.contains(.unitRenderAction_OutputIsSilence) {
            memset(storage, 0, Int(bytes))
            memset(rightOutput, 0, Int(bytes))
            return (UnsafePointer(storage), UnsafePointer(rightOutput))
        }
        guard output.count == 2, output[0].mNumberChannels == 1, output[1].mNumberChannels == 1,
              output[0].mDataByteSize >= bytes, output[1].mDataByteSize >= bytes,
              let renderedLeft = output[0].mData?.assumingMemoryBound(to: Float.self),
              let renderedRight = output[1].mData?.assumingMemoryBound(to: Float.self) else {
            failure.store(kAudioUnitErr_FormatNotSupported, ordering: .relaxed)
            return nil
        }
        return (UnsafePointer(renderedLeft), UnsafePointer(renderedRight))
    }

    deinit {
        output.unsafeMutablePointer.deallocate()
        storage.deallocate()
        pullStorage.deallocate()
        input.deinitialize(count: 1)
        input.deallocate()
    }
}

// The control thread owns the references. The HAL callback holds a reader
// count until it finishes with its snapshot, so it never frees an Audio Unit.
final class RenderChain {
    private final class Snapshot {
        let effects: [LiveEffect]
        init(_ effects: [LiveEffect]) { self.effects = effects }
    }

    private let current = Atomic<UnsafeRawPointer?>(nil)
    private let readers = Atomic<Int>(0)
    private var retired: [UnsafeRawPointer] = []
    let callbacks = Atomic<UInt64>(0)

    func replace(with effects: [LiveEffect]) {
        let next = UnsafeRawPointer(Unmanaged.passRetained(Snapshot(effects)).toOpaque())
        if let prior = current.exchange(next, ordering: .sequentiallyConsistent) {
            retired.append(prior)
        }
        reclaim()
    }

    func reclaim() {
        guard readers.load(ordering: .sequentiallyConsistent) == 0 else { return }
        for pointer in retired { Unmanaged<Snapshot>.fromOpaque(pointer).release() }
        retired.removeAll(keepingCapacity: true)
    }

    func render(
        _ time: UnsafePointer<AudioTimeStamp>, _ inputLeft: UnsafePointer<Float>,
        _ inputRight: UnsafePointer<Float>, _ outputLeft: UnsafeMutablePointer<Float>,
        _ outputRight: UnsafeMutablePointer<Float>, _ frames: UInt32
    ) {
        renderCaptured(time, nil, inputLeft, inputRight, outputLeft, outputRight, frames)
    }

    func renderCaptured(
        _ time: UnsafePointer<AudioTimeStamp>, _ captured: UnsafeBufferPointer<UnsafePointer<Float>?>?,
        _ inputLeft: UnsafePointer<Float>, _ inputRight: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, _ frames: UInt32
    ) {
        _ = readers.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer {
            _ = readers.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            _ = callbacks.wrappingAdd(1, ordering: .relaxed)
        }

        var left = inputLeft
        var right = inputRight
        if let pointer = current.load(ordering: .sequentiallyConsistent) {
            let snapshot = Unmanaged<Snapshot>.fromOpaque(pointer).takeUnretainedValue()
            for (index, effect) in snapshot.effects.enumerated() {
                if let result = effect.stage.process(time, left: left, right: right, frames: frames,
                                                     captured: index == 0 ? captured : nil) {
                    (left, right) = result
                }
            }
        }
        let bytes = Int(frames) * MemoryLayout<Float>.size
        memmove(outputLeft, left, bytes)
        memmove(outputRight, right, bytes)
    }

    deinit {
        if let pointer = current.load(ordering: .relaxed) {
            Unmanaged<Snapshot>.fromOpaque(pointer).release()
        }
        for pointer in retired { Unmanaged<Snapshot>.fromOpaque(pointer).release() }
    }
}

private extension InputLayout {
    func audioFormat(sampleRate: Double) -> AVAudioFormat? {
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: header + channels.count * MemoryLayout<AudioChannelDescription>.stride,
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        defer { storage.deallocate() }
        let layout = storage.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mChannelBitmap = []
        layout.pointee.mNumberChannelDescriptions = UInt32(channels.count)
        let descriptions = storage.advanced(by: header).bindMemory(to: AudioChannelDescription.self, capacity: channels.count)
        for (index, speaker) in channels.enumerated() {
            descriptions[index] = AudioChannelDescription(mChannelLabel: speaker.coreAudioLabel, mChannelFlags: [],
                                                           mCoordinates: (0, 0, 0))
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
                             channelLayout: AVAudioChannelLayout(layout: layout))
    }
}

private extension VirtualSpeaker {
    var coreAudioLabel: AudioChannelLabel {
        switch self {
        case .FL: kAudioChannelLabel_Left
        case .FR: kAudioChannelLabel_Right
        case .FC: kAudioChannelLabel_Center
        case .LFE: kAudioChannelLabel_LFEScreen
        case .BL: kAudioChannelLabel_LeftSurroundDirect
        case .BR: kAudioChannelLabel_RightSurroundDirect
        case .SL: kAudioChannelLabel_LeftSurround
        case .SR: kAudioChannelLabel_RightSurround
        case .TFL: kAudioChannelLabel_VerticalHeightLeft
        case .TFR: kAudioChannelLabel_VerticalHeightRight
        case .TBL: kAudioChannelLabel_TopBackLeft
        case .TBR: kAudioChannelLabel_TopBackRight
        case .FLC: kAudioChannelLabel_LeftCenter
        case .FRC: kAudioChannelLabel_RightCenter
        case .BC: kAudioChannelLabel_CenterSurround
        case .custom: kAudioChannelLabel_Unknown
        }
    }
}
