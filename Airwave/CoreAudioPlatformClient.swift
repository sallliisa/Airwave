import AppKit
import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum CoreAudioStatus {
    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioRuntimeError.cleanupFailed("\(operation) failed (OSStatus \(status))")
        }
    }

    static func creationError(_ status: OSStatus, operation: String) -> String {
        "\(operation) failed (OSStatus \(status))"
    }

    static func isAlreadyGone(_ status: OSStatus) -> Bool {
        status == kAudioHardwareBadObjectError
    }
}

nonisolated struct CoreAudioIOCleanupDisposition: Equatable {
    let shouldRemoveContext: Bool
    let error: AudioRuntimeError?
}

nonisolated enum CoreAudioIOCleanup {
    static func disposition(uninitializeStatus: OSStatus, disposeStatus: OSStatus) -> CoreAudioIOCleanupDisposition {
        let disposeCompleted = disposeStatus == noErr || CoreAudioStatus.isAlreadyGone(disposeStatus)
        guard disposeCompleted else {
            return CoreAudioIOCleanupDisposition(
                shouldRemoveContext: false,
                error: .cleanupFailed(CoreAudioStatus.creationError(disposeStatus, operation: "Dispose HAL unit"))
            )
        }
        let uninitializeCompleted = uninitializeStatus == noErr
            || uninitializeStatus == kAudioUnitErr_Uninitialized
            || CoreAudioStatus.isAlreadyGone(uninitializeStatus)
        return CoreAudioIOCleanupDisposition(
            shouldRemoveContext: true,
            error: uninitializeCompleted ? nil : .cleanupFailed(
                CoreAudioStatus.creationError(uninitializeStatus, operation: "Uninitialize HAL unit")
            )
        )
    }
}

nonisolated struct StereoCallbackOutput {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let frameCount: Int
}

nonisolated struct StereoCallbackPreparation {
    let output: StereoCallbackOutput?
    let status: OSStatus
}

nonisolated struct StereoCallbackInput {
    let left: UnsafePointer<Float>
    let right: UnsafePointer<Float>
    let frameCount: Int
}

nonisolated struct StereoCallbackInputPreparation {
    let input: StereoCallbackInput?
    let status: OSStatus
}

nonisolated enum StereoCallbackBridge {
    static let maximumFrames = 4_096

    static func validate(_ format: AudioStreamFormat) -> Bool {
        format.channelCount == 2
            && format.sampleType == .float32
            && format.sampleRate > 0
            && !format.isInterleaved
    }

    static func zero(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        memset(left, 0, frameCount * MemoryLayout<Float>.size)
        memset(right, 0, frameCount * MemoryLayout<Float>.size)
    }

    static func prepare(
        ioData: UnsafeMutablePointer<AudioBufferList>?,
        requestedFrames: UInt32
    ) -> StereoCallbackPreparation {
        guard let ioData else {
            return StereoCallbackPreparation(output: nil, status: kAudio_ParamError)
        }
        let output = UnsafeMutableAudioBufferListPointer(ioData)
        let buffersToSilence = min(output.count, 2)
        if buffersToSilence > 0 {
            for index in 0..<buffersToSilence {
                guard let data = output[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let available = min(
                    Int(output[index].mDataByteSize) / MemoryLayout<Float>.size,
                    maximumFrames
                )
                if available > 0 {
                    memset(data, 0, available * MemoryLayout<Float>.size)
                }
            }
        }
        guard output.count == 2,
              output[0].mNumberChannels == 1,
              output[1].mNumberChannels == 1,
              let left = output[0].mData?.assumingMemoryBound(to: Float.self),
              let right = output[1].mData?.assumingMemoryBound(to: Float.self) else {
            return StereoCallbackPreparation(output: nil, status: kAudio_ParamError)
        }
        let availableFrames = min(
            Int(output[0].mDataByteSize) / MemoryLayout<Float>.size,
            Int(output[1].mDataByteSize) / MemoryLayout<Float>.size
        )
        let frames = Int(requestedFrames)
        guard frames <= maximumFrames, frames <= availableFrames else {
            return StereoCallbackPreparation(output: nil, status: kAudioUnitErr_TooManyFramesToProcess)
        }
        return StereoCallbackPreparation(
            output: StereoCallbackOutput(left: left, right: right, frameCount: frames),
            status: noErr
        )
    }

    static func prepareInput(
        inputData: UnsafePointer<AudioBufferList>?,
        requestedFrames: UInt32
    ) -> StereoCallbackInputPreparation {
        guard let inputData else {
            return StereoCallbackInputPreparation(input: nil, status: kAudio_ParamError)
        }
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard input.count == 2,
              input[0].mNumberChannels == 1,
              input[1].mNumberChannels == 1,
              let leftData = input[0].mData?.assumingMemoryBound(to: Float.self),
              let rightData = input[1].mData?.assumingMemoryBound(to: Float.self) else {
            return StereoCallbackInputPreparation(input: nil, status: kAudio_ParamError)
        }
        let availableFrames = min(
            Int(input[0].mDataByteSize) / MemoryLayout<Float>.size,
            Int(input[1].mDataByteSize) / MemoryLayout<Float>.size
        )
        let frames = Int(requestedFrames)
        guard frames <= maximumFrames, frames <= availableFrames else {
            return StereoCallbackInputPreparation(input: nil, status: kAudioUnitErr_TooManyFramesToProcess)
        }
        return StereoCallbackInputPreparation(
            input: StereoCallbackInput(
                left: UnsafePointer(leftData),
                right: UnsafePointer(rightData),
                frameCount: frames
            ),
            status: noErr
        )
    }
}

nonisolated final class CoreAudioPlatformClient: AudioPlatformClient {
    fileprivate final class IOContext {
        let aggregateID: AudioObjectID
        let callback: AudioIOCallback
        var ioProcID: AudioDeviceIOProcID?
        var isStarted = false

        init(aggregateID: AudioObjectID, callback: @escaping AudioIOCallback) {
            self.aggregateID = aggregateID
            self.callback = callback
        }
    }

    private let instanceUUID = UUID()
    private var tapUIDs: [AudioObjectID: String] = [:]
    private var aggregateIDs: Set<AudioObjectID> = []
    private var ioContexts: [UInt64: IOContext] = [:]
    private var nextIOHandle: UInt64 = 1
    private var defaultOutputHandler: DefaultOutputChangeHandler?
    private var defaultOutputListenerInstalled = false

    func defaultOutputDevice() throws -> OutputDeviceDescriptor {
        let deviceID: AudioObjectID = try getSystemObjectValue(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { throw AudioRuntimeError.noOutputDevice }
        let uid: String = try getObjectCFString(deviceID, selector: kAudioDevicePropertyDeviceUID)
        let name: String = try getObjectCFString(deviceID, selector: kAudioObjectPropertyName)
        let transport: UInt32 = try getObjectValue(deviceID, selector: kAudioDevicePropertyTransportType)
        let sampleRate: Float64 = try getObjectValue(deviceID, selector: kAudioDevicePropertyNominalSampleRate)
        let channels = try channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate
        let isVirtual = transport == kAudioDeviceTransportTypeVirtual || isAggregate
        return OutputDeviceDescriptor(
            id: .init(UInt64(deviceID)),
            uid: uid,
            name: name,
            transport: fourCC(transport),
            outputChannelCount: channels,
            nominalSampleRate: sampleRate,
            isVirtual: isVirtual,
            isAggregate: isAggregate
        )
    }

    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws {
        stopObservingDefaultOutput()
        defaultOutputHandler = handler
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            defaultOutputListener
        )
        guard status == noErr else {
            defaultOutputHandler = nil
            throw AudioRuntimeError.deviceLost
        }
        defaultOutputListenerInstalled = true
    }

    func stopObservingDefaultOutput() {
        guard defaultOutputListenerInstalled else {
            defaultOutputHandler = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultOutputListener)
        defaultOutputListenerInstalled = false
        defaultOutputHandler = nil
    }

    private lazy var defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        self.defaultOutputHandler?(try? self.defaultOutputDevice())
    }

    func resolveOwnProcess() throws -> AudioProcessHandle {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processID
        )
        guard status == noErr, processID != kAudioObjectUnknown else {
            throw AudioRuntimeError.tapCreationFailed(CoreAudioStatus.creationError(status, operation: "Resolve process"))
        }
        return AudioProcessHandle(value: UInt64(processID))
    }

    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle {
        guard request.isGlobal, request.channelCount == 2, request.isPrivate, request.mutedWhenTapped else {
            throw AudioRuntimeError.tapCreationFailed("Invalid global stereo tap request")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID(request.excludedProcess.value)])
        description.name = "Airwave Process Tap"
        description.uuid = instanceUUID
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            if status == kAudioHardwareIllegalOperationError { throw AudioRuntimeError.permissionDenied }
            throw AudioRuntimeError.tapCreationFailed(CoreAudioStatus.creationError(status, operation: "Create process tap"))
        }
        tapUIDs[tapID] = instanceUUID.uuidString
        return AudioTapHandle(value: UInt64(tapID))
    }

    func destroyTap(_ tap: AudioTapHandle) throws {
        let tapID = AudioObjectID(tap.value)
        let status = AudioHardwareDestroyProcessTap(tapID)
        guard status == noErr || CoreAudioStatus.isAlreadyGone(status) else {
            throw AudioRuntimeError.cleanupFailed(CoreAudioStatus.creationError(status, operation: "Destroy process tap"))
        }
        tapUIDs.removeValue(forKey: tapID)
    }

    func createPrivateAggregate(tap: AudioTapHandle, output: OutputDeviceDescriptor) throws -> PrivateAggregateHandle {
        guard output.outputChannelCount == 2, !output.isVirtual, !output.isAggregate else {
            throw AudioRuntimeError.unsupportedOutput(output.name)
        }
        let tapID = AudioObjectID(tap.value)
        guard let tapUID = tapUIDs[tapID] else {
            throw AudioRuntimeError.aggregateCreationFailed("Unknown process tap")
        }
        let aggregateUID = "com.southneuhof.Airwave.private.\(instanceUUID.uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Airwave Private Pipeline",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw AudioRuntimeError.aggregateCreationFailed(CoreAudioStatus.creationError(status, operation: "Create private aggregate"))
        }
        aggregateIDs.insert(aggregateID)
        return PrivateAggregateHandle(value: UInt64(aggregateID))
    }

    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {
        let aggregateID = AudioObjectID(aggregate.value)
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        guard status == noErr || CoreAudioStatus.isAlreadyGone(status) else {
            throw AudioRuntimeError.cleanupFailed(CoreAudioStatus.creationError(status, operation: "Destroy private aggregate"))
        }
        aggregateIDs.remove(aggregateID)
    }

    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat {
        let asbd: AudioStreamBasicDescription = try getObjectValue(
            AudioObjectID(tap.value),
            selector: kAudioTapPropertyFormat
        )
        return streamFormat(asbd)
    }

    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat {
        let id = AudioObjectID(aggregate.value)
        let sampleRate: Float64 = try getObjectValue(id, selector: kAudioDevicePropertyNominalSampleRate)
        return AudioStreamFormat(
            sampleRate: sampleRate,
            channelCount: try channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            sampleType: .float32,
            isInterleaved: false
        )
    }

    func createIO(aggregate: PrivateAggregateHandle, callback: @escaping AudioIOCallback) throws -> AudioIOHandle {
        let aggregateID = AudioObjectID(aggregate.value)
        guard aggregateIDs.contains(aggregateID) else { throw AudioRuntimeError.ioCreationFailed("Unknown aggregate") }
        // macOS associates the NSAudioCaptureUsageDescription prompt with
        // recording started through the aggregate device API. A HAL output
        // Audio Unit can render audio but does not reliably trigger that TCC
        // request for a process tap.
        let context = IOContext(aggregateID: aggregateID, callback: callback)
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateID,
            nil
        ) { [context] _, inputData, _, outputData, _ in
            let requestedFrames = Self.frameCount(
                inputData: inputData,
                outputData: outputData
            )
            guard requestedFrames > 0 else { return }

            let input = StereoCallbackBridge.prepareInput(
                inputData: inputData,
                requestedFrames: requestedFrames
            )
            let output = StereoCallbackBridge.prepare(
                ioData: outputData,
                requestedFrames: requestedFrames
            )
            guard let input = input.input, let output = output.output else { return }
            context.callback(
                UnsafePointer<Float>(input.left),
                UnsafePointer<Float>(input.right),
                output.left,
                output.right,
                min(input.frameCount, output.frameCount)
            )
        }
        guard status == noErr, let ioProcID else {
            throw AudioRuntimeError.ioCreationFailed(
                CoreAudioStatus.creationError(status, operation: "Create aggregate I/O proc")
            )
        }
        context.ioProcID = ioProcID
        let handle = AudioIOHandle(value: nextIOHandle)
        nextIOHandle += 1
        ioContexts[handle.value] = context
        return handle
    }

    private static func frameCount(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> UInt32 {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard !input.isEmpty, !output.isEmpty else { return 0 }

        var frames = Int.max
        for buffer in input {
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        }
        for buffer in output {
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        }
        return UInt32(min(frames, Int(UInt32.max)))
    }

    func startIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { throw AudioRuntimeError.ioStartFailed("Unknown I/O") }
        let status = AudioDeviceStart(context.aggregateID, context.ioProcID)
        guard status == noErr else {
            throw AudioRuntimeError.ioStartFailed(CoreAudioStatus.creationError(status, operation: "Start aggregate I/O"))
        }
        context.isStarted = true
    }

    func stopIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { return }
        guard context.isStarted else { return }
        let status = AudioDeviceStop(context.aggregateID, context.ioProcID)
        guard status == noErr || status == kAudioHardwareNotRunningError else {
            throw AudioRuntimeError.cleanupFailed(CoreAudioStatus.creationError(status, operation: "Stop aggregate I/O"))
        }
        context.isStarted = false
    }

    func destroyIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { return }
        guard !context.isStarted, let ioProcID = context.ioProcID else { return }
        let status = AudioDeviceDestroyIOProcID(context.aggregateID, ioProcID)
        guard status == noErr || CoreAudioStatus.isAlreadyGone(status) else {
            throw AudioRuntimeError.cleanupFailed(
                CoreAudioStatus.creationError(status, operation: "Destroy aggregate I/O proc")
            )
        }
        ioContexts.removeValue(forKey: io.value)
    }

    func openAudioCapturePermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func getSystemObjectValue<T>(selector: AudioObjectPropertySelector) throws -> T {
        try getObjectValue(AudioObjectID(kAudioObjectSystemObject), selector: selector)
    }

    private func getObjectValue<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage)
        guard status == noErr else { throw AudioRuntimeError.deviceLost }
        return storage.load(as: T.self)
    }

    private func getObjectCFString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw AudioRuntimeError.deviceLost }
        return value.takeUnretainedValue() as String
    }

    private func channelCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            throw AudioRuntimeError.deviceLost
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr else {
            throw AudioRuntimeError.deviceLost
        }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func streamFormat(_ asbd: AudioStreamBasicDescription) -> AudioStreamFormat {
        let isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mBitsPerChannel == 32
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return AudioStreamFormat(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            sampleType: isFloat32 ? .float32 : .unsupported,
            isInterleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
    }

    private func fourCC(_ value: UInt32) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ], encoding: .macOSRoman) ?? String(value)
    }
}
