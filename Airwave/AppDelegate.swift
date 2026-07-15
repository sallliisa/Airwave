import AppKit
import Combine
import SwiftUI

@MainActor
protocol ApplicationLifecycleApplication: ApplicationActivationPolicyApplying {
    var windows: [NSWindow] { get }
    func terminate(_ sender: Any?)
}

extension NSApplication: ApplicationLifecycleApplication {}

@MainActor
final class ApplicationLifecycleCoordinator: NSObject {
    static let shared = ApplicationLifecycleCoordinator(
        application: NSApplication.shared,
        isMenuBarVisible: { MenuBarVisibilityManager.shared.isVisible }
    )

    static let aboutWindowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.about")

    private let application: ApplicationLifecycleApplication
    private let isMenuBarVisible: () -> Bool
    private var explicitQuitRequested = false
    private var systemTerminationRequested = false
    private var observesWindows = false

    init(
        application: ApplicationLifecycleApplication,
        isMenuBarVisible: @escaping () -> Bool,
        observeWindows: Bool = true
    ) {
        self.application = application
        self.isMenuBarVisible = isMenuBarVisible
        super.init()
        guard observeWindows else { return }
        observesWindows = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didMiniaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didDeminiaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.willCloseNotification, object: nil)
    }

    deinit {
        if observesWindows { NotificationCenter.default.removeObserver(self) }
    }

    static func activationPolicy(menuBarVisible: Bool, hasVisibleUserWindow: Bool) -> NSApplication.ActivationPolicy {
        menuBarVisible || !hasVisibleUserWindow ? .accessory : .regular
    }

    func prepareToPresentUserWindow() {
        guard !isMenuBarVisible() else { return }
        apply(.regular)
    }

    func updateActivationPolicy() {
        let hasVisibleWindow = application.windows.contains(where: Self.isUserFacingWindow)
        updateActivationPolicy(hasVisibleUserWindow: hasVisibleWindow)
    }

    func updateActivationPolicy(hasVisibleUserWindow: Bool) {
        apply(Self.activationPolicy(
            menuBarVisible: isMenuBarVisible(),
            hasVisibleUserWindow: hasVisibleUserWindow
        ))
    }

    func closeAllUserWindows() {
        application.windows.filter {
            Self.isUserFacingWindow($0) || Self.isMenuBarPopover($0)
        }.forEach { $0.close() }
        updateActivationPolicy(hasVisibleUserWindow: false)
    }

    func requestExplicitQuit() {
        explicitQuitRequested = true
        application.terminate(nil)
    }

    func beginSystemTermination() {
        systemTerminationRequested = true
    }

    func terminationReply() -> NSApplication.TerminateReply {
        if explicitQuitRequested || systemTerminationRequested {
            explicitQuitRequested = false
            return .terminateNow
        }
        closeAllUserWindows()
        return .terminateCancel
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard application.setActivationPolicy(policy) else {
            Logger.log("[Application] Could not apply \(policy == .regular ? "regular" : "accessory") activation policy")
            return
        }
        Logger.log("[Application] Activation policy is \(policy == .regular ? "regular" : "accessory")")
    }

    private static func isUserFacingWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        if window.identifier == SettingsWindowPresenter.windowIdentifier
            || window.identifier == OnboardingWindowPresenter.windowIdentifier
            || window.identifier == aboutWindowIdentifier {
            return true
        }
        let className = window.className.lowercased()
        guard !isMenuBarPopover(window) else { return false }
        return window.canBecomeMain && window.styleMask.contains(.titled) && !window.title.isEmpty
    }

    private static func isMenuBarPopover(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let className = window.className.lowercased()
        return className.contains("menubar") || className.contains("popover")
    }

    @objc private func windowStateChanged() {
        Task { @MainActor in
            await Task.yield()
            updateActivationPolicy()
        }
    }
}

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")
    private static var settingsWindow: NSWindow?
    private static var openOnboardingAction: (() -> Void)?

    static func register(_ window: NSWindow) {
        settingsWindow = window
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.styleMask.remove(.resizable)
        let fixedSize = NSSize(width: 1080, height: 760)
        window.contentMinSize = fixedSize
        window.contentMaxSize = fixedSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
    }

    static func presentExistingWindow() {
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
        WindowFronting.present(identifier: windowIdentifier, title: "Settings")
    }

    static func present(openOnboarding: (() -> Void)? = nil) {
        if let openOnboarding { openOnboardingAction = openOnboarding }
        if settingsWindow == nil {
            let content = SettingsView(openOnboardingAction: { openOnboardingAction?() })
                .environmentObject(MenuBarViewModel.shared)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.center()
            register(window)
        }
        presentExistingWindow()
    }
}

@MainActor
enum OnboardingWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.onboarding")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
    }

    static func presentExistingWindow() {
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
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
        ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioRuntimeController.shared.terminate()
        Logger.log("[AppDelegate] Airwave safe shell terminating")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationLifecycleCoordinator.shared.terminationReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !MenuBarVisibilityManager.shared.isVisible { SettingsWindowPresenter.present() }
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !MenuBarVisibilityManager.shared.isVisible else { return false }
        SettingsWindowPresenter.present()
        return true
    }

    @objc private func willSleep() { AudioRuntimeController.shared.willSleep() }
    @objc private func didWake() { AudioRuntimeController.shared.didWake() }
    @objc private func willPowerOff() { ApplicationLifecycleCoordinator.shared.beginSystemTermination() }
}
