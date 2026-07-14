import Foundation

/// Stable metadata safe to expose to UI. Core Audio object identifiers never cross this boundary.
nonisolated struct OutputDeviceDescriptor: Equatable, Sendable {
    nonisolated struct ID: Hashable, Sendable {
        let value: UInt64

        init(_ value: UInt64) {
            self.value = value
        }
    }

    let id: ID
    let uid: String
    let name: String
    let transport: String
    let outputChannelCount: Int
    let nominalSampleRate: Double
    let isVirtual: Bool
    let isAggregate: Bool
}

nonisolated struct AudioStreamFormat: Equatable, Sendable {
    enum SampleType: Equatable, Sendable {
        case float32
        case unsupported
    }

    let sampleRate: Double
    let channelCount: Int
    let sampleType: SampleType
    let isInterleaved: Bool

    static func stereo(sampleRate: Double) -> Self {
        Self(sampleRate: sampleRate, channelCount: 2, sampleType: .float32, isInterleaved: false)
    }
}

nonisolated struct AudioProcessHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct AudioTapHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct PrivateAggregateHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct AudioIOHandle: Hashable, Sendable { let value: UInt64 }

nonisolated struct GlobalStereoTapRequest: Equatable, Sendable {
    let excludedProcess: AudioProcessHandle
    let isGlobal: Bool
    let channelCount: Int
    let isPrivate: Bool
    let mutedWhenTapped: Bool

    init(excludedProcess: AudioProcessHandle) {
        self.excludedProcess = excludedProcess
        self.isGlobal = true
        self.channelCount = 2
        self.isPrivate = true
        self.mutedWhenTapped = true
    }
}

nonisolated enum AudioRuntimeError: Error, Equatable {
    case permissionDenied
    case noOutputDevice
    case unsupportedOutput(String)
    case tapCreationFailed(String)
    case aggregateCreationFailed(String)
    case formatMismatch(expected: AudioStreamFormat, actual: AudioStreamFormat)
    case ioCreationFailed(String)
    case ioStartFailed(String)
    case deviceLost
    case cleanupFailed(String)
}

typealias DefaultOutputChangeHandler = @Sendable (OutputDeviceDescriptor?) -> Void
typealias AudioIOCallback = (
    _ inputLeft: UnsafePointer<Float>,
    _ inputRight: UnsafePointer<Float>?,
    _ outputLeft: UnsafeMutablePointer<Float>,
    _ outputRight: UnsafeMutablePointer<Float>,
    _ frameCount: Int
) -> Void

/// Capability-oriented Core Audio boundary. It intentionally contains no route or volume writes.
nonisolated protocol AudioPlatformClient: AnyObject {
    func defaultOutputDevice() throws -> OutputDeviceDescriptor
    func observeDefaultOutput(_ handler: @escaping DefaultOutputChangeHandler) throws
    func stopObservingDefaultOutput()

    func resolveOwnProcess() throws -> AudioProcessHandle
    func createGlobalStereoTap(_ request: GlobalStereoTapRequest) throws -> AudioTapHandle
    func destroyTap(_ tap: AudioTapHandle) throws

    func createPrivateAggregate(
        tap: AudioTapHandle,
        output: OutputDeviceDescriptor
    ) throws -> PrivateAggregateHandle
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws

    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat

    func createIO(
        aggregate: PrivateAggregateHandle,
        callback: @escaping AudioIOCallback
    ) throws -> AudioIOHandle
    func startIO(_ io: AudioIOHandle) throws
    func stopIO(_ io: AudioIOHandle) throws
    func destroyIO(_ io: AudioIOHandle) throws

    func openAudioCapturePermissionSettings()
}
