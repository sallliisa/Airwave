import AppKit
import Combine

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func presentExistingWindow() {
        WindowFronting.present(identifier: windowIdentifier, title: "Settings")
    }
}

@MainActor
enum OnboardingWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.onboarding")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func presentExistingWindow() {
        WindowFronting.present(identifier: windowIdentifier, title: "Set Up Airwave")
    }
}

@MainActor
private enum WindowFronting {
    static func present(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        retriesRemaining: Int = 5
    ) {
        if let window = NSApp.windows.first(where: { $0.identifier == identifier || $0.title == title }) {
            window.identifier = identifier
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.hidesOnDeactivate = false
            if window.isMiniaturized { window.deminiaturize(nil) }

            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)

            Task { @MainActor in
                await Task.yield()
                guard window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard window.isVisible else { return }
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard retriesRemaining > 0 else { return }
        Task { @MainActor in
            await Task.yield()
            present(identifier: identifier, title: title, retriesRemaining: retriesRemaining - 1)
        }
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
