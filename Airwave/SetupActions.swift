import AppKit

@MainActor
protocol SetupActionProviding {
    func openBlackHoleDownload()
    func openAudioMIDISetup()
    func openMicrophoneSettings()
    func openHRTFDatabase()
    func openHRIRFolder()
    func requestMicrophonePermission(completion: ((Bool) -> Void)?)
    func startAirwave()
    func quitAirwave()
}

@MainActor
final class SystemSetupActions: SetupActionProviding {
    static let shared = SystemSetupActions()

    func openBlackHoleDownload() {
        NSWorkspace.shared.open(ConfigurationManager.ExternalLinks.blackHoleDownload)
    }

    func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    func openMicrophoneSettings() {
        PermissionManager.shared.openSystemSettings()
    }

    func openHRTFDatabase() {
        NSWorkspace.shared.open(ConfigurationManager.ExternalLinks.hrtfDatabase)
    }

    func openHRIRFolder() {
        HRIRManager.shared.openPresetsDirectory()
    }

    func requestMicrophonePermission(completion: ((Bool) -> Void)?) {
        PermissionManager.shared.checkAndRequestMicrophonePermission { granted in
            completion?(granted)
        }
    }

    func startAirwave() {
        MenuBarViewModel.shared.setEngineRunning(true)
    }

    func quitAirwave() {
        MenuBarViewModel.shared.quitApp()
    }
}
