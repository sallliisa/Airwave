import Foundation

@MainActor
protocol OnboardingRouteProviding: AnyObject {
    var aggregateDevices: [AudioDevice] { get }
    var selectedAggregate: AudioDevice? { get }
    var availableInputs: [AggregateDeviceInspector.SubDeviceInfo] { get }
    var selectedInput: AggregateDeviceInspector.SubDeviceInfo? { get }
    var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] { get }
    var selectedOutput: AggregateDeviceInspector.SubDeviceInfo? { get }
    var presets: [HRIRPreset] { get }
    var selectedPreset: HRIRPreset? { get }

    func selectAggregate(_ device: AudioDevice)
    func selectInput(_ input: AggregateDeviceInspector.SubDeviceInfo)
    func selectOutput(_ output: AggregateDeviceInspector.SubDeviceInfo)
    func selectPreset(_ preset: HRIRPreset)
}

@MainActor
final class LiveOnboardingRouteController: OnboardingRouteProviding {
    private let menuViewModel: MenuBarViewModel
    private let audioManager: AudioGraphManager
    private let deviceManager: AudioDeviceManager
    private let hrirManager: HRIRManager

    init(
        menuViewModel: MenuBarViewModel = .shared,
        audioManager: AudioGraphManager = .shared,
        deviceManager: AudioDeviceManager = .shared,
        hrirManager: HRIRManager = .shared
    ) {
        self.menuViewModel = menuViewModel
        self.audioManager = audioManager
        self.deviceManager = deviceManager
        self.hrirManager = hrirManager
    }

    var aggregateDevices: [AudioDevice] { deviceManager.aggregateDevices }
    var selectedAggregate: AudioDevice? { audioManager.aggregateDevice }
    var availableInputs: [AggregateDeviceInspector.SubDeviceInfo] { audioManager.availableInputs }
    var selectedInput: AggregateDeviceInspector.SubDeviceInfo? { audioManager.selectedInputDevice }
    var availableOutputs: [AggregateDeviceInspector.SubDeviceInfo] {
        DeviceOutputEligibility.filter(audioManager.availableOutputs)
    }
    var selectedOutput: AggregateDeviceInspector.SubDeviceInfo? { audioManager.selectedOutputDevice }
    var presets: [HRIRPreset] { hrirManager.presets }
    var selectedPreset: HRIRPreset? { hrirManager.activePreset }

    func selectAggregate(_ device: AudioDevice) {
        menuViewModel.selectAggregateDevice(device)
    }

    func selectInput(_ input: AggregateDeviceInspector.SubDeviceInfo) {
        menuViewModel.selectInputDevice(input, switchSystemAudio: false)
    }

    func selectOutput(_ output: AggregateDeviceInspector.SubDeviceInfo) {
        menuViewModel.selectOutputDevice(output)
    }

    func selectPreset(_ preset: HRIRPreset) {
        hrirManager.activatePreset(
            preset,
            targetSampleRate: 48_000,
            inputLayout: InputLayout.detect(channelCount: 2)
        )
    }
}
