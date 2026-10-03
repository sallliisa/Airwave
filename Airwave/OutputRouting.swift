import Foundation

/// A device-global stereo destination pair. Channel numbers are one-based,
/// matching the values exposed by Core Audio and shown in the configuration UI.
nonisolated struct StereoOutputChannels: Codable, Equatable, Sendable {
    let left: Int
    let right: Int

    var isDistinct: Bool { left != right }

    func isInRange(channelCount: Int) -> Bool {
        channelCount >= 1
            && isDistinct
            && (1...channelCount).contains(left)
            && (1...channelCount).contains(right)
    }
}

/// The channel range owned by one actual output AudioStream. `streamIndex` is
/// its position in the device's output stream list, never a Core Audio object ID.
nonisolated struct OutputStreamDescriptor: Codable, Equatable, Sendable {
    let streamIndex: Int
    let startingChannel: Int
    let channelCount: Int

    var endingChannel: Int? {
        guard startingChannel > 0, channelCount > 0 else { return nil }
        let (end, overflow) = startingChannel.addingReportingOverflow(channelCount - 1)
        return overflow ? nil : end
    }

    func contains(channel: Int) -> Bool {
        guard let endingChannel else { return false }
        return (startingChannel...endingChannel).contains(channel)
    }
}

nonisolated struct ResolvedOutputRouting: Equatable, Sendable {
    let device: OutputDeviceDescriptor
    let outputChannels: StereoOutputChannels
    let tapStreamIndex: Int
    let nativeWidth: Int
    /// Zero-based indices relative to `tapStreamIndex`'s native channel range.
    let sourceChannelIndices: [Int]
    let inputLayout: InputLayout
    let sampleRate: Double
    let isExplicitAssignment: Bool
}

/// UI-safe routing details for status surfaces and tests. It deliberately
/// omits transient Core Audio device IDs and native object handles.
nonisolated struct OutputRoutingSummary: Equatable, Sendable {
    let deviceUID: String
    let outputChannels: StereoOutputChannels
    let tapStreamIndex: Int
    let nativeWidth: Int
    let sourceChannelIndices: [Int]
    let inputLayout: InputLayout
    let sampleRate: Double
    let isExplicitAssignment: Bool

    init(_ routing: ResolvedOutputRouting) {
        deviceUID = routing.device.uid
        outputChannels = routing.outputChannels
        tapStreamIndex = routing.tapStreamIndex
        nativeWidth = routing.nativeWidth
        sourceChannelIndices = routing.sourceChannelIndices
        inputLayout = routing.inputLayout
        sampleRate = routing.sampleRate
        isExplicitAssignment = routing.isExplicitAssignment
    }
}

nonisolated enum OutputRoutingResolution: Equatable, Sendable {
    case resolved(ResolvedOutputRouting)
    case unsupported(reason: String)
}

/// Pure route selection. The output pair only selects device destinations;
/// source capture is resolved from the device's own metadata and stereo
/// preference, so changing the headphone jack never changes the captured feed.
nonisolated enum OutputRoutingResolver {
    private enum SourceResolution {
        case success(stream: OutputStreamDescriptor, channels: [Int], layout: InputLayout)
        case failure(String)
    }

    private static let stereoLeftLabels: Set<UInt32> = [1, 38, 208, 301]
    private static let stereoRightLabels: Set<UInt32> = [2, 39, 209, 302]
    private static let unmappedLabels: Set<UInt32> = [0, 0xFFFF_FFFF]

    static func resolve(
        output: OutputDeviceDescriptor,
        channels: StereoOutputChannels? = nil
    ) -> OutputRoutingResolution {
        guard output.isConfigurationEligible else {
            return .unsupported(reason: output.configurationEligibilityReason ?? "This output cannot be routed by Airwave.")
        }
        guard output.nominalSampleRate.isFinite, output.nominalSampleRate > 0 else {
            return .unsupported(reason: "Airwave could not read a valid sample rate for this output.")
        }

        let streams = output.outputStreams
        guard areUsable(
            streams,
            streamCount: output.outputStreamCount,
            channelCount: output.outputChannelCount
        ) else {
            return .unsupported(reason: "Airwave could not resolve this device's output stream ranges.")
        }

        let explicitAssignment = channels != nil
        let selectedOutputChannels: StereoOutputChannels
        if let channels {
            guard isValidDestination(channels, output: output, streams: streams) else {
                return .unsupported(reason: "Choose two distinct output channels available on this device.")
            }
            selectedOutputChannels = channels
        } else if let preferred = output.preferredStereoChannels,
                  isValidDestination(preferred, output: output, streams: streams) {
            selectedOutputChannels = preferred
        } else {
            let fallback = StereoOutputChannels(left: 1, right: 2)
            guard isValidDestination(fallback, output: output, streams: streams) else {
                return .unsupported(reason: "Airwave could not find two available output channels on this device.")
            }
            selectedOutputChannels = fallback
        }

        let source: (stream: OutputStreamDescriptor, channels: [Int], layout: InputLayout)?
        switch sourceSelection(output: output, streams: streams) {
        case .success(let stream, let channels, let layout): source = (stream, channels, layout)
        case .failure(let reason): return .unsupported(reason: reason)
        }
        guard let source else {
            return .unsupported(reason: "Airwave could not resolve a stereo or supported surround source stream.")
        }

        return .resolved(ResolvedOutputRouting(
            device: output,
            outputChannels: selectedOutputChannels,
            tapStreamIndex: source.stream.streamIndex,
            nativeWidth: source.stream.channelCount,
            sourceChannelIndices: source.channels,
            inputLayout: source.layout,
            sampleRate: output.nominalSampleRate,
            isExplicitAssignment: explicitAssignment
        ))
    }

    /// Checks a carried route against the same metadata used to resolve it.
    /// Destination assignment may change, but source stream/layout selection
    /// must still be the resolver's automatic choice for that device.
    static func isValid(_ routing: ResolvedOutputRouting) -> Bool {
        guard case .resolved(let current) = resolve(
            output: routing.device,
            channels: routing.isExplicitAssignment ? routing.outputChannels : nil
        ) else { return false }
        return current.outputChannels == routing.outputChannels
            && current.isExplicitAssignment == routing.isExplicitAssignment
            && current.tapStreamIndex == routing.tapStreamIndex
            && current.nativeWidth == routing.nativeWidth
            && current.sourceChannelIndices == routing.sourceChannelIndices
            && current.inputLayout == routing.inputLayout
            && current.sampleRate == routing.sampleRate
    }

    /// Destination validation is device-global: the two channels may be in
    /// different actual streams as long as both belong to this device.
    static func isValidDestination(_ channels: StereoOutputChannels, output: OutputDeviceDescriptor) -> Bool {
        channels.isInRange(channelCount: output.outputChannelCount)
            && output.outputStreams.contains(where: { $0.contains(channel: channels.left) })
            && output.outputStreams.contains(where: { $0.contains(channel: channels.right) })
    }

    private static func isValidDestination(
        _ channels: StereoOutputChannels,
        output: OutputDeviceDescriptor,
        streams: [OutputStreamDescriptor]
    ) -> Bool {
        isValidDestination(channels, output: output)
            && streams.contains(where: { $0.contains(channel: channels.left) })
            && streams.contains(where: { $0.contains(channel: channels.right) })
    }

    private static func areUsable(
        _ streams: [OutputStreamDescriptor],
        streamCount: Int,
        channelCount: Int
    ) -> Bool {
        guard !streams.isEmpty, streams.count == streamCount else { return false }
        var seenIndices = Set<Int>()
        var coveredChannels = Set<Int>()
        for stream in streams {
            guard stream.streamIndex >= 0,
                  stream.streamIndex < streamCount,
                  seenIndices.insert(stream.streamIndex).inserted,
                  let end = stream.endingChannel,
                  end <= channelCount else { return false }
            for channel in stream.startingChannel...end {
                guard coveredChannels.insert(channel).inserted else { return false }
            }
        }
        return true
    }

    private static func sourceSelection(
        output: OutputDeviceDescriptor,
        streams: [OutputStreamDescriptor]
    ) -> SourceResolution {
        if output.outputChannelCount == 2 {
            guard let source = stereoSourcePair(output: output, streams: streams) else {
                return .failure("The selected stereo source channels span multiple output streams or are unavailable.")
            }
            return .success(stream: source.stream, channels: source.channels, layout: source.layout)
        }

        let labels = output.channelLabels
        let hasMappedLabels = labels?.contains(where: { !unmappedLabels.contains($0) }) == true
        let isUnlabeledFourChannel = output.outputChannelCount == 4 && !hasMappedLabels
        let isDuplicateStereoPair = output.outputChannelCount == 4 && hasDuplicateStereoLabels(labels)

        if isUnlabeledFourChannel || isDuplicateStereoPair {
            guard let channels = stereoSourcePair(output: output, streams: streams) else {
                return .failure("The selected stereo source channels span multiple output streams or are unavailable.")
            }
            return .success(stream: channels.stream, channels: channels.channels, layout: channels.layout)
        }

        guard hasMappedLabels || [6, 8, 12].contains(output.outputChannelCount) else {
            return .failure("Airwave could not determine a supported input layout for this output.")
        }

        switch InputLayoutResolver.resolve(
            channelLabels: labels,
            channelCount: output.outputChannelCount
        ) {
        case .supported(let layout):
            guard let stream = stream(
                containing: Array(1...output.outputChannelCount),
                in: streams
            ) else {
                return .failure("The supported surround source spans multiple output streams.")
            }
            return .success(
                stream: stream,
                channels: (1...output.outputChannelCount).map { $0 - stream.startingChannel },
                layout: layout
            )
        case .unsupported(let reason):
            return .failure(reason)
        }
    }

    private static func stereoSourcePair(
        output: OutputDeviceDescriptor,
        streams: [OutputStreamDescriptor]
    ) -> (stream: OutputStreamDescriptor, channels: [Int], layout: InputLayout)? {
        let pair: StereoOutputChannels
        if let preferred = output.preferredStereoChannels,
           preferred.isInRange(channelCount: output.outputChannelCount) {
            pair = preferred
        } else {
            pair = StereoOutputChannels(left: 1, right: 2)
        }
        guard let stream = stream(containing: [pair.left, pair.right], in: streams) else { return nil }
        return (
            stream: stream,
            channels: [pair.left - stream.startingChannel, pair.right - stream.startingChannel],
            layout: .stereo
        )
    }

    private static func stream(
        containing channels: [Int],
        in streams: [OutputStreamDescriptor]
    ) -> OutputStreamDescriptor? {
        streams.first { stream in channels.allSatisfy { stream.contains(channel: $0) } }
    }

    private static func hasDuplicateStereoLabels(_ labels: [UInt32]?) -> Bool {
        guard let labels, labels.count == 4 else { return false }
        let leftCount = labels.filter(stereoLeftLabels.contains).count
        let rightCount = labels.filter(stereoRightLabels.contains).count
        return leftCount == 2 && rightCount == 2
    }
}
