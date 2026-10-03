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
    /// Actual output AudioStream count when readable. ABL buffer count is used
    /// only as a safe transient-metadata fallback for existing descriptors.
    let outputStreamCount: Int
    /// Ranges reported by the device's actual output AudioStreams. Empty means
    /// Core Audio could not provide usable stream metadata.
    let outputStreams: [OutputStreamDescriptor]
    /// Read-only Core Audio stereo preference in one-based device channels.
    let preferredStereoChannels: StereoOutputChannels?
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
        outputStreamCount: Int = 1,
        outputStreams: [OutputStreamDescriptor]? = nil,
        preferredStereoChannels: StereoOutputChannels? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.channelLabels = channelLabels
        self.outputChannelCount = outputChannelCount
        self.outputStreamCount = outputStreamCount
        // Existing descriptor fixtures predate per-AudioStream metadata. Keep
        // their explicitly single-stream shape usable in pure route tests;
        // production passes [] when Core Audio metadata is absent and never
        // fabricates ranges from the device's aggregate buffer count.
        self.outputStreams = outputStreams ?? (outputStreamCount == 1 && outputChannelCount > 0
            ? [OutputStreamDescriptor(streamIndex: 0, startingChannel: 1, channelCount: outputChannelCount)]
            : [])
        self.preferredStereoChannels = preferredStereoChannels
        self.nominalSampleRate = nominalSampleRate
        self.isVirtual = isVirtual
        self.isAggregate = isAggregate
    }

    /// Existing pipeline-startup support policy. Device configuration uses
    /// `isConfigurationEligible` separately until route resolution is wired
    /// into the runtime in the following plan steps.
    /// Layout shape comes from InputLayoutResolver.resolve: unlabeled
    /// 2/6/8/12 use the standard fallback order, unlabeled 4 uses the generic
    /// quad fallback (not verified identity), and other widths need a
    /// complete usable label mapping. Duplicate explicit stereo pairs stay
    /// unsupported (ambiguous; needs separate pair selection).
    var isSupportedProfileOutput: Bool {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isVirtual, !isAggregate, outputStreamCount == 1,
              (2...16).contains(outputChannelCount)
        else { return false }
        if case .supported = InputLayoutResolver.resolve(
            channelLabels: channelLabels,
            channelCount: outputChannelCount
        ) { return true }
        return false
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
        if case .unsupported(let reason) = InputLayoutResolver.resolve(
            channelLabels: channelLabels,
            channelCount: outputChannelCount
        ) {
            return reason
        }
        return nil
    }

    /// Device inventory and output configuration intentionally have a wider
    /// eligibility boundary than pipeline startup. Ambiguous speaker labels
    /// do not prevent a user from assigning physical stereo destinations;
    /// route resolution still decides whether the capture feed is safe.
    var isConfigurationEligible: Bool {
        !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isVirtual
            && !isAggregate
            && (2...16).contains(outputChannelCount)
    }

    var configurationEligibilityReason: String? {
        if uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The output has no stable device identity."
        }
        if isVirtual || isAggregate {
            return "Airwave supports physical output devices only."
        }
        if !(2...16).contains(outputChannelCount) {
            return "Airwave supports 2 to 16 output channels on physical devices."
        }
        return nil
    }

    /// An optional property can fail transiently while the device's required
    /// descriptor still reads successfully. Keep its last usable routing data
    /// only when the stable UID and channel shape are unchanged.
    func retainingMissingRoutingMetadata(from previous: Self) -> Self {
        guard uid == previous.uid,
              outputChannelCount == previous.outputChannelCount else { return self }
        let missingStreams = outputStreams.isEmpty
        let streams = missingStreams ? previous.outputStreams : outputStreams
        let streamCount = missingStreams ? previous.outputStreamCount : outputStreamCount
        let preferred = preferredStereoChannels ?? previous.preferredStereoChannels
        guard streams != outputStreams
                || streamCount != outputStreamCount
                || preferred != preferredStereoChannels else { return self }
        return Self(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            channelLabels: channelLabels,
            outputChannelCount: outputChannelCount,
            nominalSampleRate: nominalSampleRate,
            isVirtual: isVirtual,
            isAggregate: isAggregate,
            outputStreamCount: streamCount,
            outputStreams: streams,
            preferredStereoChannels: preferred
        )
    }
}

/// Resolves the device stream inventory independently from the ABL buffer
/// geometry. The latter remains a fallback only when the optional stream
/// metadata read failed.
nonisolated enum OutputStreamInventory {
    static func count(
        actualStreams: [OutputStreamDescriptor]?,
        fallbackBufferCount: Int
    ) -> Int {
        actualStreams?.count ?? fallbackBufferCount
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

    /// Match the physical aggregate output independently from the narrower
    /// source channels selected for capture.
    func matchesChannelCountAndSampleRate(of expected: Self) -> Bool {
        channelCount == expected.channelCount
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

    init(
        excludedProcesses: [AudioProcessHandle],
        routing: ResolvedOutputRouting,
        muteBehavior: AudioTapMuteBehavior = .mutedWhenTapped
    ) {
        self.excludedProcesses = excludedProcesses
        self.outputDeviceUID = routing.device.uid
        self.streamIndex = routing.tapStreamIndex
        self.isGlobal = true
        self.channelCount = routing.nativeWidth
        self.isPrivate = true
        self.muteBehavior = muteBehavior
    }

    init(
        excludedProcess: AudioProcessHandle,
        routing: ResolvedOutputRouting,
        muteBehavior: AudioTapMuteBehavior = .mutedWhenTapped
    ) {
        self.init(excludedProcesses: [excludedProcess], routing: routing, muteBehavior: muteBehavior)
    }
}

/// The maps passed to the two AUHAL buses. `input` maps the aggregate's
/// captured source channels to the client capture bus. `output` maps the
/// client's fixed stereo pair to physical device destinations.
nonisolated struct AUHALChannelMaps: Equatable, Sendable {
    let input: [Int32]
    let output: [Int32]
    let tapInputOffset: Int
}

nonisolated enum AUHALChannelMapError: Error, Equatable {
    case invalidCaptureSelection
    case aggregateInputDoesNotEndWithTap
    case invalidOutputSelection
}

/// Builds every map on the control path. Aggregate input geometry must be
/// exactly the physical input stream prefix followed by the selected tap
/// stream; a microphone channel can never be mistaken for tapped output.
nonisolated enum AUHALChannelMapBuilder {
    static func make(
        routing: ResolvedOutputRouting,
        physicalInputStreamChannelCounts: [Int],
        aggregateInputStreamChannelCounts: [Int]
    ) throws -> AUHALChannelMaps {
        guard OutputRoutingResolver.isValid(routing),
              (1...16).contains(routing.nativeWidth),
              !routing.sourceChannelIndices.isEmpty,
              routing.sourceChannelIndices.count == routing.inputLayout.channels.count,
              routing.sourceChannelIndices.count <= 16,
              Set(routing.sourceChannelIndices).count == routing.sourceChannelIndices.count,
              routing.sourceChannelIndices.allSatisfy({ (0..<routing.nativeWidth).contains($0) }) else {
            throw AUHALChannelMapError.invalidCaptureSelection
        }

        let tapInputOffset = try resolveTapInputOffset(
            physicalInputStreamChannelCounts: physicalInputStreamChannelCounts,
            aggregateInputStreamChannelCounts: aggregateInputStreamChannelCounts,
            tapNativeWidth: routing.nativeWidth
        )
        let input = routing.sourceChannelIndices.map { index in
            Int32(tapInputOffset + index)
        }

        let destinationChannels = routing.device.outputChannelCount
        let pair = routing.outputChannels
        guard (1...16).contains(destinationChannels),
              OutputRoutingResolver.isValidDestination(pair, output: routing.device) else {
            throw AUHALChannelMapError.invalidOutputSelection
        }
        var output = [Int32](repeating: -1, count: destinationChannels)
        output[pair.left - 1] = 0
        output[pair.right - 1] = 1
        return AUHALChannelMaps(input: input, output: output, tapInputOffset: tapInputOffset)
    }

    static func resolveTapInputOffset(
        physicalInputStreamChannelCounts: [Int],
        aggregateInputStreamChannelCounts: [Int],
        tapNativeWidth: Int
    ) throws -> Int {
        guard (1...16).contains(tapNativeWidth),
              physicalInputStreamChannelCounts.count <= 64,
              aggregateInputStreamChannelCounts.count <= 65,
              physicalInputStreamChannelCounts.allSatisfy({ $0 >= 0 }),
              aggregateInputStreamChannelCounts.allSatisfy({ $0 >= 0 }),
              aggregateInputStreamChannelCounts.count == physicalInputStreamChannelCounts.count + 1,
              Array(aggregateInputStreamChannelCounts.prefix(physicalInputStreamChannelCounts.count))
                == physicalInputStreamChannelCounts,
              aggregateInputStreamChannelCounts.last == tapNativeWidth else {
            throw AUHALChannelMapError.aggregateInputDoesNotEndWithTap
        }
        var offset = 0
        for channelCount in physicalInputStreamChannelCounts {
            let (nextOffset, overflow) = offset.addingReportingOverflow(channelCount)
            guard !overflow else { throw AUHALChannelMapError.aggregateInputDoesNotEndWithTap }
            offset = nextOffset
        }
        guard offset <= Int(Int32.max) - tapNativeWidth else { throw AUHALChannelMapError.aggregateInputDoesNotEndWithTap }
        return offset
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
    static let windowFrames = 2_048
    static let minimumActiveFrames = 1_024

    private var detected = false
    private var observedFrames = 0
    private var activeFrames = 0

    /// Observe one channel. Returns whether a complete window has accepted
    /// a signal; the result latches, so later calls keep returning true.
    /// The one-shot event itself lives in the caller (see
    /// `CoreAudioIOVerificationState`).
    mutating func observe(
        channel: UnsafePointer<Float>,
        frameCount: Int
    ) -> Bool {
        guard !detected else { return true }
        guard frameCount > 0 else { return false }
        for index in 0..<frameCount {
            let sample = channel[index]
            observeSample(active: sample.isFinite && abs(sample) >= Self.sampleThreshold)
            if detected { return true }
        }
        return false
    }

    /// Advance this channel through an unobserved gap with inactive frames,
    /// so a partial window never bridges the gap as if it were continuous.
    /// A gap can still complete a pending window when earlier frames in
    /// that same window already qualify it.
    mutating func observeMissing(frameCount: Int) -> Bool {
        guard !detected else { return true }
        guard frameCount > 0 else { return false }
        for _ in 0..<frameCount {
            observeSample(active: false)
            if detected { return true }
        }
        return false
    }

    private mutating func observeSample(active: Bool) {
        guard !detected else { return }
        if active { activeFrames += 1 }
        observedFrames += 1
        guard observedFrames >= Self.windowFrames else { return }
        if activeFrames >= Self.minimumActiveFrames { detected = true }
        observedFrames = 0
        activeFrames = 0
    }

    /// True once a complete window has accepted a signal.
    var hasDetectedSignal: Bool {
        detected
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
        routing: ResolvedOutputRouting
    ) throws -> PrivateAggregateHandle
    func destroyPrivateAggregate(_ aggregate: PrivateAggregateHandle) throws

    func streamFormat(for tap: AudioTapHandle) throws -> AudioStreamFormat
    func streamFormat(for aggregate: PrivateAggregateHandle) throws -> AudioStreamFormat

    func createIO(
        aggregate: PrivateAggregateHandle,
        routing: ResolvedOutputRouting,
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

extension OutputDeviceDescriptor {
    /// Processing and route changes for the same device. Identity
    /// (id/uid/name/transport) is excluded.
    func hasProcessingFormatChange(from other: Self) -> Bool {
        !AudioSampleRateCompatibility.matches(nominalSampleRate, with: other.nominalSampleRate)
            || outputChannelCount != other.outputChannelCount
            || outputStreamCount != other.outputStreamCount
            || channelLabels != other.channelLabels
            || outputStreams != other.outputStreams
            || preferredStereoChannels != other.preferredStereoChannels
    }
}
