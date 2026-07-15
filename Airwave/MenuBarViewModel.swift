import AppKit
import Combine

@MainActor
final class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel(
        runtime: .shared,
        hrirManager: .shared,
        updateManager: .shared,
        runtimeActions: AudioRuntimeController.shared
    )

    let runtime: AudioRuntimeState
    let hrirManager: HRIRManager
    let updateManager: UpdateManager
    private let runtimeActions: AudioRuntimeUserActions

    init(
        runtime: AudioRuntimeState,
        hrirManager: HRIRManager,
        updateManager: UpdateManager,
        runtimeActions: AudioRuntimeUserActions
    ) {
        self.runtime = runtime
        self.hrirManager = hrirManager
        self.updateManager = updateManager
        self.runtimeActions = runtimeActions
    }

    func selectPreset(_ preset: HRIRPreset?) {
        guard let preset else {
            hrirManager.deactivatePreset()
            return
        }
        hrirManager.activatePreset(
            preset,
            targetSampleRate: Self.presetTargetSampleRate(for: runtime.currentOutput),
            inputLayout: .stereo
        )
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
        guard let url = URL(string: "https://github.com/dertian/Airwave/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
