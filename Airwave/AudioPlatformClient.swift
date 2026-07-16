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

    /// The single support policy shared by persistence and the audio runtime.
    var isSupportedProfileOutput: Bool {
        !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isVirtual && !isAggregate && outputChannelCount == 2
    }

    var unsupportedProfileReason: String? {
        if uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The output has no stable device identity."
        }
        if isVirtual || isAggregate {
            return "Unsupported virtual or aggregate output. Change output in macOS Settings."
        }
        if outputChannelCount != 2 {
            return "Airwave requires a stereo output. Change output in macOS Settings."
        }
        return nil
    }
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

    /// AUHAL converts interleaved tap/aggregate streams into the canonical
    /// non-interleaved callback format configured by CoreAudioPlatformClient.
    func isStereoFloat32Compatible(with expected: Self) -> Bool {
        channelCount == 2
            && sampleType == .float32
            && expected.channelCount == 2
            && expected.sampleType == .float32
            && AudioSampleRateCompatibility.matches(sampleRate, with: expected.sampleRate)
    }
}

/// Sample-rate compatibility for the process-tap/aggregate path.
///
/// The device-bound tap and physical output must use the same rate. AUHAL may
/// convert PCM layout, but no realtime sample-rate conversion is provided.
nonisolated enum AudioSampleRateCompatibility {
    static let tolerance = 0.5

    static func matches(_ actual: Double, with expected: Double) -> Bool {
        guard actual.isFinite, expected.isFinite, actual > 0, expected > 0 else {
            return false
        }
        return abs(actual - expected) < tolerance
    }
}

nonisolated struct AudioProcessHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct AudioTapHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct PrivateAggregateHandle: Hashable, Sendable { let value: UInt64 }
nonisolated struct AudioIOHandle: Hashable, Sendable { let value: UInt64 }

nonisolated struct GlobalStereoTapRequest: Equatable, Sendable {
    let excludedProcess: AudioProcessHandle
    let outputDeviceUID: String
    let streamIndex: Int
    let isGlobal: Bool
    let channelCount: Int
    let isPrivate: Bool
    let mutedWhenTapped: Bool

    init(excludedProcess: AudioProcessHandle, output: OutputDeviceDescriptor) {
        self.excludedProcess = excludedProcess
        self.outputDeviceUID = output.uid
        self.streamIndex = 0
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

typealias DefaultOutputChangeHandler = (OutputDeviceDescriptor?) -> Void
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
