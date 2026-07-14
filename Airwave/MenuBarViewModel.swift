import AppKit
import Combine

@MainActor
final class MenuBarViewModel: ObservableObject {
    static let shared = MenuBarViewModel(
        runtime: .shared,
        hrirManager: .shared,
        updateManager: .shared
    )

    let runtime: AudioRuntimeState
    let hrirManager: HRIRManager
    let updateManager: UpdateManager

    init(
        runtime: AudioRuntimeState,
        hrirManager: HRIRManager,
        updateManager: UpdateManager
    ) {
        self.runtime = runtime
        self.hrirManager = hrirManager
        self.updateManager = updateManager
    }

    func selectPreset(_ preset: HRIRPreset) {
        hrirManager.activatePreset(
            preset,
            targetSampleRate: 48_000,
            inputLayout: .stereo
        )
    }

    func openPresetsDirectory() {
        hrirManager.openPresetsDirectory()
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
