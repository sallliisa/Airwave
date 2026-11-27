import Accelerate
import CoreAudio
import Foundation
import OSLog
import Synchronization

struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
}

typealias StereoRender = (
    UnsafePointer<AudioTimeStamp>, UnsafePointer<Float>, UnsafePointer<Float>,
    UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, UInt32
) -> Void

final class AppMixerGain: Sendable {
    private let target: Atomic<Float>

    init(_ gain: Float) { target = Atomic(gain) }

    fileprivate var value: Float { target.load(ordering: .relaxed) }

    func set(_ gain: Float) { target.store(gain, ordering: .relaxed) }
}

struct AppMixerSource: Equatable {
    let id: String
    let processIDs: [AudioObjectID]
    let gain: AppMixerGain

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sharesTap(with: rhs) && lhs.processIDs == rhs.processIDs
    }

    func sharesTap(with other: Self) -> Bool {
        id == other.id && gain === other.gain
    }
}

enum SystemAudioRouteError: LocalizedError {
    case noOutput
    case permissionDenied
    case unsupportedOutput(String)
    case operation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            "macOS has no current audio output."
        case .permissionDenied:
            "Allow Airwave in Privacy & Security to capture system audio."
        case .unsupportedOutput(let reason):
            reason
        case .operation(let operation, let status):
            "\(operation) failed (Core Audio \(status))."
        }
    }
}

final class SystemAudioRoute {
    static let maximumFrames: UInt32 = 8_192

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SystemAudioHost", category: "Audio route")
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private struct ProcessTap {
        let id: AudioObjectID
        let description: CATapDescription

        func setProcesses(_ processes: [AudioObjectID]) throws {
            guard description.processes != processes else { return }
            let previous = description.processes
            description.processes = processes
            var value = description
            var address = HAL.address(kAudioTapPropertyDescription)
            do {
                try HAL.check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &value),
                              "Update app audio tap")
            } catch {
                description.processes = previous
                throw error
            }
        }
    }

    private struct TapFormat {
        let uid: String
        let channels: Int
        let gain: AppMixerGain?
    }

    private var taps: [ProcessTap] = []
    private var hostProcess: AudioObjectID?
    private var appSources: [AppMixerSource] = []
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var bridge: StereoIOBridge?
    private var running = false

    var hasIOFailure: Bool { bridge?.failed.load(ordering: .relaxed) ?? false }
    var hasRendered: Bool { bridge?.rendered.load(ordering: .relaxed) ?? false }

    func retarget(to sources: [AppMixerSource]) throws -> Bool {
        guard let hostProcess, let remainder = taps.first, sources.count == appSources.count,
              zip(sources, appSources).allSatisfy({ $0.sharesTap(with: $1) }) else { return false }
        let newProcesses = try Self.excludedProcesses(host: hostProcess, sources: sources)
        let oldProcesses = appSources.flatMap(\.processIDs)
        try remainder.setProcesses(Set(newProcesses + oldProcesses).sorted())
        for (tap, source) in zip(taps.dropFirst(), sources) {
            try tap.setProcesses(source.processIDs)
        }
        try remainder.setProcesses(newProcesses)
        appSources = sources
        return true
    }

    static func currentOutput() throws -> OutputDevice {
        let id = try HAL.read(kAudioHardwarePropertyDefaultOutputDevice, of: system, as: AudioDeviceID.self)
        guard id != kAudioObjectUnknown else { throw SystemAudioRouteError.noOutput }
        return try describeOutput(id)
    }

    static func availableOutputs() -> [OutputDevice] {
        guard let ids = try? HAL.deviceIDs() else { return [] }
        return ids.compactMap { id in
            guard let transport = try? HAL.read(kAudioDevicePropertyTransportType, of: id, as: UInt32.self),
                  transport != kAudioDeviceTransportTypeVirtual, transport != kAudioDeviceTransportTypeAggregate,
                  let widths = try? HAL.channelWidths(of: id, scope: kAudioObjectPropertyScopeOutput),
                  widths.contains(where: { $0 > 0 }) else { return nil }
            return try? describeOutput(id)
        }
    }

    private static func describeOutput(_ id: AudioDeviceID) throws -> OutputDevice {
        try OutputDevice(
            id: id,
            uid: HAL.string(kAudioDevicePropertyDeviceUID, of: id),
            name: HAL.string(kAudioObjectPropertyName, of: id),
            sampleRate: HAL.read(kAudioDevicePropertyNominalSampleRate, of: id, as: Double.self)
        )
    }

    init(output: OutputDevice, verification: Bool = false, appSources: [AppMixerSource] = [],
         render: @escaping StereoRender) throws {
        do {
            try prepare(output: output, verification: verification, appSources: appSources, render: render)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func start() throws {
        guard !running else { return }
        guard let io, let bridge else { throw SystemAudioRouteError.noOutput }
        bridge.enabled.store(true, ordering: .releasing)
        running = true
        try HAL.check(AudioDeviceStart(aggregate, io), "Start system audio")
    }

    @discardableResult
    func stop() -> Bool {
        if running, let io {
            let status = AudioDeviceStop(aggregate, io)
            guard status == kAudioHardwareNotRunningError || Self.released(status, operation: "Stop audio I/O") else {
                if restoreNativePlayback() {
                    bridge?.enabled.store(false, ordering: .releasing)
                }
                return false
            }
            running = false
        }
        bridge?.enabled.store(false, ordering: .releasing)
        if let io {
            let status = AudioDeviceDestroyIOProcID(aggregate, io)
            guard Self.released(status, operation: "Release audio I/O") else { return false }
            self.io = nil
            bridge = nil
        }
        if aggregate != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            guard Self.released(status, operation: "Release private audio device") else { return false }
            aggregate = kAudioObjectUnknown
        }
        for index in taps.indices.reversed() {
            let status = AudioHardwareDestroyProcessTap(taps[index].id)
            if Self.released(status, operation: "Release system audio tap") {
                taps.remove(at: index)
            }
        }
        return taps.isEmpty
    }

    private func restoreNativePlayback() -> Bool {
        var restored = true
        for tap in taps where tap.description.muteBehavior != .unmuted {
            let previous = tap.description.muteBehavior
            tap.description.muteBehavior = .unmuted
            var description = tap.description
            var address = HAL.address(kAudioTapPropertyDescription)
            let status = withUnsafePointer(to: &description) {
                AudioObjectSetPropertyData(tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if !Self.released(status, operation: "Restore native playback") {
                tap.description.muteBehavior = previous
                restored = false
            }
        }
        return restored
    }

    private static func released(_ status: OSStatus, operation: String) -> Bool {
        if status == noErr || status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError {
            return true
        }
        log.error("\(operation, privacy: .public) failed (\(status))")
        return false
    }

    private func prepare(output: OutputDevice, verification: Bool, appSources: [AppMixerSource],
                         render: @escaping StereoRender) throws {
        let transport = try HAL.read(kAudioDevicePropertyTransportType, of: output.id, as: UInt32.self)
        guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else {
            throw SystemAudioRouteError.unsupportedOutput("\(output.name) uses a virtual or aggregate audio route.")
        }
        let destination = try DeviceDestination(output)
        let sources = verification ? [] : appSources
        let host = verification ? nil : try HAL.processID()
        self.hostProcess = host
        self.appSources = sources
        let excluded = try host.map { try Self.excludedProcesses(host: $0, sources: sources) } ?? []
        let remainder = CATapDescription(excludingProcesses: excluded, deviceUID: output.uid, stream: destination.stream)
        var formats = [try createTap(remainder, name: "Airwave", gain: nil,
                                     output: output, destination: destination, verification: verification)]
        for source in sources {
            let description = CATapDescription(processes: source.processIDs, deviceUID: output.uid, stream: destination.stream)
            formats.append(try createTap(description, name: "Airwave: \(source.id)", gain: source.gain,
                                         output: output, destination: destination, verification: verification))
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Airwave",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: formats.map { [
                kAudioSubTapUIDKey: $0.uid,
                kAudioSubTapDriftCompensationKey: true
            ] }
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create private audio device")

        let inputScope = kAudioObjectPropertyScopeInput
        let outputScope = kAudioObjectPropertyScopeOutput
        let deviceInputs = try HAL.channelWidths(of: output.id, scope: inputScope)
        let aggregateInputs = try HAL.channelWidths(of: aggregate, scope: inputScope)
        let aggregateOutputs = try HAL.channelWidths(of: aggregate, scope: outputScope)
        let aggregateRate = try HAL.read(kAudioDevicePropertyNominalSampleRate, of: aggregate, as: Double.self)
        let frameSize = try HAL.read(kAudioDevicePropertyBufferFrameSize, of: aggregate, as: UInt32.self)
        guard Array(aggregateInputs.prefix(deviceInputs.count)) == deviceInputs,
              aggregateInputs.dropFirst(deviceInputs.count).reduce(0, +) == formats.reduce(0, { $0 + $1.channels }),
              aggregateOutputs == destination.bufferWidths,
              aggregateRate == output.sampleRate,
              (1...Self.maximumFrames).contains(frameSize) else {
            throw SystemAudioRouteError.unsupportedOutput("Core Audio changed the tap or output format during setup.")
        }
        if formats.count > 1 {
            let tapUIDs = try HAL.read(kAudioAggregateDevicePropertyTapList, of: aggregate, as: Unmanaged<CFArray>.self)
                .takeRetainedValue() as NSArray
            guard tapUIDs as? [String] == formats.map(\.uid) else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio changed the order of the app audio taps.")
            }
        }
        var tapStart = deviceInputs.reduce(0, +)
        var tapInputs: [StereoTapInput] = []
        for format in formats {
            guard let left = BufferChannel.at(tapStart, widths: aggregateInputs), left.offset == 0,
                  let right = BufferChannel.at(tapStart + format.channels - 1, widths: aggregateInputs),
                  right.offset == right.stride - 1 else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio did not expose the system audio tap channels.")
            }
            tapInputs.append(StereoTapInput(left: left, right: right, gain: format.gain))
            tapStart += format.channels
        }
        let bridge = StereoIOBridge(
            tapInputs: tapInputs, sampleRate: output.sampleRate,
            outputLeft: destination.left, outputRight: destination.right,
            verification: verification, render: render
        )
        self.bridge = bridge
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, timestamp in
            bridge.process(input: input, output: output, timestamp: timestamp)
        }, "Register audio I/O")
        if !deviceInputs.isEmpty, let io {
            try HAL.disableHardwareInputs(on: aggregate, io: io, hardware: output.id)
        }
    }

    private static func excludedProcesses(host: AudioObjectID, sources: [AppMixerSource]) throws -> [AudioObjectID] {
        let processIDs = [host] + sources.flatMap(\.processIDs)
        guard Set(processIDs).count == processIDs.count else {
            throw SystemAudioRouteError.unsupportedOutput("An audio process belongs to more than one app mixer source.")
        }
        return processIDs.sorted()
    }

    private func createTap(_ description: CATapDescription, name: String, gain: AppMixerGain?,
                           output: OutputDevice, destination: DeviceDestination, verification: Bool) throws -> TapFormat {
        description.name = name
        description.isPrivate = true
        description.isMixdown = destination.streamChannels > 2
        description.isMono = false
        description.muteBehavior = verification ? .unmuted : .mutedWhenTapped
        var id = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateProcessTap(description, &id), "Create system audio tap")
        taps.append(ProcessTap(id: id, description: description))
        let uid = try HAL.string(kAudioTapPropertyUID, of: id)
        let format = try HAL.read(kAudioTapPropertyFormat, of: id, as: AudioStreamBasicDescription.self)
        let channels = Int(format.mChannelsPerFrame)
        guard (1...2).contains(channels), HAL.isFloatPCM(format, at: output.sampleRate) else {
            throw SystemAudioRouteError.unsupportedOutput("Core Audio did not provide a mono or stereo tap at the output sample rate.")
        }
        return TapFormat(uid: uid, channels: channels, gain: gain)
    }
}

private struct DeviceDestination {
    let stream: UInt
    let streamChannels: Int
    let bufferWidths: [Int]
    let left: BufferChannel
    let right: BufferChannel

    init(_ output: OutputDevice) throws {
        let scope = kAudioObjectPropertyScopeOutput
        let widths = try HAL.channelWidths(of: output.id, scope: scope)
        let preferred = HAL.preferredStereoChannels(of: output.id, channelCount: widths.reduce(0, +))
        guard let left = BufferChannel.at(preferred.0, widths: widths),
              let right = BufferChannel.at(preferred.1, widths: widths) else {
            throw SystemAudioRouteError.unsupportedOutput("\(output.name) has no usable playback channels.")
        }
        for (index, stream) in try HAL.streams(of: output.id, scope: scope).enumerated() {
            let first = try HAL.read(kAudioStreamPropertyStartingChannel, of: stream, as: UInt32.self)
            let format = try HAL.read(kAudioStreamPropertyVirtualFormat, of: stream, as: AudioStreamBasicDescription.self)
            let channelCount = Int(format.mChannelsPerFrame)
            let start = max(0, Int(first) - 1)
            let range = start..<(start + channelCount)
            if range.contains(preferred.0), range.contains(preferred.1), HAL.isFloatPCM(format, at: output.sampleRate) {
                self.stream = UInt(index)
                self.streamChannels = channelCount
                self.bufferWidths = widths
                self.left = left
                self.right = right
                return
            }
        }
        throw SystemAudioRouteError.unsupportedOutput("\(output.name) has no compatible mono or stereo playback stream.")
    }
}

struct BufferChannel: Equatable {
    let buffer: Int
    let offset: Int
    let stride: Int

    static func at(_ channel: Int, widths: [Int]) -> Self? {
        var offset = channel
        for (buffer, width) in widths.enumerated() {
            if (0..<width).contains(offset) { return Self(buffer: buffer, offset: offset, stride: width) }
            offset -= width
        }
        return nil
    }

    func samples(in buffers: UnsafeMutableAudioBufferListPointer) -> (data: UnsafeMutablePointer<Float>?, frames: Int)? {
        guard buffer < buffers.count else { return nil }
        let entry = buffers[buffer]
        let frameBytes = stride * MemoryLayout<Float>.size
        guard entry.mNumberChannels == stride,
              Int(entry.mDataByteSize) % frameBytes == 0 else { return nil }
        let data = entry.mData?.assumingMemoryBound(to: Float.self).advanced(by: offset)
        return (data, Int(entry.mDataByteSize) / frameBytes)
    }
}

final class StereoTapInput {
    private let left: BufferChannel
    private let right: BufferChannel
    private let gain: AppMixerGain?
    private var currentGain: Float

    init(left: BufferChannel, right: BufferChannel, gain: AppMixerGain?) {
        self.left = left
        self.right = right
        self.gain = gain
        currentGain = gain?.value ?? 1
    }

    func mix(from buffers: UnsafeMutableAudioBufferListPointer, into mixedLeft: UnsafeMutablePointer<Float>,
             _ mixedRight: UnsafeMutablePointer<Float>, frames: Int, gainStep: Float) -> Bool {
        guard let sourceLeft = left.samples(in: buffers), let sourceRight = right.samples(in: buffers) else { return false }
        let targetGain = gain?.value ?? 1
        let count = min(sourceLeft.frames, sourceRight.frames, frames)
        guard let leftData = sourceLeft.data, let rightData = sourceRight.data, count > 0 else {
            currentGain = targetGain
            return true
        }

        var frame = 0
        var level = currentGain
        while frame < count, level != targetGain {
            let distance = targetGain - level
            if abs(distance) <= gainStep {
                level = targetGain
            } else {
                level += distance > 0 ? gainStep : -gainStep
            }
            mixedLeft[frame] += leftData[frame * left.stride] * level
            mixedRight[frame] += rightData[frame * right.stride] * level
            frame += 1
        }
        currentGain = level
        guard frame < count, level != 0 else { return true }
        let length = vDSP_Length(count - frame)
        let sourceL = leftData.advanced(by: frame * left.stride)
        let sourceR = rightData.advanced(by: frame * right.stride)
        let mixL = mixedLeft.advanced(by: frame)
        let mixR = mixedRight.advanced(by: frame)
        if left.stride == 2, right.stride == 2 {
            for i in 0..<(count - frame) {
                mixL[i] += sourceL[2 * i] * level
                mixR[i] += sourceR[2 * i] * level
            }
        } else if level == 1 {
            vDSP_vadd(sourceL, left.stride, mixL, 1, mixL, 1, length)
            vDSP_vadd(sourceR, right.stride, mixR, 1, mixR, 1, length)
        } else {
            vDSP_vsma(sourceL, left.stride, &level, mixL, 1, mixL, 1, length)
            vDSP_vsma(sourceR, right.stride, &level, mixR, 1, mixR, 1, length)
        }
        return true
    }
}

final class StereoIOBridge: @unchecked Sendable {
    let enabled = Atomic(false)
    let failed = Atomic(false)
    let rendered = Atomic(false)

    private let tapInputs: [StereoTapInput]
    private let gainStep: Float
    private let outputLeft: BufferChannel
    private let outputRight: BufferChannel
    private let verification: Bool
    private let render: StereoRender
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4 * Int(SystemAudioRoute.maximumFrames))
    private var invalidCycles = 0

    init(tapInputs: [StereoTapInput], sampleRate: Double, outputLeft: BufferChannel, outputRight: BufferChannel,
         verification: Bool, render: @escaping StereoRender) {
        self.tapInputs = tapInputs
        gainStep = 1 / Float(sampleRate * 0.01)
        self.outputLeft = outputLeft
        self.outputRight = outputRight
        self.verification = verification
        self.render = render
    }

    deinit { storage.deallocate() }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                 timestamp: UnsafePointer<AudioTimeStamp>) {
        guard enabled.load(ordering: .acquiring) else { return }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let leftOutput = outputLeft.samples(in: outputs), let leftData = leftOutput.data,
              let rightOutput = outputRight.samples(in: outputs), let rightData = rightOutput.data else {
            recordInvalidCycle()
            return
        }
        let frames = min(leftOutput.frames, rightOutput.frames)
        let capacity = Int(SystemAudioRoute.maximumFrames)
        guard frames > 0 else { return }
        guard frames <= capacity else {
            failed.store(true, ordering: .relaxed)
            return
        }
        let left = storage
        let right = storage.advanced(by: capacity)
        let bytes = frames * MemoryLayout<Float>.size
        memset(left, 0, bytes)
        memset(right, 0, bytes)
        for tap in tapInputs {
            guard tap.mix(from: inputs, into: left, right, frames: frames, gainStep: gainStep) else {
                recordInvalidCycle()
                return
            }
        }
        invalidCycles = 0
        if !verification, outputLeft.stride == 1, outputRight.stride == 1, outputLeft != outputRight {
            render(timestamp, left, right, leftData, rightData, UInt32(frames))
            rendered.store(true, ordering: .relaxed)
            return
        }
        let processedLeft = storage.advanced(by: 2 * capacity)
        let processedRight = storage.advanced(by: 3 * capacity)
        render(timestamp, left, right, processedLeft, processedRight, UInt32(frames))
        rendered.store(true, ordering: .relaxed)
        guard !verification else { return }
        if outputLeft == outputRight {
            for frame in 0..<frames {
                leftData[frame * outputLeft.stride] = (processedLeft[frame] + processedRight[frame]) * 0.5
            }
        } else {
            copyChannel(processedLeft, to: leftData, stride: outputLeft.stride, frames: frames)
            copyChannel(processedRight, to: rightData, stride: outputRight.stride, frames: frames)
        }
    }

    private func recordInvalidCycle() {
        invalidCycles += 1
        if invalidCycles >= 4 { failed.store(true, ordering: .relaxed) }
    }

    private func copyChannel(_ input: UnsafePointer<Float>, to output: UnsafeMutablePointer<Float>,
                             stride outputStride: Int, frames: Int) {
        if outputStride == 1 {
            output.update(from: input, count: frames)
        } else {
            for frame in 0..<frames { output[frame * outputStride] = input[frame] }
        }
    }
}

enum HAL {
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status == kAudioDevicePermissionsError { throw SystemAudioRouteError.permissionDenied }
        guard status == noErr else { throw SystemAudioRouteError.operation(operation, status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ selector: AudioObjectPropertySelector, of id: AudioObjectID,
                        as _: T.Type, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { value in
            let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, value.baseAddress!)
            try check(status, "Read audio property \(fourCC(selector))")
            guard size == MemoryLayout<T>.size else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio returned an unexpected property size.")
            }
            return value[0]
        }
    }

    static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) throws -> String {
        try read(selector, of: id, as: Unmanaged<CFString>.self).takeRetainedValue() as String
    }

    static func processID(_ pid: pid_t = getpid()) throws -> AudioObjectID {
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Resolve audio process")
        guard process != kAudioObjectUnknown else { throw SystemAudioRouteError.noOutput }
        return process
    }

    static func channelWidths(of id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        try readBuffer(kAudioDevicePropertyStreamConfiguration, of: id, scope: scope) { raw, size in
            guard size >= MemoryLayout<UInt32>.size else { return [] }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            let head = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
            guard list.count == 0 || size >= head + list.count * MemoryLayout<AudioBuffer>.stride else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio returned invalid stream geometry.")
            }
            return list.map { Int($0.mNumberChannels) }
        }
    }

    static func deviceIDs() throws -> [AudioDeviceID] {
        try readIDs(
            kAudioHardwarePropertyDevices, of: AudioObjectID(kAudioObjectSystemObject),
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    static func streams(of id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        try readIDs(kAudioDevicePropertyStreams, of: id, scope: scope)
    }

    static func readIDs(
        _ selector: AudioObjectPropertySelector, of id: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        try readBuffer(selector, of: id, scope: scope) { raw, size in
            let stride = MemoryLayout<AudioObjectID>.stride
            guard size % stride == 0 else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio returned an invalid stream list.")
            }
            return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: AudioObjectID.self), count: size / stride))
        }
    }

    static func preferredStereoChannels(of id: AudioObjectID, channelCount: Int) -> (Int, Int) {
        guard channelCount > 1 else { return (0, 0) }
        var property = address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var values: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout.size(ofValue: values))
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &values)
        guard status == noErr, size == MemoryLayout.size(ofValue: values), values.0 != values.1,
              (1...channelCount).contains(Int(values.0)),
              (1...channelCount).contains(Int(values.1)) else { return (0, 1) }
        return (Int(values.0) - 1, Int(values.1) - 1)
    }

    static func disableHardwareInputs(on aggregate: AudioDeviceID, io: AudioDeviceIOProcID, hardware: AudioDeviceID) throws {
        let scope = kAudioObjectPropertyScopeInput
        let physicalCount = try streams(of: hardware, scope: scope).count
        let aggregateCount = try streams(of: aggregate, scope: scope).count
        guard physicalCount > 0, aggregateCount > physicalCount else {
            throw SystemAudioRouteError.unsupportedOutput("Core Audio could not isolate the system audio tap from hardware inputs.")
        }
        var property = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = flagsOffset + aggregateCount * MemoryLayout<UInt32>.stride
        try withUnsafeTemporaryAllocation(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment) { storage in
            let raw = storage.baseAddress!
            let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
            usage.pointee = AudioHardwareIOProcStreamUsage(mIOProc: unsafeBitCast(io, to: UnsafeMutableRawPointer.self),
                                                          mNumberStreams: UInt32(aggregateCount), mStreamIsOn: 0)
            let flags = raw.advanced(by: flagsOffset).assumingMemoryBound(to: UInt32.self)
            for index in 0..<aggregateCount { flags[index] = index < physicalCount ? 0 : 1 }
            try check(AudioObjectSetPropertyData(aggregate, &property, 0, nil, UInt32(size), raw), "Exclude hardware inputs")
        }
    }

    static func isFloatPCM(_ format: AudioStreamBasicDescription, at sampleRate: Double) -> Bool {
        let width = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0) ? 1 : format.mChannelsPerFrame
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == kAudioFormatFlagIsFloat
            && format.mBitsPerChannel == 32 && format.mFramesPerPacket == 1
            && format.mBytesPerFrame == width * UInt32(MemoryLayout<Float>.size)
            && format.mSampleRate == sampleRate
    }

    private static func readBuffer<T>(_ selector: AudioObjectPropertySelector, of id: AudioObjectID,
                                      scope: AudioObjectPropertyScope, decode: (UnsafeMutableRawPointer, Int) throws -> T) throws -> T {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read audio property size \(fourCC(selector))")
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(size)), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        if size > 0 {
            try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage), "Read audio property \(fourCC(selector))")
        }
        return try decode(storage, Int(size))
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}
