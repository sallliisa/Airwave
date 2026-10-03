import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

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
        if isPermissionDenied(status) { return .permissionDenied }
        return .tapCreationFailed(CoreAudioStatus.creationError(status, operation: "Create process tap"))
    }

    static func aggregateCreation(_ status: OSStatus) -> AudioRuntimeError {
        if isPermissionDenied(status) { return .permissionDenied }
        return .aggregateCreationFailed(CoreAudioStatus.creationError(status, operation: "Create private aggregate"))
    }

    static func ioCreation(_ status: OSStatus, operation: String) -> AudioRuntimeError {
        if isPermissionDenied(status) { return .permissionDenied }
        return .ioCreationFailed(CoreAudioStatus.creationError(status, operation: operation))
    }

    static func ioStart(_ status: OSStatus) -> AudioRuntimeError {
        if isPermissionDenied(status) {
            return .permissionDenied
        }
        return .ioStartFailed(CoreAudioStatus.creationError(status, operation: "Start HAL unit"))
    }

    static func isPermissionDenied(_ status: OSStatus) -> Bool {
        status == kAudioHardwareIllegalOperationError || status == kAudioDevicePermissionsError
    }
}

nonisolated enum AudioCaptureVerificationPolicy {
    static func event(forRenderStatus status: OSStatus) -> AudioCaptureVerificationEvent {
        if CoreAudioErrorMapping.isPermissionDenied(status) { return .permissionDenied }
        return .renderFailed(status)
    }
}

/// One-shot callback state. Core Audio invokes this state only from its render
/// callback; it performs no allocation or controller work on that realtime path.
nonisolated struct CoreAudioIOVerificationState: Equatable, Sendable {
    private(set) var signalReported = false
    private(set) var renderFailureReported = false
    private var channelPolicies: [CaptureSignalPolicy]

    init(inputChannelCount: Int) {
        signalReported = false
        renderFailureReported = false
        channelPolicies = Array(repeating: CaptureSignalPolicy(), count: max(inputChannelCount, 1))
    }

    mutating func observeSignal(
        inputChannels: UnsafePointer<UnsafePointer<Float>?>,
        inputChannelCount: Int,
        frameCount: Int
    ) -> AudioCaptureVerificationEvent? {
        guard !signalReported else { return nil }
        var detected = false
        for index in 0..<min(inputChannelCount, channelPolicies.count) {
            if let channel = inputChannels[index] {
                let _ = channelPolicies[index].observe(channel: channel, frameCount: frameCount)
                if channelPolicies[index].hasDetectedSignal {
                    detected = true
                }
            } else {
                // A missing channel must not carry partial activity across
                // an unobserved gap as if it were continuous. Advance its
                // window with inactive frames for the skipped frames.
                let _ = channelPolicies[index].observeMissing(frameCount: frameCount)
                if channelPolicies[index].hasDetectedSignal {
                    detected = true
                }
            }
        }
        guard detected else { return nil }
        signalReported = true
        return .signalDetected
    }

    mutating func observeRenderFailure(status: OSStatus) -> AudioCaptureVerificationEvent? {
        guard !renderFailureReported else { return nil }
        renderFailureReported = true
        return AudioCaptureVerificationPolicy.event(forRenderStatus: status)
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

nonisolated enum AUHALChannelMapInstallationError: Error, Equatable {
    case input(OSStatus)
    case output(OSStatus)
}

/// Installs the maps on the private AUHAL instance. The setter seam keeps
/// ordering and failure behavior unit-testable; production passes a closure
/// that synchronously calls AudioUnitSetProperty with each map's storage.
nonisolated enum AUHALChannelMapInstaller {
    typealias Setter = (AudioUnitScope, AudioUnitElement, [Int32]) -> OSStatus

    static func install(_ maps: AUHALChannelMaps, setProperty: Setter) throws {
        let inputStatus = setProperty(kAudioUnitScope_Output, 1, maps.input)
        guard inputStatus == noErr else { throw AUHALChannelMapInstallationError.input(inputStatus) }
        let outputStatus = setProperty(kAudioUnitScope_Input, 0, maps.output)
        guard outputStatus == noErr else { throw AUHALChannelMapInstallationError.output(outputStatus) }
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
        // Pre-silence EVERY buffer the device hands us: with a multichannel
        // aggregate, stale memory beyond channels 1-2 would play on surround
        // outputs. The DSP writes only the stereo pair. Silencing stays inside
        // the requested window — the HAL consumes exactly requestedFrames.
        for index in 0..<output.count {
            guard let data = output[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = min(
                Int(output[index].mDataByteSize) / MemoryLayout<Float>.size,
                Int(requestedFrames),
                maximumFrames
            )
            if available > 0 {
                memset(data, 0, available * MemoryLayout<Float>.size)
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

nonisolated enum DefaultOutputObservationDecision: Equatable {
    case output(OutputDeviceDescriptor)
    case missing
    case retainLastValid

    static func make(from result: Result<OutputDeviceDescriptor, Error>) -> Self {
        switch result {
        case .success(let output): .output(output)
        case .failure(AudioRuntimeError.noOutputDevice): .missing
        case .failure: .retainLastValid
        }
    }
}

/// Plan 039 Step 1 record for one installed current-device property
/// listener. The device ID plus the exact address identifies the
/// registration. Delivery uses the same serial control queue as
/// default-output observation (main).
nonisolated struct CurrentDeviceListenerRecord: Equatable, Sendable {
    let deviceID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
    /// False for the optional preferred-layout property. Its absence uses
    /// plan 038 fallback policy instead of failing observation.
    let isRequired: Bool
}

/// Watched properties that can change the output descriptor or route. Stream
/// inventory and preferred stereo are optional metadata, so a temporarily
/// unavailable selector does not invalidate the last readable device shape.
nonisolated enum CurrentDeviceFormatObservation {
    static func records(for deviceID: AudioObjectID) -> [CurrentDeviceListenerRecord] {
        [
            CurrentDeviceListenerRecord(
                deviceID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain,
                isRequired: true
            ),
            CurrentDeviceListenerRecord(
                deviceID: deviceID,
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeOutput,
                element: kAudioObjectPropertyElementMain,
                isRequired: true
            ),
            CurrentDeviceListenerRecord(
                deviceID: deviceID,
                selector: kAudioDevicePropertyPreferredChannelLayout,
                scope: kAudioObjectPropertyScopeOutput,
                element: kAudioObjectPropertyElementMain,
                isRequired: false
            ),
            CurrentDeviceListenerRecord(
                deviceID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput,
                element: kAudioObjectPropertyElementMain,
                isRequired: false
            ),
            CurrentDeviceListenerRecord(
                deviceID: deviceID,
                selector: kAudioDevicePropertyPreferredChannelsForStereo,
                scope: kAudioObjectPropertyScopeOutput,
                element: kAudioObjectPropertyElementMain,
                isRequired: false
            ),
        ]
    }

    static func address(for record: CurrentDeviceListenerRecord) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: record.selector,
            mScope: record.scope,
            mElement: record.element
        )
    }
}

/// Plan 039 Step 2 retry boundary. One pending descriptor retry at most,
/// three attempts after the initial failure. Delays are measured from the
/// preceding failed attempt. Distinct from the controller pipeline recovery
/// schedule. Tests advance a fake scheduler; production posts on main.
nonisolated protocol CurrentDeviceRetryScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AudioRuntimeCancellation
}

nonisolated final class DispatchCurrentDeviceRetryScheduler: CurrentDeviceRetryScheduling {
    private final class Token: AudioRuntimeCancellation {
        var item: DispatchWorkItem?
        func cancel() { item?.cancel(); item = nil }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AudioRuntimeCancellation {
        let token = Token()
        let item = DispatchWorkItem { [weak token] in
            guard token?.item != nil else { return }
            token?.item = nil
            action()
        }
        token.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }
}

nonisolated enum CurrentDeviceDescriptorRetry {
    static let delays: [TimeInterval] = [0.1, 0.25, 1.0]
}

/// Plan 039 Step 1 ownership of current-device listeners. Production passes
/// Core Audio closures; tests pass fakes. Install/remove balance,
/// partial-failure rollback, generation guard, and unchanged suppression
/// live here so tests exercise the same path as production.
/// Step 2 adds bounded descriptor retries on the same seam: one pending
/// token, generation-guarded attempts, newer-identity/stop cancellation.
nonisolated final class CurrentDeviceListenerSet {
    typealias AddListener = (AudioObjectID, AudioObjectPropertyAddress) -> OSStatus
    typealias RemoveListener = (AudioObjectID, AudioObjectPropertyAddress) -> OSStatus
    typealias ReadDescriptor = (AudioObjectID) -> Result<OutputDeviceDescriptor, Error>

    private let add: AddListener
    private let remove: RemoveListener
    private let read: ReadDescriptor?
    private let retryScheduler: CurrentDeviceRetryScheduling?
    private(set) var installed: [CurrentDeviceListenerRecord] = []
    private(set) var deviceID: AudioObjectID?
    private(set) var generation: UInt64 = 0
    private(set) var lastDelivered: OutputDeviceDescriptor?
    private var pendingRetryToken: AudioRuntimeCancellation?
    private(set) var pendingRetryAttempt = 0
    private var pendingRetryDevice: AudioObjectID?
    private var pendingRetryGeneration: UInt64?
    private var pendingOnOutput: ((OutputDeviceDescriptor) -> Void)?
    private var pendingOnMissing: (() -> Void)?

    init(
        add: @escaping AddListener,
        remove: @escaping RemoveListener,
        read: ReadDescriptor? = nil,
        scheduler: CurrentDeviceRetryScheduling? = nil
    ) {
        self.add = add
        self.remove = remove
        self.read = read
        self.retryScheduler = scheduler
    }

    var installedCount: Int { installed.count }

    var hasPendingRetry: Bool { pendingRetryToken != nil }

    /// Bind a new device: remove old registrations, then install the watched
    /// properties. A required failure removes this attempt's successes and
    /// throws. An optional layout failure keeps the required listeners.
    func bind(deviceID: AudioObjectID, seed: OutputDeviceDescriptor? = nil) throws {
        unbind()
        var added: [CurrentDeviceListenerRecord] = []
        for record in CurrentDeviceFormatObservation.records(for: deviceID) {
            let address = CurrentDeviceFormatObservation.address(for: record)
            guard add(deviceID, address) == noErr else {
                if record.isRequired {
                    for done in added {
                        remove(done.deviceID, CurrentDeviceFormatObservation.address(for: done))
                    }
                    installed = []
                    self.deviceID = nil
                    throw AudioRuntimeError.deviceLost
                }
                continue
            }
            added.append(record)
        }
        installed = added
        self.deviceID = deviceID
        generation &+= 1
        lastDelivered = seed
    }

    /// Best-effort rebind after a default-device event. False means the set
    /// was unwound; the caller logs and still delivers the descriptor.
    /// Step 2: a newer identity also cancels any pending retry (via bind).
    @discardableResult
    func rebindIfNeeded(deviceID: AudioObjectID, seed: OutputDeviceDescriptor) -> Bool {
        guard deviceID != self.deviceID else {
            // Same device: keep one pending chain; a fresh readable event
            // routes through `shouldDeliver` and clears it on delivery.
            coalescePendingRetry(for: deviceID, eventGeneration: generation)
            return true
        }
        do {
            try bind(deviceID: deviceID, seed: seed)
            return true
        } catch {
            return false
        }
    }

    /// Remove all current-device registrations. Safe to repeat. Bumps the
    /// generation so in-flight events from removed listeners are ignored.
    /// Step 2: also cancels any pending descriptor retry.
    func unbind() {
        cancelPendingRetry()
        for record in installed {
            remove(record.deviceID, CurrentDeviceFormatObservation.address(for: record))
        }
        installed = []
        deviceID = nil
        generation &+= 1
        lastDelivered = nil
    }

    /// Decide whether a current-device event reaches the descriptor handler.
    /// Stale generations, empty sets, and unchanged values are ignored. A
    /// first read after bind (no seed) is delivered.
    func shouldDeliver(_ fresh: OutputDeviceDescriptor, eventGeneration: UInt64) -> Bool {
        guard eventGeneration == generation, !installed.isEmpty else { return false }
        guard let last = lastDelivered else {
            lastDelivered = fresh
            return true
        }
        let retained = fresh.retainingMissingRoutingMetadata(from: last)
        guard retained.hasProcessingFormatChange(from: last) else { return false }
        lastDelivered = retained
        return true
    }

    // MARK: - Plan 039 Step 2: bounded descriptor retries

    /// Entry for a current-device event whose descriptor read failed with a
    /// transient error. A `.noOutputDevice` failure publishes missing at
    /// once (no retry). Any other failure arms at most one retry token:
    /// first attempt after 0.1s, then 0.25s, then 1.0s. Returns true when
    /// missing was published or a retry was armed.
    @discardableResult
    func noteTransientReadFailure(
        for device: AudioObjectID,
        eventGeneration: UInt64,
        onOutput: @escaping (OutputDeviceDescriptor) -> Void,
        onMissing: @escaping () -> Void
    ) -> Bool {
        guard eventGeneration == generation, device == deviceID, !installed.isEmpty else { return false }
        guard pendingRetryToken == nil else { return true }
        guard retryScheduler != nil, read != nil, !CurrentDeviceDescriptorRetry.delays.isEmpty else {
            pendingOnMissing = nil
            pendingOnOutput = nil
            onMissing()
            return true
        }
        pendingOnOutput = onOutput
        pendingOnMissing = onMissing
        pendingRetryDevice = device
        pendingRetryGeneration = eventGeneration
        pendingRetryAttempt = 0
        armRetryLocked(delay: CurrentDeviceDescriptorRetry.delays[0])
        return true
    }

    private func armRetryLocked(delay: TimeInterval) {
        guard let scheduler = retryScheduler,
              let tokenGeneration = pendingRetryGeneration,
              let tokenDevice = pendingRetryDevice,
              tokenGeneration == generation,
              tokenDevice == deviceID else {
            cancelPendingRetry()
            return
        }
        pendingRetryToken?.cancel()
        pendingRetryToken = scheduler.schedule(after: delay) { [weak self] in
            self?.firePendingRetry()
        }
    }

    private func firePendingRetry() {
        guard let runningToken = pendingRetryToken,
              let tokenDevice = pendingRetryDevice,
              let tokenGeneration = pendingRetryGeneration,
              tokenGeneration == generation,
              tokenDevice == deviceID,
              let read,
              let onOutput = pendingOnOutput,
              let onMissing = pendingOnMissing else {
            cancelPendingRetry()
            return
        }
        pendingRetryToken = nil
        runningToken.cancel()
        switch read(tokenDevice) {
        case .success(let output):
            let delivered = shouldDeliver(output, eventGeneration: tokenGeneration)
            cancelPendingRetry()
            if delivered { onOutput(output) }
        case .failure(AudioRuntimeError.noOutputDevice):
            cancelPendingRetry()
            onMissing()
        case .failure:
            pendingRetryAttempt += 1
            if pendingRetryAttempt >= CurrentDeviceDescriptorRetry.delays.count {
                cancelPendingRetry()
                onMissing()
                return
            }
            armRetryLocked(delay: CurrentDeviceDescriptorRetry.delays[pendingRetryAttempt])
        }
    }

    /// A new event for the same pending read must not create a second chain.
    /// Callers route the fresh readable path first; this keeps the single
    /// pending token while its device and generation are still current,
    /// otherwise it cancels the stale chain.
    func coalescePendingRetry(for device: AudioObjectID, eventGeneration: UInt64) {
        guard pendingRetryToken != nil else { return }
        guard eventGeneration == generation, device == deviceID,
              eventGeneration == pendingRetryGeneration,
              device == pendingRetryDevice else {
            cancelPendingRetry()
            return
        }
    }

    private func cancelPendingRetry() {
        pendingRetryToken?.cancel()
        pendingRetryToken = nil
        pendingRetryAttempt = 0
        pendingRetryDevice = nil
        pendingRetryGeneration = nil
        pendingOnOutput = nil
        pendingOnMissing = nil
    }
}

nonisolated final class CoreAudioPlatformClient: AudioPlatformClient, OutputDeviceDiscovering {
    fileprivate final class IOContext {
        let unit: AudioUnit
        let callback: AudioIOCallback
        let verificationHandler: AudioCaptureVerificationHandler
        /// Keeps the exact resolved route with this callback's preallocated
        /// input width so a later route cannot reuse stale source geometry.
        let routing: ResolvedOutputRouting
        let inputChannelCount: Int
        let inputStorage: [UnsafeMutablePointer<Float>]
        // Preallocated once; refreshed in place on every render callback.
        let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>?>
        let inputListStorage: UnsafeMutableRawPointer
        var verificationState: CoreAudioIOVerificationState

        init(
            unit: AudioUnit,
            callback: @escaping AudioIOCallback,
            verificationHandler: @escaping AudioCaptureVerificationHandler,
            routing: ResolvedOutputRouting
        ) {
            let inputChannelCount = routing.sourceChannelIndices.count
            precondition((1...16).contains(inputChannelCount))
            self.unit = unit
            self.callback = callback
            self.verificationHandler = verificationHandler
            self.routing = routing
            self.inputChannelCount = inputChannelCount
            inputPointers = .allocate(capacity: inputChannelCount)
            var storage: [UnsafeMutablePointer<Float>] = []
            storage.reserveCapacity(inputChannelCount)
            for _ in 0..<inputChannelCount {
                storage.append(.allocate(capacity: StereoCallbackBridge.maximumFrames))
            }
            inputStorage = storage
            let byteCount = MemoryLayout<AudioBufferList>.size
                + MemoryLayout<AudioBuffer>.size * (inputChannelCount - 1)
            inputListStorage = .allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
            inputListStorage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            verificationState = CoreAudioIOVerificationState(inputChannelCount: inputChannelCount)
            let inputList = inputListStorage.assumingMemoryBound(to: AudioBufferList.self)
            inputList.pointee.mNumberBuffers = UInt32(inputChannelCount)
            let buffers = UnsafeMutableAudioBufferListPointer(inputList)
            for index in 0..<inputChannelCount {
                buffers[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(StereoCallbackBridge.maximumFrames * MemoryLayout<Float>.size),
                    mData: inputStorage[index]
                )
            }
        }

        deinit {
            for pointer in inputStorage { pointer.deallocate() }
            inputPointers.deallocate()
            inputListStorage.deallocate()
        }
    }

    private let instanceUUID = UUID()
    private var tapUIDs: [AudioObjectID: String] = [:]
    private var aggregateIDs: Set<AudioObjectID> = []
    /// Route metadata shares the aggregate's ownership lifetime. A failed
    /// aggregate teardown keeps both the handle and its routing record.
    private var aggregateRoutings: [AudioObjectID: ResolvedOutputRouting] = [:]
    private var ioContexts: [UInt64: IOContext] = [:]
    private var nextIOHandle: UInt64 = 1
    private var defaultOutputHandler: DefaultOutputChangeHandler?
    private var defaultOutputListenerInstalled = false
    /// Plan 039 Step 1: current-device listeners (nominal rate, stream
    /// config, preferred layout). Installed on the same serial control
    /// queue as default-output observation. Nil blocks are the production
    /// HAL calls; the block slot exists so registration uses one exact
    /// block object for add and remove.
    private var currentDeviceListeners: CurrentDeviceListenerSet!
    private var currentDeviceListenerBlock: AudioObjectPropertyListenerBlock!
    private var lastObservedOutput: OutputDeviceDescriptor?
    private var observationGeneration: UInt64 = 0
    private var availableOutputHandler: AvailableOutputChangeHandler?
    private var availableOutputListenerInstalled = false

    /// Pipeline ownership is exclusive: one client instance serves exactly one
    /// pipeline lifecycle, and its create/destroy calls are strictly ordered.
    /// A second creation while a PRIOR FOREIGN handle is still registered
    /// therefore means a leaked concurrent pipeline — the P0 dead-air
    /// signature. A pipeline's own tap registered moments earlier is part of
    /// the same lifecycle, not a leak.
    private func assertExclusiveResourceCreation(
        resource: String,
        conflictsWithLiveHandle: Bool
    ) {
        guard conflictsWithLiveHandle else { return }
        Logger.log(
            "[CoreAudio] Exclusive-ownership violation: \(resource) created while prior tap/aggregate handles are still registered (taps: \(tapUIDs.keys.sorted()), aggregates: \(aggregateIDs.sorted()))."
        )
        #if DEBUG
        assertionFailure("Airwave created a second \(resource) while a previous tap/aggregate was still registered — leaked concurrent pipeline.")
        #else
        AirwaveLog.audioRuntime.fault(
            "Exclusive pipeline ownership violated: \(resource, privacy: .public) created while prior tap/aggregate handles are still registered."
        )
        #endif
    }

    func defaultOutputDevice() throws -> OutputDeviceDescriptor {
        let deviceID: AudioObjectID = try getSystemObjectValue(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            as: AudioObjectID.self
        )
        guard deviceID != kAudioObjectUnknown else { throw AudioRuntimeError.noOutputDevice }
        return try descriptor(for: deviceID)
    }

    func availableOutputDevices() throws -> [OutputDeviceDescriptor] {
        let deviceIDs = try availableDeviceIDs()
        var descriptorsByUID: [String: OutputDeviceDescriptor] = [:]
        for deviceID in deviceIDs {
            do {
                let descriptor = try descriptor(for: deviceID)
                guard descriptor.isConfigurationEligible else { continue }
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
        ensureCurrentDeviceObservation()
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
            currentDeviceListeners?.unbind()
            defaultOutputHandler = nil
            throw AudioRuntimeError.deviceLost
        }
        defaultOutputListenerInstalled = true
        // Plan 039 Step 1: bind current-device listeners at observation
        // start, not only after the first default-device event. A required
        // registration failure unwinds the system listener too.
        do {
            try bindCurrentDeviceListeners()
        } catch {
            var removeAddress = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &removeAddress,
                .main,
                defaultOutputListener
            )
            defaultOutputListenerInstalled = false
            defaultOutputHandler = nil
            throw error
        }
    }

    func stopObservingDefaultOutput() {
        // Plan 039 Step 1: current-device registrations are always removed,
        // even when the system listener is already gone. Unbind bumps the
        // generation so in-flight events are ignored. Safe to repeat.
        currentDeviceListeners?.unbind()
        lastObservedOutput = nil
        observationGeneration &+= 1
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

    /// Production-path entry for a current-device format event. Generation
    /// guard, unchanged suppression, and delivery bookkeeping live in the
    /// set; this method routes actual changes through the existing handler.
    func handleCurrentDeviceDescriptor(_ fresh: OutputDeviceDescriptor, eventGeneration: UInt64) {
        guard let listeners = currentDeviceListeners,
              listeners.shouldDeliver(fresh, eventGeneration: eventGeneration) else { return }
        lastObservedOutput = fresh
        defaultOutputHandler?(fresh)
    }

    private func ensureCurrentDeviceObservation() {
        if currentDeviceListeners == nil {
            currentDeviceListenerBlock = { [weak self] _, _ in
                guard let self,
                      let listeners = self.currentDeviceListeners,
                      let deviceID = listeners.deviceID else { return }
                let generation = listeners.generation
                listeners.coalescePendingRetry(for: deviceID, eventGeneration: generation)
                let result = Result { try self.descriptor(for: deviceID) }
                switch DefaultOutputObservationDecision.make(from: result) {
                case .output(let output):
                    self.handleCurrentDeviceDescriptor(output, eventGeneration: generation)
                case .missing:
                    self.defaultOutputHandler?(nil)
                case .retainLastValid:
                    // Plan 039 Step 2: a transient read waits for bounded
                    // retries (0.1/0.25/1.0s), not for another OS
                    // notification that may never arrive. A transient read
                    // is not permission denial; exhaustion publishes
                    // unavailable through the established handler.
                    let armed = listeners.noteTransientReadFailure(
                        for: deviceID,
                        eventGeneration: generation,
                        onOutput: { [weak self] output in
                            guard let self else { return }
                            self.lastObservedOutput = output
                            self.defaultOutputHandler?(output)
                        },
                        onMissing: { [weak self] in
                            self?.defaultOutputHandler?(nil)
                        }
                    )
                    if !armed {
                        Logger.log("[CoreAudio] Current device changed before its descriptor was readable: \(result)")
                    }
                }
            }
            currentDeviceListeners = CurrentDeviceListenerSet(
                add: { [weak self] deviceID, address in
                    guard let self, let block = self.currentDeviceListenerBlock else {
                        return kAudioHardwareBadObjectError
                    }
                    var mutableAddress = address
                    return AudioObjectAddPropertyListenerBlock(
                        deviceID,
                        &mutableAddress,
                        .main,
                        block
                    )
                },
                remove: { [weak self] deviceID, address in
                    // Removal runs on the same serial control queue; the
                    // block slot is stable for the client's lifetime, so the
                    // exact registered block is removed. Best effort: the
                    // return value is intentionally ignored on teardown.
                    guard let self, let block = self.currentDeviceListenerBlock else { return noErr }
                    var mutableAddress = address
                    return AudioObjectRemovePropertyListenerBlock(
                        deviceID,
                        &mutableAddress,
                        .main,
                        block
                    )
                },
                read: { [weak self] deviceID in
                    guard let self else { return .failure(AudioRuntimeError.deviceLost) }
                    return Result { try self.descriptor(for: deviceID) }
                },
                scheduler: DispatchCurrentDeviceRetryScheduler()
            )
        }
    }

    /// Plan 039 Step 1: bind the current device when observation starts. No
    /// device yet (`.noOutputDevice`) leaves the set unbound; the first
    /// default-device event binds it. A transient read failure also defers
    /// to the first event so start behavior matches the prior contract.
    private func bindCurrentDeviceListeners() throws {
        guard let listeners = currentDeviceListeners else { return }
        let output: OutputDeviceDescriptor
        do {
            output = try defaultOutputDevice()
        } catch AudioRuntimeError.noOutputDevice {
            return
        } catch {
            Logger.log("[CoreAudio] Deferring current-device listeners until the first output event: \(error)")
            return
        }
        do {
            try listeners.bind(deviceID: AudioObjectID(output.id.value), seed: output)
        } catch {
            Logger.log("[CoreAudio] Current-device listener registration failed; unwound partial registrations.")
            throw error
        }
        lastObservedOutput = output
        observationGeneration = listeners.generation
    }

    private lazy var defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        let result = Result { try self.defaultOutputDevice() }
        switch DefaultOutputObservationDecision.make(from: result) {
        case .output(let fresh):
            let output = self.lastObservedOutput.map {
                fresh.retainingMissingRoutingMetadata(from: $0)
            } ?? fresh
            // Plan 039 Step 1: on replacement, rebind the new device's
            // current-device listeners. The set rolls back partial failures
            // internally; a failed rebind is logged and the descriptor is
            // still delivered through the existing handler path.
            if let listeners = self.currentDeviceListeners {
                let deviceID = AudioObjectID(output.id.value)
                if !listeners.rebindIfNeeded(deviceID: deviceID, seed: output) {
                    Logger.log("[CoreAudio] Current-device listener rebind failed for \(output.uid); delivered without format observation.")
                }
                self.observationGeneration = listeners.generation
                self.lastObservedOutput = output
            }
            self.defaultOutputHandler?(output)
        case .missing:
            self.currentDeviceListeners?.unbind()
            self.lastObservedOutput = nil
            self.defaultOutputHandler?(nil)
        case .retainLastValid:
            // A property notification can race the device graph becoming readable.
            // Preserve the last valid output; a later notification will retry.
            Logger.log("[CoreAudio] Default output changed before its descriptor was readable: \(result)")
        }
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
              (2...16).contains(request.channelCount),
              request.isPrivate,
              !request.outputDeviceUID.isEmpty,
              request.streamIndex >= 0 else {
            throw AudioRuntimeError.tapCreationFailed("Invalid global tap request")
        }
        assertExclusiveResourceCreation(
            resource: "process tap",
            conflictsWithLiveHandle: !tapUIDs.isEmpty || !aggregateIDs.isEmpty
        )
        let description = CATapDescription(
            excludingProcesses: request.excludedProcesses.map { AudioObjectID($0.value) },
            deviceUID: request.outputDeviceUID,
            stream: UInt(request.streamIndex)
        )
        description.name = "Airwave Process Tap"
        description.uuid = instanceUUID
        description.isPrivate = true
        switch request.muteBehavior {
        case .unmuted:
            description.muteBehavior = .unmuted
        case .mutedWhenTapped:
            description.muteBehavior = .mutedWhenTapped
        }

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

    func createPrivateAggregate(tap: AudioTapHandle, routing: ResolvedOutputRouting) throws -> PrivateAggregateHandle {
        let output = routing.device
        guard OutputRoutingResolver.isValid(routing),
              (2...16).contains(output.outputChannelCount), !output.isVirtual, !output.isAggregate,
              (1...16).contains(routing.nativeWidth),
              routing.sourceChannelIndices.count == routing.inputLayout.channels.count else {
            throw AudioRuntimeError.unsupportedOutput(output.name)
        }
        let tapID = AudioObjectID(tap.value)
        guard let tapUID = tapUIDs[tapID] else {
            throw AudioRuntimeError.aggregateCreationFailed("Unknown process tap")
        }
        // Our own tap is guaranteed registered above; a second tap or any
        // aggregate signals a leaked concurrent pipeline.
        assertExclusiveResourceCreation(
            resource: "private aggregate",
            conflictsWithLiveHandle: !aggregateIDs.isEmpty || tapUIDs.count > 1
        )
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
            throw CoreAudioErrorMapping.aggregateCreation(status)
        }
        aggregateIDs.insert(aggregateID)
        aggregateRoutings[aggregateID] = routing
        return PrivateAggregateHandle(value: UInt64(aggregateID))
    }

    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws {
        let aggregateID = AudioObjectID(aggregate.value)
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        guard status == noErr || CoreAudioStatus.isAlreadyGone(status) else {
            throw AudioRuntimeError.cleanupFailed(CoreAudioStatus.creationError(status, operation: "Destroy private aggregate"))
        }
        aggregateIDs.remove(aggregateID)
        aggregateRoutings.removeValue(forKey: aggregateID)
    }

    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat {
        let asbd: AudioStreamBasicDescription = try getObjectValue(
            AudioObjectID(tap.value),
            as: AudioStreamBasicDescription.self,
            selector: kAudioTapPropertyFormat
        )
        return streamFormat(asbd)
    }

    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat {
        let id = AudioObjectID(aggregate.value)
        let sampleRate: Float64 = try getObjectValue(
            id,
            as: Float64.self,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        return AudioStreamFormat(
            sampleRate: sampleRate,
            channelCount: try streamChannelCounts(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +),
            sampleType: .float32,
            isInterleaved: false
        )
    }

    func createIO(
        aggregate: PrivateAggregateHandle,
        routing: ResolvedOutputRouting,
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle {
        let aggregateID = AudioObjectID(aggregate.value)
        guard aggregateIDs.contains(aggregateID),
              let ownedRouting = aggregateRoutings[aggregateID],
              ownedRouting == routing else {
            throw AudioRuntimeError.ioCreationFailed("Unknown aggregate routing")
        }
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
            throw CoreAudioErrorMapping.ioCreation(status, operation: "Create HAL unit")
        }
        do {
            var enabled: UInt32 = 1
            try setUnit(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &enabled)
            try setUnit(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &enabled)
            var currentDevice = aggregateID
            try setUnit(unit, property: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &currentDevice)

            let aggregateFormat = try streamFormat(for: aggregate)
            let expectedOutput = AudioStreamFormat.capturing(
                channels: routing.device.outputChannelCount,
                sampleRate: routing.sampleRate
            )
            guard aggregateFormat.matchesChannelCountAndSampleRate(of: expectedOutput) else {
                throw AudioRuntimeError.ioCreationFailed("Aggregate output format changed before AUHAL setup")
            }
            let rate = aggregateFormat.sampleRate
            let inputChannelMap = try AUHALChannelMapBuilder.make(
                routing: routing,
                physicalInputStreamChannelCounts: streamChannelCounts(
                    AudioObjectID(routing.device.id.value),
                    scope: kAudioObjectPropertyScopeInput
                ),
                aggregateInputStreamChannelCounts: streamChannelCounts(
                    aggregateID,
                    scope: kAudioObjectPropertyScopeInput
                )
            )
            let captureWidth = inputChannelMap.input.count
            var inputFormat = canonicalWideFormat(sampleRate: rate, channelCount: captureWidth)
            try setUnit(unit, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, value: &inputFormat)
            var format = canonicalStereoFormat(sampleRate: rate)
            try setUnit(unit, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: 0, value: &format)

            do {
                try AUHALChannelMapInstaller.install(inputChannelMap) { scope, element, channels in
                    channels.withUnsafeBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else { return kAudio_ParamError }
                        return AudioUnitSetProperty(
                            unit,
                            kAudioOutputUnitProperty_ChannelMap,
                            scope,
                            element,
                            UnsafeRawPointer(baseAddress),
                            UInt32(buffer.count * MemoryLayout<Int32>.size)
                        )
                    }
                }
            } catch AUHALChannelMapInstallationError.input(let mapStatus) {
                throw CoreAudioErrorMapping.ioCreation(mapStatus, operation: "Set AUHAL input channel map")
            } catch AUHALChannelMapInstallationError.output(let mapStatus) {
                throw CoreAudioErrorMapping.ioCreation(mapStatus, operation: "Set AUHAL output channel map")
            } catch {
                throw error
            }
            AirwaveLog.audio.info(
                "IO formats: selected input bus (\(captureWidth) ch) / stereo output bus @ \(rate) Hz"
            )
            var maximumFrames = UInt32(StereoCallbackBridge.maximumFrames)
            try setUnit(unit, property: kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, value: &maximumFrames)

            let context = IOContext(
                unit: unit,
                callback: callback,
                verificationHandler: verificationHandler,
                routing: routing
            )
            var render = AURenderCallbackStruct(
                inputProc: coreAudioRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try setUnit(unit, property: kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, element: 0, value: &render)
            status = AudioUnitInitialize(unit)
            guard status == noErr else {
                throw CoreAudioErrorMapping.ioCreation(status, operation: "Initialize HAL unit")
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

    private func getSystemObjectValue<T>(selector: AudioObjectPropertySelector, as type: T.Type) throws -> T {
        try getObjectValue(AudioObjectID(kAudioObjectSystemObject), as: type, selector: selector)
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
        let transport: UInt32 = try getObjectValue(
            deviceID,
            as: UInt32.self,
            selector: kAudioDevicePropertyTransportType
        )
        let sampleRate: Float64 = try getObjectValue(
            deviceID,
            as: Float64.self,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        let streamChannels = try streamChannelCounts(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let outputStreams = outputStreamDescriptors(deviceID)
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate
        let isVirtual = transport == kAudioDeviceTransportTypeVirtual || isAggregate
        return OutputDeviceDescriptor(
            id: .init(UInt64(deviceID)),
            uid: uid,
            name: name,
            transport: fourCC(transport),
            channelLabels: outputChannelLabels(deviceID),
            outputChannelCount: streamChannels.reduce(0, +),
            nominalSampleRate: sampleRate,
            isVirtual: isVirtual,
            isAggregate: isAggregate,
            outputStreamCount: OutputStreamInventory.count(
                actualStreams: outputStreams,
                fallbackBufferCount: streamChannels.count
            ),
            outputStreams: outputStreams ?? [],
            preferredStereoChannels: preferredStereoChannels(deviceID)
        )
    }

    private static func sortDescriptors(_ lhs: OutputDeviceDescriptor, _ rhs: OutputDeviceDescriptor) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame ? lhs.uid < rhs.uid : comparison == .orderedAscending
    }

    private func getObjectValue<T>(
        _ objectID: AudioObjectID,
        as _: T.Type,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let expectedSize = MemoryLayout<T>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: expectedSize, alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        var size = UInt32(expectedSize)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage)
        guard status == noErr, Int(size) == expectedSize else { throw AudioRuntimeError.deviceLost }
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
        // Core Audio returns owned values for the device UID and object name.
        return value.takeRetainedValue() as String
    }

    private func streamChannelCounts(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
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
        return list.map { Int($0.mNumberChannels) }
    }

    /// Reads actual AudioStream objects, which are distinct from the buffers
    /// reported by kAudioDevicePropertyStreamConfiguration. A malformed or
    /// temporarily unreadable optional property yields no ranges; callers keep
    /// the physical device visible but the pure resolver will refuse to guess.
    private func outputStreamDescriptors(_ objectID: AudioObjectID) -> [OutputStreamDescriptor]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<AudioStreamID>.stride
        guard size > 0,
              Int(size) % stride == 0,
              Int(size) / stride <= 64 else { return nil }
        let byteCount = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioStreamID>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr,
              Int(size) <= byteCount,
              Int(size) % stride == 0 else { return nil }

        let streamCount = Int(size) / stride
        let streamIDs = storage.assumingMemoryBound(to: AudioStreamID.self)
        var descriptors: [OutputStreamDescriptor] = []
        descriptors.reserveCapacity(streamCount)
        for index in 0..<streamCount {
            let streamID = streamIDs[index]
            // Constrain T before try? lifts the result to an optional. A type
            // annotation on the optional binding alone can infer Optional<T>,
            // which changes the raw property size and rejects valid CoreAudio data.
            guard let startingChannel = try? getObjectValue(
                streamID,
                as: UInt32.self,
                selector: kAudioStreamPropertyStartingChannel
            ),
                  let format = try? getObjectValue(
                    streamID,
                    as: AudioStreamBasicDescription.self,
                    selector: kAudioStreamPropertyVirtualFormat
                  ),
                  startingChannel > 0,
                  format.mChannelsPerFrame > 0 else { return nil }
            descriptors.append(OutputStreamDescriptor(
                streamIndex: index,
                startingChannel: Int(startingChannel),
                channelCount: Int(format.mChannelsPerFrame)
            ))
        }
        return descriptors.isEmpty ? nil : descriptors
    }

    /// The preferred pair is optional, read-only, and exactly two UInt32
    /// device channel numbers. Invalid sizes or transient property failures
    /// are ignored and route resolution falls back to channels 1–2.
    private func preferredStereoChannels(_ objectID: AudioObjectID) -> StereoOutputChannels? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let expectedSize = MemoryLayout<UInt32>.stride * 2
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              Int(size) == expectedSize else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: expectedSize,
            alignment: MemoryLayout<UInt32>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr,
              Int(size) == expectedSize else { return nil }
        let channels = storage.assumingMemoryBound(to: UInt32.self)
        return StereoOutputChannels(left: Int(channels[0]), right: Int(channels[1]))
    }

    /// Best-effort read of the device's output channel labels. Nil means the
    /// property was unreadable or malformed; callers fall back to count-based
    /// layout detection. Reads the preferred-layout bytes on control, checks
    /// the byte count before the fixed header or trailing descriptions, and
    /// bounds description counts with checked size arithmetic before any read.
    /// Each native form has its own path: explicit descriptions, layout tag,
    /// and channel bitmap, all through public AudioFormat conversion. The
    /// expanded count must equal the output stream width. Missing metadata
    /// stays nil (count fallback); supplied invalid metadata also stays nil
    /// so support policy can reject it as unresolved.
    private func outputChannelLabels(_ objectID: AudioObjectID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        let minimumSize = MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size
        guard Int(size) >= minimumSize else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr else { return nil }

        let base = storage.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        // Variable-length trailing array: descriptions begin where the
        // fixed-size header ends (both types share 4-byte alignment).
        let headerBytes = minimumSize
        switch base.mChannelLayoutTag {
        case kAudioChannelLayoutTag_UseChannelDescriptions:
            return NativeChannelLayoutReader.labelsFromDescriptions(
                count: Int(base.mNumberChannelDescriptions),
                descriptions: storage.advanced(by: headerBytes).assumingMemoryBound(to: AudioChannelDescription.self),
                capacityBytes: Int(size) - headerBytes
            )
        case kAudioChannelLayoutTag_UseChannelBitmap:
            return NativeChannelLayoutReader.labelsFromBitmap(base.mChannelBitmap)
        case kAudioChannelLayoutTag_Unknown:
            return nil
        default:
            return NativeChannelLayoutReader.labelsFromTag(base.mChannelLayoutTag)
        }
    }

    /// Pure native-layout boundary. Tag and bitmap expand through public
    /// AudioFormat conversion; description buffers need checked size
    /// arithmetic and a count check before any read. Small injectable seam
    /// for regression tests: no hardware needed.
    nonisolated enum NativeChannelLayoutReader {
        static let maximumDescriptions = 64

        /// Stub override for host-side diagnosis and regression tests.
        /// Production path leaves this nil and calls AudioFormat. Tests set
        /// it to replay recorded AudioFormat results without hardware.
        nonisolated(unsafe) static var convertedLayoutStub: ((_ tag: AudioChannelLayoutTag, _ bitmap: UInt32?) -> [UInt32]?)?

        static func labelsFromDescriptions(
            count: Int,
            descriptions: UnsafePointer<AudioChannelDescription>,
            capacityBytes: Int
        ) -> [UInt32]? {
            guard count > 0, count <= maximumDescriptions else { return nil }
            let (capacity, overflow) = capacityBytes.dividedReportingOverflow(
                by: MemoryLayout<AudioChannelDescription>.stride
            )
            guard !overflow, count <= capacity else { return nil }
            return (0..<count).map { descriptions[$0].mChannelLabel }
        }

        static func labelsFromBitmap(_ bitmap: AudioChannelBitmap) -> [UInt32]? {
            guard bitmap.rawValue != 0 else { return nil }
            if let stub = convertedLayoutStub {
                return stub(kAudioChannelLayoutTag_UseChannelBitmap, bitmap.rawValue)
            }
            var specifier = bitmap.rawValue
            var infoSize: UInt32 = 0
            guard AudioFormatGetPropertyInfo(
                kAudioFormatProperty_ChannelLayoutForBitmap,
                UInt32(MemoryLayout<UInt32>.size),
                &specifier,
                &infoSize
            ) == noErr, infoSize > 0 else { return nil }
            return labelsFromConvertedLayout(
                property: kAudioFormatProperty_ChannelLayoutForBitmap,
                specifierSize: UInt32(MemoryLayout<UInt32>.size),
                specifier: &specifier,
                size: infoSize
            )
        }

        static func labelsFromTag(_ tag: AudioChannelLayoutTag) -> [UInt32]? {
            if let stub = convertedLayoutStub {
                return stub(tag, nil)
            }
            var specifier = tag
            var infoSize: UInt32 = 0
            guard AudioFormatGetPropertyInfo(
                kAudioFormatProperty_ChannelLayoutForTag,
                UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                &specifier,
                &infoSize
            ) == noErr, infoSize > 0 else { return nil }
            return labelsFromConvertedLayout(
                property: kAudioFormatProperty_ChannelLayoutForTag,
                specifierSize: UInt32(MemoryLayout<AudioChannelLayoutTag>.size),
                specifier: &specifier,
                size: infoSize
            )
        }

        private static func labelsFromConvertedLayout(
            property: AudioFormatPropertyID,
            specifierSize: UInt32,
            specifier: UnsafeRawPointer,
            size: UInt32
        ) -> [UInt32]? {
            let headerBytes = MemoryLayout<AudioChannelLayout>.size - MemoryLayout<AudioChannelDescription>.size
            guard Int(size) >= headerBytes, Int(size) <= headerBytes + maximumDescriptions * MemoryLayout<AudioChannelDescription>.stride else {
                return nil
            }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { storage.deallocate() }
            var outputSize = size
            guard AudioFormatGetProperty(
                property,
                specifierSize,
                specifier,
                &outputSize,
                storage
            ) == noErr, outputSize == size else { return nil }
            let base = storage.assumingMemoryBound(to: AudioChannelLayout.self).pointee
            // Standard tags keep their tag on return (e.g. Stereo returns
            // tag Stereo with 2 inline descriptions); bitmap conversion
            // returns UseChannelDescriptions. Either form is valid when the
            // description count matches the returned byte size exactly.
            let count = Int(base.mNumberChannelDescriptions)
            guard count > 0, count <= maximumDescriptions else { return nil }
            guard Int(outputSize) == headerBytes + count * MemoryLayout<AudioChannelDescription>.stride else { return nil }
            return labelsFromDescriptions(
                count: Int(base.mNumberChannelDescriptions),
                descriptions: storage.advanced(by: headerBytes).assumingMemoryBound(to: AudioChannelDescription.self),
                capacityBytes: Int(outputSize) - headerBytes
            )
        }
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
        Self.canonicalNonInterleavedFloat32Format(sampleRate: sampleRate, channelCount: 2)
    }

    /// Same canonical float32 non-interleaved shape, at capture width.
    /// Non-interleaved buffers each store a single channel, so one frame is
    /// always 4 bytes per buffer (one Float32 sample) regardless of width;
    /// only `mChannelsPerFrame` widens.
    private func canonicalWideFormat(sampleRate: Double, channelCount: Int) -> AudioStreamBasicDescription {
        Self.canonicalNonInterleavedFloat32Format(sampleRate: sampleRate, channelCount: channelCount)
    }

    /// Canonical capture-side ASBD: packed Float32, non-interleaved. Every
    /// AudioBuffer carries exactly one channel, so `mBytesPerFrame` stays
    /// 4 (one sample per buffer per frame) no matter how wide the stream is.
    nonisolated static func canonicalNonInterleavedFloat32Format(
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
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
            throw CoreAudioErrorMapping.ioCreation(status, operation: "Configure HAL unit")
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
    guard status == noErr else {
        if let event = context.verificationState.observeRenderFailure(status: status) {
            context.verificationHandler(event)
        }
        return status
    }
    // Refresh the preallocated pointer array in place; no per-callback
    // allocation on this realtime path.
    for index in 0..<context.inputChannelCount {
        context.inputPointers[index] = UnsafePointer<Float>(context.inputStorage[index])
    }
    if let event = context.verificationState.observeSignal(
        inputChannels: UnsafePointer(context.inputPointers),
        inputChannelCount: context.inputChannelCount,
        frameCount: output.frameCount
    ) {
        context.verificationHandler(event)
    }
    context.callback(
        UnsafePointer(context.inputPointers),
        context.inputChannelCount,
        output.left,
        output.right,
        output.frameCount
    )
    return noErr
}
