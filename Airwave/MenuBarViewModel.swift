import AppKit
import Combine

@MainActor
final class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel(
        runtime: .shared,
        hrirManager: .shared,
        profileManager: .shared,
        updateManager: .shared,
        runtimeActions: AudioRuntimeController.shared
    )

    let runtime: AudioRuntimeState
    let hrirManager: HRIRManager
    let profileManager: DeviceProfileManager
    let updateManager: UpdateManager
    private let runtimeActions: AudioRuntimeUserActions

    init(
        runtime: AudioRuntimeState,
        hrirManager: HRIRManager,
        profileManager: DeviceProfileManager = .shared,
        updateManager: UpdateManager,
        runtimeActions: AudioRuntimeUserActions
    ) {
        self.runtime = runtime
        self.hrirManager = hrirManager
        self.profileManager = profileManager
        self.updateManager = updateManager
        self.runtimeActions = runtimeActions
    }

    func selectPreset(_ preset: HRIRPreset?) {
        profileManager.setCurrentHRIRPresetID(preset?.id)
    }

    var currentHRIRPreset: HRIRPreset? {
        hrirManager.presets.first { $0.id == profileManager.currentProfile?.hrirPresetID }
    }

    static func sortedPresets(_ presets: [HRIRPreset]) -> [HRIRPreset] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func presetTargetSampleRate(for output: OutputDeviceDescriptor?) -> Double {
        output?.nominalSampleRate ?? 48_000
    }

    func openPresetsDirectory() {
        hrirManager.openPresetsDirectory()
    }

    var presentation: RuntimeMenuPresentation {
        .make(from: runtime.status)
    }

    func retryAudio() {
        runtimeActions.retryNow()
    }

    func openSystemAudioRecordingSettings() {
        runtimeActions.openSystemAudioRecordingSettings()
    }

    func openSupport() {
        guard let url = URL(string: "https://github.com/sallliisa/Airwave/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        closeMenuBarPopover()
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
        NSApp.orderFrontStandardAboutPanel(nil)
        if let window = NSApp.windows.first(where: { $0.title.localizedCaseInsensitiveContains("About") }) {
            window.identifier = ApplicationLifecycleCoordinator.aboutWindowIdentifier
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeMenuBarPopover() {
        if let window = NSApp.windows.first(where: {
            $0.className.contains("MenuBar") || $0.className.contains("Popover")
        }) {
            window.close()
        }
    }

    func quitApp() {
        ApplicationLifecycleCoordinator.shared.requestExplicitQuit()
    }
}
