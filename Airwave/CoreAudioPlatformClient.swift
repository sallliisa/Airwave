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

nonisolated enum CoreAudioErrorMapping {
    static func tapCreation(_ status: OSStatus) -> AudioRuntimeError {
        .tapCreationFailed(CoreAudioStatus.creationError(status, operation: "Create process tap"))
    }

    static func ioStart(_ status: OSStatus) -> AudioRuntimeError {
        if status == kAudioHardwareIllegalOperationError {
            return .permissionDenied
        }
        return .ioStartFailed(CoreAudioStatus.creationError(status, operation: "Start HAL unit"))
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
}

nonisolated final class CoreAudioPlatformClient: AudioPlatformClient, OutputDeviceDiscovering {
    fileprivate final class IOContext {
        let unit: AudioUnit
        let callback: AudioIOCallback
        let inputLeft: UnsafeMutablePointer<Float>
        let inputRight: UnsafeMutablePointer<Float>
        let inputListStorage: UnsafeMutableRawPointer

        init(unit: AudioUnit, callback: @escaping AudioIOCallback) {
            self.unit = unit
            self.callback = callback
            inputLeft = .allocate(capacity: StereoCallbackBridge.maximumFrames)
            inputRight = .allocate(capacity: StereoCallbackBridge.maximumFrames)
            let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
            inputListStorage = .allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
            inputListStorage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            let inputList = inputListStorage.assumingMemoryBound(to: AudioBufferList.self)
            inputList.pointee.mNumberBuffers = 2
            let buffers = UnsafeMutableAudioBufferListPointer(inputList)
            buffers[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(StereoCallbackBridge.maximumFrames * MemoryLayout<Float>.size),
                mData: inputLeft
            )
            buffers[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(StereoCallbackBridge.maximumFrames * MemoryLayout<Float>.size),
                mData: inputRight
            )
        }

        deinit {
            inputLeft.deallocate()
            inputRight.deallocate()
            inputListStorage.deallocate()
        }
    }

    private let instanceUUID = UUID()
    private var tapUIDs: [AudioObjectID: String] = [:]
    private var aggregateIDs: Set<AudioObjectID> = []
    private var ioContexts: [UInt64: IOContext] = [:]
    private var nextIOHandle: UInt64 = 1
    private var defaultOutputHandler: DefaultOutputChangeHandler?
    private var defaultOutputListenerInstalled = false
    private var availableOutputHandler: AvailableOutputChangeHandler?
    private var availableOutputListenerInstalled = false

    func defaultOutputDevice() throws -> OutputDeviceDescriptor {
        let deviceID: AudioObjectID = try getSystemObjectValue(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { throw AudioRuntimeError.noOutputDevice }
        return try descriptor(for: deviceID)
    }

    func availableOutputDevices() throws -> [OutputDeviceDescriptor] {
        let deviceIDs = try availableDeviceIDs()
        var descriptorsByUID: [String: OutputDeviceDescriptor] = [:]
        for deviceID in deviceIDs {
            do {
                let descriptor = try descriptor(for: deviceID)
                guard descriptor.isSupportedProfileOutput else { continue }
                descriptorsByUID[descriptor.uid] = descriptor
            } catch {
                Logger.log("[CoreAudio] Skipping unavailable device \(deviceID): \(error)")
            }
        }
        return descriptorsByUID.values.sorted(by: Self.sortDescriptors)
    }

    func observeAvailableOutputs(_ handler: @escaping AvailableOutputChangeHandler) throws {
        stopObservingAvailableOutputs()
        availableOutputHandler = handler
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            availableOutputListener
        )
        guard status == noErr else {
            availableOutputHandler = nil
            throw AudioRuntimeError.deviceLost
        }
        availableOutputListenerInstalled = true
    }

    func stopObservingAvailableOutputs() {
        guard availableOutputListenerInstalled else {
            availableOutputHandler = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            availableOutputListener
        )
        availableOutputListenerInstalled = false
        availableOutputHandler = nil
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

    private lazy var availableOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        guard let outputs = try? self.availableOutputDevices() else {
            Logger.log("[CoreAudio] Unable to refresh available output devices")
            return
        }
        self.availableOutputHandler?(outputs)
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
        guard request.isGlobal,
              request.channelCount == 2,
              request.isPrivate,
              request.mutedWhenTapped,
              !request.outputDeviceUID.isEmpty,
              request.streamIndex >= 0 else {
            throw AudioRuntimeError.tapCreationFailed("Invalid global stereo tap request")
        }
        let description = CATapDescription(
            excludingProcesses: [AudioObjectID(request.excludedProcess.value)],
            deviceUID: request.outputDeviceUID,
            stream: UInt(request.streamIndex)
        )
        description.name = "Airwave Process Tap"
        description.uuid = instanceUUID
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CoreAudioErrorMapping.tapCreation(status)
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
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRuntimeError.ioCreationFailed("HAL output component unavailable")
        }
        var candidate: AudioUnit?
        var status = AudioComponentInstanceNew(component, &candidate)
        guard status == noErr, let unit = candidate else {
            throw AudioRuntimeError.ioCreationFailed(CoreAudioStatus.creationError(status, operation: "Create HAL unit"))
        }
        do {
            var enabled: UInt32 = 1
            try setUnit(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &enabled)
            try setUnit(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &enabled)
            var currentDevice = aggregateID
            try setUnit(unit, property: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &currentDevice)

            let rate: Float64 = try getObjectValue(aggregateID, selector: kAudioDevicePropertyNominalSampleRate)
            var format = canonicalStereoFormat(sampleRate: rate)
            try setUnit(unit, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, value: &format)
            try setUnit(unit, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: 0, value: &format)
            var maximumFrames = UInt32(StereoCallbackBridge.maximumFrames)
            try setUnit(unit, property: kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, value: &maximumFrames)

            let context = IOContext(unit: unit, callback: callback)
            var render = AURenderCallbackStruct(
                inputProc: coreAudioRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try setUnit(unit, property: kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, element: 0, value: &render)
            status = AudioUnitInitialize(unit)
            guard status == noErr else {
                throw AudioRuntimeError.ioCreationFailed(CoreAudioStatus.creationError(status, operation: "Initialize HAL unit"))
            }
            let handle = AudioIOHandle(value: nextIOHandle)
            nextIOHandle += 1
            ioContexts[handle.value] = context
            return handle
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    func startIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { throw AudioRuntimeError.ioStartFailed("Unknown I/O") }
        let status = AudioOutputUnitStart(context.unit)
        guard status == noErr else {
            throw CoreAudioErrorMapping.ioStart(status)
        }
    }

    func stopIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { return }
        let status = AudioOutputUnitStop(context.unit)
        guard status == noErr || status == kAudioUnitErr_Uninitialized else {
            throw AudioRuntimeError.cleanupFailed(CoreAudioStatus.creationError(status, operation: "Stop HAL unit"))
        }
    }

    func destroyIO(_ io: AudioIOHandle) throws {
        guard let context = ioContexts[io.value] else { return }
        let uninitializeStatus = AudioUnitUninitialize(context.unit)
        let disposeStatus = AudioComponentInstanceDispose(context.unit)
        let disposition = CoreAudioIOCleanup.disposition(
            uninitializeStatus: uninitializeStatus,
            disposeStatus: disposeStatus
        )
        if disposition.shouldRemoveContext {
            ioContexts.removeValue(forKey: io.value)
        }
        if let error = disposition.error { throw error }
    }

    func openAudioCapturePermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func getSystemObjectValue<T>(selector: AudioObjectPropertySelector) throws -> T {
        try getObjectValue(AudioObjectID(kAudioObjectSystemObject), selector: selector)
    }

    private func availableDeviceIDs() throws -> [AudioObjectID] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw AudioRuntimeError.deviceLost }
        guard size > 0 else { return [] }
        let byteCount = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioObjectID>.alignment
        )
        defer { storage.deallocate() }
        let dataStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, storage)
        guard dataStatus == noErr else { throw AudioRuntimeError.deviceLost }
        let count = byteCount / MemoryLayout<AudioObjectID>.stride
        let pointer = storage.assumingMemoryBound(to: AudioObjectID.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func descriptor(for deviceID: AudioObjectID) throws -> OutputDeviceDescriptor {
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

    private static func sortDescriptors(_ lhs: OutputDeviceDescriptor, _ rhs: OutputDeviceDescriptor) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame ? lhs.uid < rhs.uid : comparison == .orderedAscending
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

    private func canonicalStereoFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func setUnit<T>(
        _ unit: AudioUnit,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: inout T
    ) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioUnitSetProperty(
                unit,
                property,
                scope,
                element,
                UnsafeRawPointer(pointer),
                UInt32(MemoryLayout<T>.size)
            )
        }
        guard status == noErr else {
            throw AudioRuntimeError.ioCreationFailed(CoreAudioStatus.creationError(status, operation: "Configure HAL unit"))
        }
    }

    private func fourCC(_ value: UInt32) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ], encoding: .macOSRoman) ?? String(value)
    }
}

nonisolated private func coreAudioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<CoreAudioPlatformClient.IOContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let preparation = StereoCallbackBridge.prepare(ioData: ioData, requestedFrames: inNumberFrames)
    guard let output = preparation.output else { return preparation.status }

    let inputList = context.inputListStorage.assumingMemoryBound(to: AudioBufferList.self)
    var flags: AudioUnitRenderActionFlags = []
    let status = AudioUnitRender(context.unit, &flags, inTimeStamp, 1, inNumberFrames, inputList)
    guard status == noErr else { return status }
    context.callback(
        UnsafePointer<Float>(context.inputLeft),
        UnsafePointer<Float>(context.inputRight),
        output.left,
        output.right,
        output.frameCount
    )
    return noErr
}
