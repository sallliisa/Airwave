import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization

struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    let routing: OutputDeviceDescriptor?

    init(id: AudioDeviceID, uid: String, name: String, sampleRate: Double, routing: OutputDeviceDescriptor? = nil) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.routing = routing
    }

    var captureLayout: InputLayout? {
        guard let routing, case .resolved(let route) = OutputRoutingResolver.resolve(output: routing) else { return nil }
        return route.inputLayout
    }

    var capturedChannelCount: Int? {
        captureLayout?.channels.count ?? routing.map { min($0.outputChannelCount, 2) }
    }
}

typealias CapturedRender = (
    UnsafePointer<AudioTimeStamp>, UnsafeBufferPointer<UnsafePointer<Float>?>?,
    UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>,
    UnsafeMutablePointer<Float>, UInt32
) -> Void

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
        let uid = try HAL.string(kAudioDevicePropertyDeviceUID, of: id)
        let name = try HAL.string(kAudioObjectPropertyName, of: id)
        let sampleRate = try HAL.read(kAudioDevicePropertyNominalSampleRate, of: id, as: Double.self)
        let transport = try HAL.read(kAudioDevicePropertyTransportType, of: id, as: UInt32.self)
        let scope = kAudioObjectPropertyScopeOutput
        let channelCount = ((try? HAL.channelWidths(of: id, scope: scope)) ?? []).reduce(0, +)
        let streams = (try? HAL.streams(of: id, scope: scope)) ?? []
        let ranges = streams.enumerated().compactMap { index, stream -> OutputStreamDescriptor? in
            guard let start = try? HAL.read(kAudioStreamPropertyStartingChannel, of: stream, as: UInt32.self),
                  let format = try? HAL.read(kAudioStreamPropertyVirtualFormat, of: stream, as: AudioStreamBasicDescription.self)
            else { return nil }
            return OutputStreamDescriptor(streamIndex: index, startingChannel: Int(start), channelCount: Int(format.mChannelsPerFrame))
        }
        let preferred = HAL.preferredStereoChannels(of: id, channelCount: channelCount)
        let descriptor = OutputDeviceDescriptor(
            id: .init(UInt64(id)), uid: uid, name: name, transport: "",
            channelLabels: channelCount > 2 ? HAL.channelLabels(of: id, channelCount: channelCount) : nil,
            outputChannelCount: channelCount, nominalSampleRate: sampleRate,
            isVirtual: transport == kAudioDeviceTransportTypeVirtual,
            isAggregate: transport == kAudioDeviceTransportTypeAggregate,
            outputStreamCount: streams.count, outputStreams: ranges,
            preferredStereoChannels: StereoOutputChannels(left: preferred.0 + 1, right: preferred.1 + 1)
        )
        return OutputDevice(id: id, uid: uid, name: name, sampleRate: sampleRate, routing: descriptor)
    }

    init(output: OutputDevice, verification: Bool = false, appSources: [AppMixerSource] = [],
         outputChannels: StereoOutputChannels? = nil, capturedRender: CapturedRender? = nil,
         render: @escaping StereoRender) throws {
        do {
            try prepare(output: output, verification: verification, appSources: appSources,
                        outputChannels: outputChannels, capturedRender: capturedRender, render: render)
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
                         outputChannels: StereoOutputChannels?, capturedRender: CapturedRender?,
                         render: @escaping StereoRender) throws {
        let transport = try HAL.read(kAudioDevicePropertyTransportType, of: output.id, as: UInt32.self)
        guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else {
            throw SystemAudioRouteError.unsupportedOutput("\(output.name) uses a virtual or aggregate audio route.")
        }
        let destination = try DeviceDestination(output, pair: outputChannels,
                                                preserveCapture: capturedRender != nil || outputChannels != nil)
        let sources = verification ? [] : appSources
        let host = verification ? nil : try HAL.processID()
        self.hostProcess = host
        self.appSources = sources
        let excluded = try host.map { try Self.excludedProcesses(host: $0, sources: sources) } ?? []
        let remainder = CATapDescription(excludingProcesses: excluded, deviceUID: output.uid, stream: destination.capture.stream)
        var formats = [try createTap(remainder, name: "Airwave", gain: nil,
                                     output: output, source: destination.capture, verification: verification)]
        for source in sources {
            let description = CATapDescription(processes: source.processIDs, deviceUID: output.uid, stream: destination.capture.stream)
            formats.append(try createTap(description, name: "Airwave: \(source.id)", gain: source.gain,
                                         output: output, source: destination.capture, verification: verification))
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
        var wideInputs: [MultichannelTapInput] = []
        let inputLayout = destination.capture.layout
        for format in formats {
            guard let first = BufferChannel.at(tapStart, widths: aggregateInputs), first.offset == 0,
                  let last = BufferChannel.at(tapStart + format.channels - 1, widths: aggregateInputs),
                  last.offset == last.stride - 1 else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio did not expose the system audio tap channels.")
            }
            let localChannels = destination.capture.sourceIndices ?? [0, format.channels - 1]
            let channels = localChannels.compactMap { BufferChannel.at(tapStart + $0, widths: aggregateInputs) }
            guard channels.count == localChannels.count else {
                throw SystemAudioRouteError.unsupportedOutput("Core Audio did not expose the selected source channels.")
            }
            if channels.count == 2 {
                tapInputs.append(StereoTapInput(left: channels[0], right: channels[1], gain: format.gain))
            } else {
                wideInputs.append(MultichannelTapInput(channels: channels, gain: format.gain))
            }
            tapStart += format.channels
        }
        let bridge = StereoIOBridge(
            tapInputs: tapInputs, sampleRate: output.sampleRate,
            outputLeft: destination.left, outputRight: destination.right,
            verification: verification, wideInputs: wideInputs, inputLayout: inputLayout,
            clearsUnusedOutputs: outputChannels != nil, capturedRender: capturedRender, render: render
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
                           output: OutputDevice, source: CaptureSource, verification: Bool) throws -> TapFormat {
        description.name = name
        description.isPrivate = true
        description.isMixdown = source.streamChannels > 2 && source.sourceIndices == nil
        description.isMono = false
        description.muteBehavior = verification ? .unmuted : .mutedWhenTapped
        var id = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateProcessTap(description, &id), "Create system audio tap")
        taps.append(ProcessTap(id: id, description: description))
        let uid = try HAL.string(kAudioTapPropertyUID, of: id)
        let format = try HAL.read(kAudioTapPropertyFormat, of: id, as: AudioStreamBasicDescription.self)
        let channels = Int(format.mChannelsPerFrame)
        let expectedWidth = source.sourceIndices != nil ? channels == source.streamChannels : (1...2).contains(channels)
        guard expectedWidth, HAL.isFloatPCM(format, at: output.sampleRate) else {
            throw SystemAudioRouteError.unsupportedOutput("Core Audio did not provide the expected tap format at the output sample rate.")
        }
        return TapFormat(uid: uid, channels: channels, gain: gain)
    }
}

private struct CaptureSource {
    let stream: UInt
    let streamChannels: Int
    let sourceIndices: [Int]?
    let layout: InputLayout?
}

private struct DeviceDestination {
    let capture: CaptureSource
    let bufferWidths: [Int]
    let left: BufferChannel
    let right: BufferChannel

    init(_ output: OutputDevice, pair: StereoOutputChannels?, preserveCapture: Bool) throws {
        let scope = kAudioObjectPropertyScopeOutput
        let widths = try HAL.channelWidths(of: output.id, scope: scope)
        let channelCount = widths.reduce(0, +)
        if let pair, !(2...16).contains(channelCount) || !pair.isInRange(channelCount: channelCount) {
            throw SystemAudioRouteError.unsupportedOutput("Choose two distinct output channels available on this device.")
        }
        let preferred = HAL.preferredStereoChannels(of: output.id, channelCount: channelCount)
        let destination = pair.map { ($0.left - 1, $0.right - 1) } ?? preferred
        let streams = try HAL.streams(of: output.id, scope: scope)
        let validRanges = try streams.compactMap { stream -> Range<Int>? in
            let first = try HAL.read(kAudioStreamPropertyStartingChannel, of: stream, as: UInt32.self)
            let format = try HAL.read(kAudioStreamPropertyVirtualFormat, of: stream, as: AudioStreamBasicDescription.self)
            guard first > 0, format.mChannelsPerFrame > 0, HAL.isFloatPCM(format, at: output.sampleRate) else { return nil }
            let start = Int(first) - 1
            return start..<(start + Int(format.mChannelsPerFrame))
        }
        guard let left = BufferChannel.at(destination.0, widths: widths),
              let right = BufferChannel.at(destination.1, widths: widths),
              validRanges.contains(where: { $0.contains(destination.0) }),
              validRanges.contains(where: { $0.contains(destination.1) }) else {
            throw SystemAudioRouteError.unsupportedOutput("The saved output channels are unavailable on \(output.name). Configure the device to choose another pair.")
        }
        self.left = left
        self.right = right
        self.bufferWidths = widths

        if preserveCapture, let descriptor = output.routing {
            switch OutputRoutingResolver.resolve(output: descriptor, channels: pair) {
            case .resolved(let route):
                guard streams.indices.contains(route.tapStreamIndex),
                      let oldSource = route.device.outputStreams.first(where: { $0.streamIndex == route.tapStreamIndex })
                else { throw SystemAudioRouteError.unsupportedOutput("Core Audio changed the source stream during setup.") }
                let sourceStream = streams[route.tapStreamIndex]
                let first = try HAL.read(kAudioStreamPropertyStartingChannel, of: sourceStream, as: UInt32.self)
                let format = try HAL.read(kAudioStreamPropertyVirtualFormat, of: sourceStream, as: AudioStreamBasicDescription.self)
                guard Int(first) == oldSource.startingChannel,
                      Int(format.mChannelsPerFrame) == route.nativeWidth, HAL.isFloatPCM(format, at: output.sampleRate) else {
                    throw SystemAudioRouteError.unsupportedOutput("Core Audio changed the source stream during setup.")
                }
                capture = CaptureSource(stream: UInt(route.tapStreamIndex), streamChannels: route.nativeWidth,
                                        sourceIndices: route.sourceChannelIndices, layout: route.inputLayout)
                return
            case .unsupported(let reason):
                if pair != nil { throw SystemAudioRouteError.unsupportedOutput(reason) }
            }
        }

        for (index, stream) in streams.enumerated() {
            let first = try HAL.read(kAudioStreamPropertyStartingChannel, of: stream, as: UInt32.self)
            let format = try HAL.read(kAudioStreamPropertyVirtualFormat, of: stream, as: AudioStreamBasicDescription.self)
            let count = Int(format.mChannelsPerFrame)
            let start = max(0, Int(first) - 1)
            let range = start..<(start + count)
            if range.contains(preferred.0), range.contains(preferred.1), HAL.isFloatPCM(format, at: output.sampleRate) {
                capture = CaptureSource(stream: UInt(index), streamChannels: count, sourceIndices: nil, layout: nil)
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

final class MultichannelTapInput {
    private let channels: [BufferChannel]
    private let gain: AppMixerGain?
    private var currentGain: Float

    init(channels: [BufferChannel], gain: AppMixerGain?) {
        self.channels = channels
        self.gain = gain
        currentGain = gain?.value ?? 1
    }

    func mix(from buffers: UnsafeMutableAudioBufferListPointer, into output: UnsafeMutablePointer<Float>,
             channelStride: Int, frames: Int, gainStep: Float) -> Bool {
        let target = gain?.value ?? 1
        var count = frames
        var hasSamples = false
        for channel in channels {
            guard let samples = channel.samples(in: buffers) else { return false }
            if samples.data != nil {
                count = min(count, samples.frames)
                hasSamples = true
            }
        }
        guard hasSamples, count > 0 else {
            currentGain = target
            return true
        }

        let start = currentGain
        var end = start
        for (index, channel) in channels.enumerated() {
            guard let samples = channel.samples(in: buffers), let source = samples.data else { continue }
            let destination = output.advanced(by: index * channelStride)
            var level = start
            var frame = 0
            while frame < count, level != target {
                let distance = target - level
                level = abs(distance) <= gainStep ? target : level + (distance > 0 ? gainStep : -gainStep)
                destination[frame] += source[frame * channel.stride] * level
                frame += 1
            }
            end = level
            if frame < count, level != 0 {
                let source = source.advanced(by: frame * channel.stride)
                let destination = destination.advanced(by: frame)
                if level == 1 {
                    vDSP_vadd(source, channel.stride, destination, 1, destination, 1, vDSP_Length(count - frame))
                } else {
                    vDSP_vsma(source, channel.stride, &level, destination, 1, destination, 1, vDSP_Length(count - frame))
                }
            }
        }
        currentGain = end
        return true
    }
}

final class StereoIOBridge: @unchecked Sendable {
    let enabled = Atomic(false)
    let failed = Atomic(false)
    let rendered = Atomic(false)

    private let tapInputs: [StereoTapInput]
    private let wideInputs: [MultichannelTapInput]
    private let inputSpeakers: [VirtualSpeaker]
    private let capturePlanes: [UnsafePointer<Float>?]
    private let captureStorage: UnsafeMutablePointer<Float>?
    private let clearsUnusedOutputs: Bool
    private let capturedRender: CapturedRender?
    private let gainStep: Float
    private let outputLeft: BufferChannel
    private let outputRight: BufferChannel
    private let verification: Bool
    private let render: StereoRender
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4 * Int(SystemAudioRoute.maximumFrames))
    private var invalidCycles = 0

    convenience init(tapInputs: [StereoTapInput], sampleRate: Double, outputLeft: BufferChannel, outputRight: BufferChannel,
                     verification: Bool, render: @escaping StereoRender) {
        self.init(tapInputs: tapInputs, sampleRate: sampleRate, outputLeft: outputLeft, outputRight: outputRight,
                  verification: verification, wideInputs: [], inputLayout: nil,
                  clearsUnusedOutputs: false, capturedRender: nil, render: render)
    }

    init(tapInputs: [StereoTapInput], sampleRate: Double, outputLeft: BufferChannel, outputRight: BufferChannel,
                     verification: Bool, wideInputs: [MultichannelTapInput], inputLayout: InputLayout?,
                     clearsUnusedOutputs: Bool, capturedRender: CapturedRender?,
                     render: @escaping StereoRender) {
        self.tapInputs = tapInputs
        self.wideInputs = wideInputs
        inputSpeakers = inputLayout?.channels ?? []
        self.clearsUnusedOutputs = clearsUnusedOutputs
        self.capturedRender = capturedRender
        if !wideInputs.isEmpty, let inputLayout {
            let stride = Int(SystemAudioRoute.maximumFrames)
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: stride * inputLayout.channels.count)
            captureStorage = storage
            capturePlanes = inputLayout.channels.indices.map { UnsafePointer(storage.advanced(by: $0 * stride)) }
        } else {
            captureStorage = nil
            capturePlanes = []
        }
        gainStep = 1 / Float(sampleRate * 0.01)
        self.outputLeft = outputLeft
        self.outputRight = outputRight
        self.verification = verification
        self.render = render
    }

    deinit {
        storage.deallocate()
        captureStorage?.deallocate()
    }

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
        if let captureStorage {
            for channel in capturePlanes.indices {
                memset(captureStorage.advanced(by: channel * capacity), 0, bytes)
            }
            for tap in wideInputs {
                guard tap.mix(from: inputs, into: captureStorage, channelStride: capacity, frames: frames, gainStep: gainStep) else {
                    recordInvalidCycle()
                    return
                }
            }
            capturePlanes.withUnsafeBufferPointer { planes in
                guard let base = planes.baseAddress else { return }
                StereoDownmixGains.downmix(inputChannels: base, inputChannelCount: planes.count, inputOffset: 0,
                                          inputSpeakers: inputSpeakers, outputLeft: left, outputRight: right,
                                          frameCount: frames)
            }
        } else {
            memset(left, 0, bytes)
            memset(right, 0, bytes)
            for tap in tapInputs {
                guard tap.mix(from: inputs, into: left, right, frames: frames, gainStep: gainStep) else {
                    recordInvalidCycle()
                    return
                }
            }
        }
        invalidCycles = 0
        if !verification, clearsUnusedOutputs {
            for index in outputs.indices {
                let buffer = outputs[index]
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        if !verification, outputLeft.stride == 1, outputRight.stride == 1, outputLeft != outputRight {
            processCapture(timestamp, left, right, leftData, rightData, UInt32(frames))
            rendered.store(true, ordering: .relaxed)
            return
        }
        let processedLeft = storage.advanced(by: 2 * capacity)
        let processedRight = storage.advanced(by: 3 * capacity)
        processCapture(timestamp, left, right, processedLeft, processedRight, UInt32(frames))
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

    private func processCapture(
        _ time: UnsafePointer<AudioTimeStamp>, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
        _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, _ frames: UInt32
    ) {
        if let capturedRender, !capturePlanes.isEmpty {
            capturePlanes.withUnsafeBufferPointer { planes in
                capturedRender(time, planes, left, right, outputLeft, outputRight, frames)
            }
        } else {
            render(time, left, right, outputLeft, outputRight, frames)
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

    static func channelLabels(of id: AudioDeviceID, channelCount: Int) -> [UInt32]? {
        let scope = kAudioObjectPropertyScopeOutput
        guard (2...16).contains(channelCount) else { return nil }
        return try? readBuffer(kAudioDevicePropertyPreferredChannelLayout, of: id, scope: scope) { raw, size in
            let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            guard size >= header else { return nil }
            let native = raw.assumingMemoryBound(to: AudioChannelLayout.self)
            let tag = native.pointee.mChannelLayoutTag
            if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
                return labels(from: native, byteCount: size, channelCount: channelCount)
            }
            var value = tag == kAudioChannelLayoutTag_UseChannelBitmap ? native.pointee.mChannelBitmap.rawValue : tag
            let property = tag == kAudioChannelLayoutTag_UseChannelBitmap
                ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            let argumentSize = UInt32(MemoryLayout<UInt32>.size)
            var resultSize: UInt32 = 0
            let expected = header + channelCount * MemoryLayout<AudioChannelDescription>.stride
            guard AudioFormatGetPropertyInfo(property, argumentSize, &value, &resultSize) == noErr,
                  resultSize == expected else { return nil }
            return withUnsafeTemporaryAllocation(byteCount: expected, alignment: MemoryLayout<AudioChannelLayout>.alignment) { result in
                guard let base = result.baseAddress,
                      AudioFormatGetProperty(property, argumentSize, &value, &resultSize, base) == noErr,
                      resultSize == expected else { return nil }
                return labels(from: base.assumingMemoryBound(to: AudioChannelLayout.self),
                              byteCount: expected, channelCount: channelCount)
            }
        }
    }

    private static func labels(from layout: UnsafePointer<AudioChannelLayout>, byteCount: Int, channelCount: Int) -> [UInt32]? {
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions,
              Int(layout.pointee.mNumberChannelDescriptions) == channelCount,
              byteCount >= header + channelCount * MemoryLayout<AudioChannelDescription>.stride else { return nil }
        let descriptions = UnsafeRawPointer(layout).advanced(by: header).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<channelCount).map { descriptions[$0].mChannelLabel }
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
