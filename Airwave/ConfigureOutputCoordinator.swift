import Combine
import Foundation

@MainActor
final class ConfigureOutputCoordinator: ObservableObject {
    let deviceUID: String
    let deviceName: String

    @Published private(set) var leftChannel: Int
    @Published private(set) var rightChannel: Int

    private let profiles: DeviceProfileManager
    private let saveOperation: (StereoOutputChannels, String) -> Bool
    @Published private var output: OutputDeviceDescriptor?
    private var cancellables: Set<AnyCancellable> = []
    private var isFinished = false
    @Published private var saveFailureMessage: String?

    init(
        deviceUID: String,
        deviceName: String,
        profiles: DeviceProfileManager,
        saveOperation: ((StereoOutputChannels, String) -> Bool)? = nil
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.profiles = profiles
        self.saveOperation = saveOperation ?? { [weak profiles] channels, uid in
            profiles?.setOutputChannels(channels, for: uid) ?? false
        }
        let initialOutput = profiles.availableOutputs.first { $0.uid == deviceUID }
        output = initialOutput
        let initialChannels = Self.initialChannels(
            saved: profiles.profile(for: deviceUID)?.outputChannels,
            output: initialOutput
        )
        leftChannel = initialChannels.left
        rightChannel = initialChannels.right

        profiles.$availableOutputs
            .combineLatest(profiles.$profiles)
            .receive(on: RunLoop.main)
            .sink { [weak self] outputs, _ in
                self?.refreshOutput(in: outputs)
            }
            .store(in: &cancellables)
    }

    var isAvailable: Bool {
        output?.isConfigurationEligible == true
    }

    var channelCount: Int? {
        output?.outputChannelCount
    }

    var leftChannelOptions: [Int] {
        channelOptions(including: leftChannel)
    }

    var rightChannelOptions: [Int] {
        channelOptions(including: rightChannel)
    }

    var canSave: Bool {
        !isFinished && validation == .valid
    }

    var validationMessage: String? {
        if let saveFailureMessage { return saveFailureMessage }
        switch validation {
        case .valid, .finished:
            return nil
        case .unavailable:
            return "Device unavailable. Reconnect it to configure output channels."
        case .duplicate:
            return "Choose different channel numbers for left and right output."
        case .outOfRange:
            return "The saved channel assignment is unavailable. Choose channels on this device."
        case .unmapped:
            return "Choose two channels available in the device's output streams."
        }
    }

    func channelOptionLabel(_ channel: Int) -> String {
        isChannelAvailable(channel) ? "Channel \(channel)" : "Unavailable (channel \(channel))"
    }

    func selectLeftChannel(_ channel: Int) {
        guard !isFinished, leftChannel != channel else { return }
        saveFailureMessage = nil
        leftChannel = channel
    }

    func selectRightChannel(_ channel: Int) {
        guard !isFinished, rightChannel != channel else { return }
        saveFailureMessage = nil
        rightChannel = channel
    }

    /// Saves one pair for the UID captured when this editor opened. The
    /// manager's false result also represents a no-op save of an existing pair.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        let pair = draftPair
        let didChange = saveOperation(pair, deviceUID)
        guard didChange || profiles.profile(for: deviceUID)?.outputChannels == pair else {
            saveFailureMessage = "Airwave could not save this output assignment. Try again."
            return false
        }
        isFinished = true
        return true
    }

    /// Explicit Cancel and owner-driven invalidation discard this editor's draft.
    /// Native popover dismissal does not call this method.
    func cancel() {
        isFinished = true
    }

    private var draftPair: StereoOutputChannels {
        StereoOutputChannels(left: leftChannel, right: rightChannel)
    }

    private var validation: Validation {
        guard !isFinished else { return .finished }
        guard let output, output.isConfigurationEligible else { return .unavailable }
        let pair = draftPair
        guard pair.isDistinct else { return .duplicate }
        guard pair.isInRange(channelCount: output.outputChannelCount) else { return .outOfRange }
        guard OutputRoutingResolver.isValidDestination(pair, output: output) else { return .unmapped }
        return .valid
    }

    private func channelOptions(including selected: Int) -> [Int] {
        var channels: [Int] = []
        if let count = output?.outputChannelCount, count > 0 {
            channels = Array(1...count)
        }
        if !channels.contains(selected) {
            channels.append(selected)
            channels.sort()
        }
        return channels
    }

    private func isChannelAvailable(_ channel: Int) -> Bool {
        guard let output,
              output.outputChannelCount > 0,
              (1...output.outputChannelCount).contains(channel) else { return false }
        return output.outputStreams.contains { $0.contains(channel: channel) }
    }

    private func refreshOutput(in outputs: [OutputDeviceDescriptor]) {
        let refreshed = outputs.first { $0.uid == deviceUID }
        guard refreshed != output else { return }
        output = refreshed
        saveFailureMessage = nil
    }

    private static func initialChannels(
        saved: StereoOutputChannels?,
        output: OutputDeviceDescriptor?
    ) -> StereoOutputChannels {
        if let saved { return saved }
        if let output,
           let preferred = output.preferredStereoChannels,
           OutputRoutingResolver.isValidDestination(preferred, output: output) {
            return preferred
        }
        return StereoOutputChannels(left: 1, right: 2)
    }

    private enum Validation: Equatable {
        case valid
        case unavailable
        case duplicate
        case outOfRange
        case unmapped
        case finished
    }
}
