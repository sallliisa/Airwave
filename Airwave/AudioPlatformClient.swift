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
    /// Raw `kAudioChannelLabel` values from the device's output channel layout.
    /// Nil when unreadable; absence triggers count-based layout detection.
    let channelLabels: [UInt32]?
    let outputChannelCount: Int
    let outputStreamCount: Int
    let nominalSampleRate: Double
    let isVirtual: Bool
    let isAggregate: Bool

    init(
        id: ID,
        uid: String,
        name: String,
        transport: String,
        channelLabels: [UInt32]?,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        isVirtual: Bool,
        isAggregate: Bool,
        outputStreamCount: Int = 1
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.channelLabels = channelLabels
        self.outputChannelCount = outputChannelCount
        self.outputStreamCount = outputStreamCount
        self.nominalSampleRate = nominalSampleRate
        self.isVirtual = isVirtual
        self.isAggregate = isAggregate
    }

    /// The single support policy shared by persistence and the audio runtime.
    var isSupportedProfileOutput: Bool {
        !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isVirtual && !isAggregate && outputStreamCount == 1
            && (2...16).contains(outputChannelCount)
    }

    var unsupportedProfileReason: String? {
        if uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The output has no stable device identity."
        }
        if isVirtual || isAggregate {
            return "Unsupported virtual or aggregate output. Change output in macOS Settings."
        }
        if outputStreamCount != 1 {
            return "Airwave supports physical output devices with one output stream."
        }
        if !(2...16).contains(outputChannelCount) {
            return "Airwave supports 2 to 16 output channels on physical devices."
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

    /// Expected capture format for a device stream of the given width.
    static func capturing(channels: Int, sampleRate: Double) -> Self {
        Self(sampleRate: sampleRate, channelCount: channels, sampleType: .float32, isInterleaved: false)
    }

    /// AUHAL converts interleaved tap/aggregate streams into the canonical
    /// non-interleaved callback format configured by CoreAudioPlatformClient.
    /// Width follows the tapped device stream; the binaural output stays stereo.
    func isFloat32CaptureCompatible(with expected: Self) -> Bool {
        (1...16).contains(channelCount)
            && (1...16).contains(expected.channelCount)
            && channelCount == expected.channelCount
            && sampleType == .float32
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

nonisolated enum AudioTapMuteBehavior: Equatable, Sendable {
    case unmuted
    case mutedWhenTapped
}

nonisolated enum AudioPipelinePurpose: Equatable, Sendable {
    case verification(includeOwnProcess: Bool)
    case processing
}

nonisolated struct GlobalStereoTapRequest: Equatable, Sendable {
    let excludedProcesses: [AudioProcessHandle]
    let outputDeviceUID: String
    let streamIndex: Int
    let isGlobal: Bool
    let channelCount: Int
    let isPrivate: Bool
    let muteBehavior: AudioTapMuteBehavior

    /// Historical name: the tap is still global and private, but its width
    /// now follows the tapped output device's channel count (2...16) instead
    /// of being hardcoded stereo.
    init(
        excludedProcesses: [AudioProcessHandle],
        output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior = .mutedWhenTapped
    ) {
        self.excludedProcesses = excludedProcesses
        self.outputDeviceUID = output.uid
        self.streamIndex = 0
        self.isGlobal = true
        self.channelCount = output.outputChannelCount
        self.isPrivate = true
        self.muteBehavior = muteBehavior
    }

    init(
        excludedProcess: AudioProcessHandle,
        output: OutputDeviceDescriptor,
        muteBehavior: AudioTapMuteBehavior = .mutedWhenTapped
    ) {
        self.init(excludedProcesses: [excludedProcess], output: output, muteBehavior: muteBehavior)
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
typealias AvailableOutputChangeHandler = ([OutputDeviceDescriptor]) -> Void
typealias AudioIOCallback = (
    _ inputChannels: UnsafePointer<UnsafePointer<Float>?>,
    _ inputChannelCount: Int,
    _ outputLeft: UnsafeMutablePointer<Float>,
    _ outputRight: UnsafeMutablePointer<Float>,
    _ frameCount: Int
) -> Void

nonisolated struct CaptureSignalPolicy: Equatable, Sendable {
    static let sampleThreshold: Float = 0.0001
    static let minimumSustainedFrames = 2_048

    private var sustainedFrames = 0

    /// Observe one channel. Returns whether this call completed a detection;
    /// the latch itself lives in the caller (see
    /// `CoreAudioIOVerificationState`).
    mutating func observe(
        channel: UnsafePointer<Float>,
        frameCount: Int
    ) -> Bool {
        guard frameCount > 0 else { return hasDetectedSignal }
        for index in 0..<frameCount {
            let sample = channel[index]
            let active = sample.isFinite && abs(sample) >= Self.sampleThreshold
            if active {
                sustainedFrames += 1
                if sustainedFrames >= Self.minimumSustainedFrames {
                    return true
                }
            } else {
                sustainedFrames = 0
            }
        }
        return false
    }

    /// True once any observation has completed the sustained-frame threshold.
    var hasDetectedSignal: Bool {
        sustainedFrames >= Self.minimumSustainedFrames
    }
}

nonisolated enum AudioCaptureVerificationEvent: Equatable, Sendable {
    case signalDetected
    case permissionDenied
    case renderFailed(OSStatus)

    static let tapReady = Self.signalDetected
}

typealias AudioCaptureVerificationHandler = @Sendable (AudioCaptureVerificationEvent) -> Void

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
        callback: @escaping AudioIOCallback,
        verificationHandler: @escaping AudioCaptureVerificationHandler
    ) throws -> AudioIOHandle
    func startIO(_ io: AudioIOHandle) throws
    func stopIO(_ io: AudioIOHandle) throws
    func destroyIO(_ io: AudioIOHandle) throws

    func openAudioCapturePermissionSettings()
}

nonisolated protocol OutputDeviceDiscovering: AnyObject {
    func availableOutputDevices() throws -> [OutputDeviceDescriptor]
    func observeAvailableOutputs(_ handler: @escaping AvailableOutputChangeHandler) throws
    func stopObservingAvailableOutputs()
}
