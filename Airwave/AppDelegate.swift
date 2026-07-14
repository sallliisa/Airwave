import AppKit
import Combine

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("[AppDelegate] Airwave safe shell launched")
        let controller = AudioRuntimeController.shared
        let hrir = HRIRManager.shared
        controller.launch(presetReady: hrir.isConvolutionActive)
        hrir.$activePreset
            .combineLatest(hrir.$errorMessage)
            .receive(on: DispatchQueue.main)
            .sink { preset, error in
                if let error {
                    controller.presetActivationFailed(error)
                } else {
                    controller.presetDidChange(isReady: preset != nil && hrir.isConvolutionActive)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioRuntimeController.shared.terminate()
        Logger.log("[AppDelegate] Airwave safe shell terminating")
    }

    @objc private func willSleep() { AudioRuntimeController.shared.willSleep() }
    @objc private func didWake() { AudioRuntimeController.shared.didWake() }
}
